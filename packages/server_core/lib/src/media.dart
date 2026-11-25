import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

class Meta {
  const Meta({
    this.durationMs,
    this.width,
    this.height,
    this.vcodec,
    this.acodec,
    this.audio = const [],
    this.subs = const [],
  });
  final int? durationMs, width, height;
  final String? vcodec, acodec;

  /// Pistas de audio y subtítulos: {codec, lang, title, ch}
  final List<Map<String, dynamic>> audio, subs;

  static List<Map<String, dynamic>> _list(Object? o) =>
      ((o as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();

  factory Meta.fromJson(Map<String, dynamic> j) => Meta(
        durationMs: j['durationMs'] as int?,
        width: j['width'] as int?,
        height: j['height'] as int?,
        vcodec: j['vcodec'] as String?,
        acodec: j['acodec'] as String?,
        audio: _list(j['audio']),
        subs: _list(j['subs']),
      );
  Map<String, dynamic> toJson() => {
        'durationMs': durationMs,
        'width': width,
        'height': height,
        'vcodec': vcodec,
        'acodec': acodec,
        'audio': audio,
        'subs': subs,
      };
}

/// Localiza ffmpeg/ffprobe junto al ejecutable, en el directorio actual o en el PATH.
class Tools {
  const Tools(this.ffmpeg, this.ffprobe);
  final String? ffmpeg, ffprobe;

  static Future<Tools> locate() async {
    Future<String?> find(String name) async {
      final exe = Platform.isWindows ? '$name.exe' : name;
      for (final c in [
        p.join(p.dirname(Platform.resolvedExecutable), exe),
        p.join(Directory.current.path, exe),
        exe,
      ]) {
        try {
          final r = await Process.run(c, ['-version']);
          if (r.exitCode == 0) {
            print('$name: $c');
            return c;
          }
        } catch (_) {}
      }
      print('AVISO: no se encontró $name (copia $exe junto al servidor o al PATH).');
      return null;
    }

    return Tools(await find('ffmpeg'), await find('ffprobe'));
  }

  Future<Meta?> probe(String path) async {
    final ff = ffprobe;
    if (ff == null) return null;
    try {
      final r = await Process.run(
          ff,
          ['-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', path],
          stdoutEncoding: utf8);
      if (r.exitCode != 0) return null;
      final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
      final streams = ((j['streams'] as List?) ?? []).cast<Map<String, dynamic>>();
      final v = streams.where((s) => s['codec_type'] == 'video').firstOrNull;
      final a = streams.where((s) => s['codec_type'] == 'audio').firstOrNull;
      final dur = double.tryParse('${(j['format'] as Map?)?['duration']}');
      Map<String, dynamic> info(Map<String, dynamic> st) {
        final tags = {
          for (final e in ((st['tags'] as Map?) ?? {}).entries)
            '${e.key}'.toLowerCase(): e.value
        };
        return {
          'codec': st['codec_name'],
          'lang': tags['language'],
          'title': tags['title'],
          'ch': st['channels'],
        };
      }

      return Meta(
        durationMs: dur == null ? null : (dur * 1000).round(),
        width: v?['width'] as int?,
        height: v?['height'] as int?,
        vcodec: v?['codec_name'] as String?,
        acodec: a?['codec_name'] as String?,
        audio: streams.where((x) => x['codec_type'] == 'audio').map(info).toList(),
        subs: streams.where((x) => x['codec_type'] == 'subtitle').map(info).toList(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Miniaturas bajo demanda, cacheadas en disco, con máx. 2 ffmpeg a la vez.
class Thumbs {
  Thumbs(this.tools, String dirPath)
      : dir = Directory(dirPath)..createSync(recursive: true);
  final Tools tools;
  final Directory dir;
  final _inflight = <String, Future<File?>>{};
  final _queue = <Completer<void>>[];
  int _running = 0;
  static const _max = 2;

  Future<File?> get(String id, String path, int? durationMs) => _inflight.putIfAbsent(
      id,
      () => _make(id, path, durationMs).whenComplete(() {
            _inflight.remove(id); // con llaves: no debe devolver la Future
          }));

  Future<void> _acquire() async {
    if (_running < _max) {
      _running++;
      return;
    }
    final c = Completer<void>();
    _queue.add(c);
    await c.future; // el hueco se transfiere al liberar
  }

  void _release() {
    if (_queue.isNotEmpty) {
      _queue.removeAt(0).complete();
    } else {
      _running--;
    }
  }

  Future<File?> _make(String id, String path, int? durationMs) async {
    for (final e in ['jpg', 'png']) {
      final f = File(p.join(dir.path, '$id.$e'));
      if (f.existsSync()) return f;
    }
    final ff = tools.ffmpeg;
    if (ff == null) return null;
    await _acquire();
    try {
      final secs = durationMs == null ? 5 : max(1, durationMs ~/ 10000);
      // JPG y, si esta versión de ffmpeg lo rechaza, PNG. Cada fallo se registra.
      for (final ext in ['jpg', 'png']) {
        final out = File(p.join(dir.path, '$id.$ext'));
        final tmp = '${out.path}.tmp.$ext';
        for (final t in [secs, 0]) {
          final r = await Process.run(ff, [
            '-y', '-v', 'error', '-ss', '$t', '-i', path,
            '-frames:v', '1', '-an', '-sn', '-vf', 'scale=320:-2',
            if (ext == 'jpg') ...['-q:v', '5'],
            tmp,
          ]);
          if (r.exitCode == 0 && File(tmp).existsSync()) {
            await File(tmp).rename(out.path);
            return out;
          }
          print('[miniatura] ffmpeg falló ($ext, ss=$t) en "$path": ${'${r.stderr}'.trim()}');
        }
      }
      return null;
    } catch (e) {
      print('[miniatura] error: $e');
      return null;
    } finally {
      _release();
    }
  }
}

/// Mapa persistente en un archivo JSON (caché de metadatos y progreso).
///
/// Robusto ante cortes: se escribe en un archivo temporal y se renombra (nunca queda un JSON
/// a medias si se apaga el PC o se cierra el servidor justo al guardar), se conserva una copia
/// del último estado bueno (.bak) y, si al arrancar el archivo está dañado, se recupera de la
/// copia en lugar de empezar de cero y borrar todo el progreso en el siguiente guardado.
class JsonFile {
  JsonFile(String path)
      : _f = File(path),
        _bak = File('$path.bak'),
        _tmp = File('$path.tmp') {
    final loaded = _tryLoad(_f) ?? _tryLoad(_bak);
    if (loaded != null) {
      data.addAll(loaded);
    } else if (_f.existsSync() && _f.lengthSync() > 0) {
      // Ilegible y sin copia válida: se aparta para poder revisarlo en vez de pisarlo.
      try {
        _f.copySync('$path.corrupt-${DateTime.now().millisecondsSinceEpoch}');
      } catch (_) {}
    }
  }
  final File _f, _bak, _tmp;
  final data = <String, dynamic>{};
  DateTime _lastBak = DateTime.fromMillisecondsSinceEpoch(0);

  static Map<String, dynamic>? _tryLoad(File f) {
    try {
      if (!f.existsSync()) return null;
      final raw = f.readAsStringSync();
      if (raw.trim().isEmpty) return null;
      final d = jsonDecode(raw);
      return d is Map ? d.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  void save() {
    final json = jsonEncode(data);
    try {
      _tmp.writeAsStringSync(json, flush: true);
      // Copia del último estado bueno (como mucho una por minuto: los archivos grandes,
      // como la caché de metadatos, no se duplican en cada guardado).
      final now = DateTime.now();
      if (_f.existsSync() && now.difference(_lastBak).inSeconds >= 60) {
        try {
          _f.copySync(_bak.path);
          _lastBak = now;
        } catch (_) {}
      }
      _tmp.renameSync(_f.path); // reemplazo atómico
    } catch (_) {
      // Algún antivirus o el sistema puede bloquear el renombrado: se escribe directo.
      _f.writeAsStringSync(json, flush: true);
    }
  }
}
