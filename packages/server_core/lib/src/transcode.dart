import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'media.dart';

const segLen = 6; // segundos por segmento
const hlsRates = {480: 2, 720: 4, 1080: 8}; // altura -> Mbps máximos

class _Session {
  _Session(this.dir);
  final Directory dir;
  Process? proc;
  bool exited = false, starting = false;
  int startSeg = 0;
  DateTime last = DateTime.now();

  File file(int i) => File(p.join(dir.path, 'seg_$i.ts'));
  bool get alive => starting || (proc != null && !exited);

  /// Primer segmento sin generar a partir del punto donde arrancó ffmpeg.
  int firstMissing() {
    var n = startSeg;
    while (file(n).existsSync()) {
      n++;
    }
    return n;
  }
}

/// HLS bajo demanda: un solo ffmpeg continuo por (video, calidad, audio).
/// Si el cliente salta lejos o hacia atrás, se reinicia en ese segmento.
class Transcoder {
  Transcoder(this.tools, String path) : root = Directory(path) {
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {}
    root.createSync(recursive: true);
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _sweep());
  }

  final Tools tools;
  final Directory root;
  Timer? _timer;
  final _sessions = <String, _Session>{};

  Future<File?> segment(String id, String path, int q, int audio, int i) async {
    final key = '${id}_${q}_$audio';
    final s = _sessions.putIfAbsent(key, () {
      final d = Directory(p.join(root.path, key))..createSync(recursive: true);
      return _Session(d);
    });
    s.last = DateTime.now();
    final f = s.file(i);
    if (f.existsSync()) return f;

    // La decisión se toma de forma síncrona para que peticiones paralelas no
    // arranquen varios ffmpeg a la vez.
    if (!s.alive || i < s.startSeg || i > s.firstMissing() + 2) {
      await _start(s, path, q, audio, i);
    }

    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      if (f.existsSync()) return f;
      if (s.exited && !s.starting) return null; // ffmpeg terminó sin generarlo
      await Future.delayed(const Duration(milliseconds: 150));
    }
    return null;
  }

  Future<void> _start(_Session s, String path, int q, int audio, int i) async {
    s.proc?.kill();
    s.proc = null;
    s.exited = false;
    s.starting = true;
    s.startSeg = i;
    final t = i * segLen;
    final rate = hlsRates[q]!;
    final args = [
      '-hide_banner', '-loglevel', 'error', '-nostdin',
      '-ss', '$t', '-i', path,
      '-map', '0:v:0', '-map', '0:a:$audio?',
      '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23',
      '-maxrate', '${rate}M', '-bufsize', '${rate * 2}M',
      '-vf', "scale=-2:'min($q,ih)',format=yuv420p",
      '-force_key_frames', 'expr:gte(t,n_forced*$segLen)',
      '-c:a', 'aac', '-b:a', '160k', '-ac', '2',
      '-f', 'hls', '-hls_time', '$segLen', '-hls_list_size', '0',
      '-hls_flags', 'temp_file', '-start_number', '$i',
      '-output_ts_offset', '$t',
      '-hls_segment_filename', p.join(s.dir.path, 'seg_%d.ts'),
      p.join(s.dir.path, 'out.m3u8'),
    ];
    try {
      final proc = await Process.start(tools.ffmpeg!, args);
      s.proc = proc;
      proc.stdout.drain<void>();
      proc.stderr.transform(utf8.decoder).listen((e) => print('[ffmpeg] ${e.trim()}'));
      proc.exitCode.then((_) {
        if (identical(s.proc, proc)) s.exited = true;
      });
    } finally {
      s.starting = false;
    }
  }

  void _sweep() {
    final now = DateTime.now();
    for (final e in _sessions.entries.toList()) {
      final idle = now.difference(e.value.last);
      if (idle > const Duration(seconds: 90)) e.value.proc?.kill();
      if (idle > const Duration(minutes: 15)) {
        try {
          e.value.dir.deleteSync(recursive: true);
        } catch (_) {}
        _sessions.remove(e.key);
      }
    }
  }

  void dispose() {
    _timer?.cancel();
    for (final s in _sessions.values) {
      s.proc?.kill();
    }
  }
}
