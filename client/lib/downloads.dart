import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken, DioException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared/shared.dart';

import 'api.dart';
import 'book_downloads.dart';
import 'book_playback.dart';
import 'audiobooks.dart';
import 'core.dart';
import 'main.dart' show PlayerScreen;
import 'player_params.dart';
import 'progress_sync.dart';
import 'oscars.dart';
import 'remote.dart';
import 'settings.dart' show SettingsScreen;
import 'tv.dart' show TvTextEntry, tvModeProvider;
import 'sounds.dart';
import 'theater.dart' show PosterCard, FeaturedHero, ShelfRow, OfflineBookShelf;

// ===========================================================================
//  Descargas: guardan en el dispositivo el video original, la carátula, el fondo,
//  la miniatura, la ficha (sinopsis, reparto...) y los subtítulos externos, para
//  ver películas y series con el servidor apagado.
//
//  <datos de la app>/downloads/<id>/
//      video.<ext>   (mientras baja: video.part, se reanuda con HTTP Range)
//      poster.jpg  backdrop.jpg  thumb.jpg  still.jpg (imagen del capítulo)
//      sub_<id>      subtítulos externos
//  <datos de la app>/downloads/_show_<idSerie>/
//      poster.jpg  backdrop.jpg      (carátula y fondo de la serie)
//  El índice (estado, ficha, progreso) se guarda en SharedPreferences.
//
//  Las series no son un tipo aparte: cada capítulo es una descarga normal (con su
//  propio estado y progreso) y la serie se arma agrupando por `showId`.
// ===========================================================================

const _bg = Color(0xFF141414);
const _red = Color(0xFFE50914);
final _sep = Platform.pathSeparator;

/// Carpeta raíz de las descargas; la prepara main() antes de arrancar.
final downloadsRootProvider =
    Provider<String>((_) => throw UnimplementedError('override en main'));

Future<String> prepareDownloadsRoot() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory('${base.path}${Platform.pathSeparator}downloads');
  await dir.create(recursive: true);
  return dir.path;
}

String fmtBytes(int b) {
  if (b >= 1073741824) return '${(b / 1073741824).toStringAsFixed(1)} GB';
  if (b >= 1048576) return '${(b / 1048576).toStringAsFixed(0)} MB';
  return '${(b / 1024).toStringAsFixed(0)} KB';
}

const _extByMime = {
  'video/mp4': '.mp4',
  'video/x-matroska': '.mkv',
  'video/webm': '.webm',
  'video/x-msvideo': '.avi',
  'video/quicktime': '.mov',
  'video/x-ms-wmv': '.wmv',
  'video/x-flv': '.flv',
  'video/mp2t': '.ts',
};

// ---------------------------------------------------------------------------
//  Modelo
// ---------------------------------------------------------------------------

enum DlState { queued, downloading, paused, error, done }

class DownloadException implements Exception {
  const DownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DownloadEntry {
  DownloadEntry(this.id, this._raw,
      {this.state = DlState.queued,
      this.received = 0,
      this.total = 0,
      this.ext = '.mkv',
      this.hasPoster = false,
      this.hasBackdrop = false,
      this.hasThumb = false,
      this.hasStill = false,
      this.subs = const [],
      this.positionMs = 0,
      this.watchedMs = 0,
      this.dirty = false,
      this.addedMs = 0,
      this.error});

  final String id;
  Map<String, dynamic> _raw;
  VideoDetail? _detail;

  DlState state;
  int received, total, positionMs, watchedMs, addedMs;
  String ext;
  bool hasPoster, hasBackdrop, hasThumb, hasStill;

  /// Hay una posición de reproducción guardada aquí que el servidor aún no conoce.
  bool dirty;

  /// Subtítulos externos descargados: {id, label}.
  List<Map<String, String>> subs;
  String? error;

  /// Respuesta de /api/videos/<id> (item, pistas y perfil completo).
  Map<String, dynamic> get raw => _raw;
  set raw(Map<String, dynamic> v) {
    _raw = v;
    _detail = null;
  }

  VideoDetail get detail => _detail ??= VideoDetail.fromJson(_raw);
  Profile get profile => detail.profile;

  /// El video como lo ve el resto de la app, con la posición local y sin las imágenes
  /// que no se pudieron descargar.
  VideoItem get item {
    final j = Map<String, dynamic>.from(_raw['item'] as Map);
    j['positionMs'] = positionMs;
    j['watchedMs'] = watchedMs;
    j['addedMs'] = addedMs;
    if (!hasPoster) j['posterV'] = 0;
    if (!hasBackdrop) j['backdropV'] = 0;
    if (!hasStill) j['stillV'] = 0;
    return VideoItem.fromJson(j);
  }

  /// Id de la serie si es un capítulo.
  String? get showId => (_raw['item'] as Map)['showId'] as String?;
  bool get isEpisode => showId != null;

  /// Visto (más del 95 %).
  bool get seen {
    final p = item.progress;
    return p != null && p >= 0.95;
  }

  double? get fraction =>
      total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'raw': _raw,
        'state': state.name,
        'received': received,
        'total': total,
        'ext': ext,
        'hasPoster': hasPoster,
        'hasBackdrop': hasBackdrop,
        'hasThumb': hasThumb,
        'hasStill': hasStill,
        'subs': subs,
        'positionMs': positionMs,
        'watchedMs': watchedMs,
        'dirty': dirty,
        'addedMs': addedMs,
        'error': error,
      };

  factory DownloadEntry.fromJson(Map<String, dynamic> j) {
    final st = DlState.values
        .firstWhere((s) => s.name == j['state'], orElse: () => DlState.error);
    // Si la app se cerró a medias, la descarga quedó interrumpida (no pausada por el usuario).
    final interrupted = st == DlState.queued || st == DlState.downloading;
    return DownloadEntry(
        j['id'] as String, (j['raw'] as Map).cast<String, dynamic>(),
        state: interrupted ? DlState.error : st,
        received: (j['received'] as int?) ?? 0,
        total: (j['total'] as int?) ?? 0,
        ext: (j['ext'] as String?) ?? '.mkv',
        hasPoster: (j['hasPoster'] as bool?) ?? false,
        hasBackdrop: (j['hasBackdrop'] as bool?) ?? false,
        hasThumb: (j['hasThumb'] as bool?) ?? false,
        hasStill: (j['hasStill'] as bool?) ?? false,
        subs: [
          for (final s in (j['subs'] as List? ?? const []))
            (s as Map).map((k, v) => MapEntry('$k', '$v'))
        ],
        positionMs: (j['positionMs'] as int?) ?? 0,
        watchedMs: (j['watchedMs'] as int?) ?? 0,
        dirty: (j['dirty'] as bool?) ?? false,
        addedMs: (j['addedMs'] as int?) ?? 0,
        error:
            (j['error'] as String?) ?? (interrupted ? 'Interrumpida' : null));
  }
}

/// Ficha de una serie guardada en el dispositivo (sin capítulos: esos son las descargas).
class ShowMeta {
  ShowMeta(this.id, this.raw,
      {this.hasPoster = false, this.hasBackdrop = false});

  final String id;

  /// {show: ShowItem, profile: Profile} tal como los entrega /api/shows/<id>.
  Map<String, dynamic> raw;
  bool hasPoster, hasBackdrop;

  ShowItem get show =>
      ShowItem.fromJson((raw['show'] as Map).cast<String, dynamic>());

  Profile get profile => raw['profile'] is Map
      ? Profile.fromJson((raw['profile'] as Map).cast<String, dynamic>())
      : const Profile();

  Map<String, dynamic> toJson() => {
        'id': id,
        'raw': raw,
        'hasPoster': hasPoster,
        'hasBackdrop': hasBackdrop,
      };

  factory ShowMeta.fromJson(Map<String, dynamic> j) =>
      ShowMeta(j['id'] as String, (j['raw'] as Map).cast<String, dynamic>(),
          hasPoster: (j['hasPoster'] as bool?) ?? false,
          hasBackdrop: (j['hasBackdrop'] as bool?) ?? false);
}

int _byEpisode(DownloadEntry a, DownloadEntry b) {
  final x = a.item, y = b.item;
  final s = (x.season ?? 0).compareTo(y.season ?? 0);
  return s != 0 ? s : (x.episode ?? 0).compareTo(y.episode ?? 0);
}

/// Bytes que ocupan las descargas en el dispositivo.
int downloadsUsedBytes(Iterable<DownloadEntry> all) =>
    all.fold(0, (s, e) => s + e.received);

// ---------------------------------------------------------------------------
//  Gestor de descargas
// ---------------------------------------------------------------------------

enum _Stop { pause, delete }

String _errMsg(Object err) {
  if (err is DownloadException) return err.message;
  if (err is DioException) {
    final c = err.response?.statusCode;
    if (c == 404) return 'El video ya no está en el servidor.';
    if (c == 401) return 'El servidor no reconoce este dispositivo.';
    return 'Se perdió la conexión con el servidor.';
  }
  if (err is FileSystemException) {
    return 'No se pudo escribir en el dispositivo (¿sin espacio?).';
  }
  return '$err';
}

int? _rangeTotal(String? contentRange) {
  if (contentRange == null) return null;
  final m = RegExp(r'/(\d+)\s*$').firstMatch(contentRange);
  return m == null ? null : int.tryParse(m.group(1)!);
}

class DownloadsNotifier extends Notifier<Map<String, DownloadEntry>> {
  static const _key = 'downloads_index';
  static const _showsKey = 'downloads_shows';

  final _cancel = <String, CancelToken>{};
  final _subs = <String, StreamSubscription<Uint8List>>{};
  final _finish = <String, Completer<void>>{};
  final _stopWhy = <String, _Stop>{};
  final _refreshing = <String>{};
  final _showBusy = <String>{};
  final _shows = <String, ShowMeta>{};

  /// Descargas bajando ahora mismo (id -> ejecución). Pueden ser varias a la vez
  /// (Ajustes → Descargas simultáneas).
  final _running = <String, Future<void>>{};

  /// Fichas de las series que tienen capítulos en el dispositivo.
  Map<String, ShowMeta> get shows => _shows;

  @override
  Map<String, DownloadEntry> build() {
    // Al volver el servidor (o al abrir la app con él encendido): reanuda lo interrumpido
    // y sube el progreso visto sin conexión.
    ref.listen<bool>(remoteProvider.select((r) => r.connected), (prev, next) {
      if (next && prev != true) _onOnline();
    });
    // Con la biblioteca cargada: trae el progreso de otros dispositivos y renueva fichas.
    ref.listen<AsyncValue<List<VideoItem>>>(libraryProvider, (_, next) {
      final l = next.valueOrNull;
      if (l != null && l.isNotEmpty) _onLibrary(l);
    });
    // Las fichas de las series (carátula, sinopsis...) también se renuevan solas.
    ref.listen<AsyncValue<List<ShowItem>>>(showsProvider, (_, next) {
      final l = next.valueOrNull;
      if (l != null) _onShows(l);
    });
    // Si se permiten más descargas a la vez, arrancan las que esperaban.
    ref.listen<AppSettings>(settingsProvider, (prev, next) {
      if (prev != null && next.parallelDownloads > prev.parallelDownloads) {
        _pump();
      }
    });
    return _load();
  }

  // ---------- rutas ----------

  String dirOf(String id) => '${ref.read(downloadsRootProvider)}$_sep$id';
  String showDirOf(String showId) =>
      '${ref.read(downloadsRootProvider)}${_sep}_show_$showId';
  File _f(String id, String name) => File('${dirOf(id)}$_sep$name');
  File _sf(String showId, String name) =>
      File('${showDirOf(showId)}$_sep$name');
  File videoFile(DownloadEntry e) => _f(e.id, 'video${e.ext}');
  File partFile(DownloadEntry e) => _f(e.id, 'video.part');
  File? posterOf(DownloadEntry e) =>
      e.hasPoster ? _f(e.id, 'poster.jpg') : null;
  File? backdropOf(DownloadEntry e) =>
      e.hasBackdrop ? _f(e.id, 'backdrop.jpg') : null;
  File? thumbOf(DownloadEntry e) => e.hasThumb ? _f(e.id, 'thumb.jpg') : null;
  File? stillOf(DownloadEntry e) => e.hasStill ? _f(e.id, 'still.jpg') : null;
  String subtitlePath(DownloadEntry e, String sid) => _f(e.id, 'sub_$sid').path;
  File? showPosterOf(String showId) {
    final m = _shows[showId];
    return m != null && m.hasPoster ? _sf(showId, 'poster.jpg') : null;
  }

  File? showBackdropOf(String showId) {
    final m = _shows[showId];
    return m != null && m.hasBackdrop ? _sf(showId, 'backdrop.jpg') : null;
  }

  // ---------- persistencia ----------

  Map<String, DownloadEntry> _load() {
    final out = <String, DownloadEntry>{};
    _shows.clear();
    final prefs = ref.read(prefsProvider);
    try {
      final raw = prefs.getString(_key);
      if (raw != null) {
        for (final e in jsonDecode(raw) as List) {
          final d = DownloadEntry.fromJson((e as Map).cast<String, dynamic>());
          if (d.state == DlState.done) {
            if (!videoFile(d).existsSync())
              continue; // borraron el archivo a mano
          } else {
            final part = partFile(d);
            d.received = part.existsSync() ? part.lengthSync() : 0;
          }
          out[d.id] = d;
        }
      }
    } catch (_) {}
    try {
      final raw = prefs.getString(_showsKey);
      if (raw != null) {
        for (final e in jsonDecode(raw) as List) {
          final m = ShowMeta.fromJson((e as Map).cast<String, dynamic>());
          if (out.values.any((d) => d.showId == m.id)) _shows[m.id] = m;
        }
      }
    } catch (_) {}
    return out;
  }

  void _save() {
    try {
      final p = ref.read(prefsProvider);
      p.setString(_key, jsonEncode([for (final e in state.values) e.toJson()]));
      p.setString(
          _showsKey, jsonEncode([for (final m in _shows.values) m.toJson()]));
    } catch (_) {}
  }

  void _emit({bool save = false}) {
    state = Map.of(state);
    if (save) _save();
  }

  int get usedBytes => downloadsUsedBytes(state.values);

  // ---------- consultas (series) ----------

  /// Todas las descargas de una serie (cualquier estado), en orden de capítulo.
  List<DownloadEntry> episodesOf(String showId) => [
        for (final e in state.values)
          if (e.showId == showId) e
      ]..sort(_byEpisode);

  /// Solo los capítulos ya descargados por completo.
  List<DownloadEntry> doneEpisodes(String showId) => [
        for (final e in episodesOf(showId))
          if (e.state == DlState.done) e
      ];

  /// Series que tienen algún capítulo en la lista de descargas.
  Set<String> get showIds => {
        for (final e in state.values)
          if (e.showId != null) e.showId!
      };

  /// El capítulo descargado que toca ver: el que quedó a medias o el siguiente al
  /// último visto. null si ya se vieron todos los descargados.
  DownloadEntry? nextEpisode(String showId) {
    final eps = doneEpisodes(showId);
    if (eps.isEmpty) return null;
    DownloadEntry? latest(Iterable<DownloadEntry> l) {
      DownloadEntry? best;
      for (final e in l) {
        if (best == null || e.watchedMs > best.watchedMs) best = e;
      }
      return best;
    }

    final partial = latest(eps.where((e) {
      final p = e.item.progress;
      return p != null && p < 0.95;
    }));
    if (partial != null) return partial;
    final seen = eps.where((e) => e.seen).toList();
    if (seen.isEmpty) return eps.first;
    final i = eps.indexOf(latest(seen)!);
    return i + 1 < eps.length ? eps[i + 1] : null;
  }

  /// Ya empezaste la serie y te quedan capítulos descargados por ver.
  bool showInProgress(String showId) {
    final eps = doneEpisodes(showId);
    final started = eps.any((e) => e.watchedMs > 0 || e.item.progress != null);
    return started && nextEpisode(showId) != null;
  }

  /// La serie como "carátula" para las filas del teatro sin conexión. Con
  /// [forContinue] lleva el capítulo que toca (etiqueta "T1 · E3" y barra).
  VideoItem showCard(String showId, {bool forContinue = false}) {
    final eps = doneEpisodes(showId);
    final m = _shows[showId];
    final s = m?.show;
    final name =
        s?.name ?? (eps.isEmpty ? null : eps.first.item.show) ?? 'Serie';
    final next = forContinue ? nextEpisode(showId)?.item : null;
    return VideoItem(showId, name, 0,
        durationMs: next?.durationMs,
        positionMs: next?.positionMs ?? 0,
        year: s?.year,
        rating: s?.rating,
        overview: s?.overview,
        genres: s?.genres ?? const [],
        posterV: m != null && m.hasPoster ? 1 : 0,
        backdropV: m != null && m.hasBackdrop ? 1 : 0,
        addedMs: eps.fold<int>(0, (a, e) => e.addedMs > a ? e.addedMs : a),
        watchedMs:
            eps.fold<int>(0, (a, e) => e.watchedMs > a ? e.watchedMs : a),
        matched: s?.matched ?? false,
        show: name,
        season: next?.season,
        episode: next?.episode,
        isShow: true);
  }

  // ---------- acciones ----------

  DownloadEntry _newEntry(VideoItem v, int addedMs) => DownloadEntry(
      v.id,
      {
        'item': v.toJson(),
        'audio': <Object>[],
        'subtitles': <Object>[],
        'profile': <String, dynamic>{},
      },
      total: v.size,
      positionMs: v.positionMs,
      watchedMs: v.watchedMs,
      addedMs: addedMs);

  /// Pone varios videos (p. ej. los capítulos de una temporada) en la cola. Lo que ya
  /// estaba descargado o bajando se deja como está; lo pausado o interrumpido se
  /// reanuda. Devuelve cuántos se añadieron o reanudaron.
  int startMany(Iterable<VideoItem> list) {
    final next = Map.of(state);
    final now = DateTime.now().millisecondsSinceEpoch;
    final series = <String>{};
    var n = 0;
    for (final v in list) {
      final cur = next[v.id];
      if (cur == null) {
        next[v.id] = _newEntry(v, now + n);
        n++;
      } else if (cur.state == DlState.paused || cur.state == DlState.error) {
        cur.state = DlState.queued;
        cur.error = null;
        n++;
      } else {
        continue;
      }
      if (v.showId != null) series.add(v.showId!);
    }
    if (n == 0) return 0;
    Sfx.play(Snd.empezarDescarga, force: true);
    state = next;
    _save();
    _pump();
    // La ficha, carátula y fondo de la serie se guardan en segundo plano.
    for (final id in series) {
      unawaited(_ensureShow(id));
    }
    return n;
  }

  /// Empieza a descargar [v] (o reanuda si ya estaba en la lista).
  void start(VideoItem v) => startMany([v]);

  void pause(String id) {
    final e = state[id];
    if (e == null) return;
    if (_running.containsKey(id) && e.state == DlState.downloading) {
      _stop(id, _Stop.pause);
    } else if (e.state == DlState.queued) {
      e.state = DlState.paused;
      _emit(save: true);
    }
  }

  void resume(String id) {
    final e = state[id];
    if (e == null) return;
    if (e.state == DlState.paused || e.state == DlState.error) {
      e.state = DlState.queued;
      e.error = null;
      _emit(save: true);
      _pump();
    }
  }

  List<DownloadEntry> _pick(Iterable<String>? ids) => ids == null
      ? state.values.toList()
      : [
          for (final id in ids)
            if (state[id] != null) state[id]!
        ];

  /// Pausa lo que baja o espera ([ids] null = todas las descargas).
  void pauseAll({Iterable<String>? ids}) {
    for (final e in _pick(ids)) {
      if (e.state == DlState.downloading || e.state == DlState.queued) {
        pause(e.id);
      }
    }
  }

  /// Reanuda lo pausado o interrumpido ([ids] null = todas las descargas).
  void resumeAll({Iterable<String>? ids}) {
    var any = false;
    for (final e in _pick(ids)) {
      if (e.state == DlState.paused || e.state == DlState.error) {
        e.state = DlState.queued;
        e.error = null;
        any = true;
      }
    }
    if (any) {
      _emit(save: true);
      _pump();
    }
  }

  /// Pone la descarga la primera de la cola (la siguiente en bajar).
  void prioritize(String id) {
    final e = state[id];
    if (e == null || e.state == DlState.done) return;
    if (e.state == DlState.paused || e.state == DlState.error) {
      e.state = DlState.queued;
      e.error = null;
    }
    state = {
      id: e,
      for (final o in state.entries)
        if (o.key != id) o.key: o.value,
    };
    _save();
    _pump();
  }

  /// Borra la descarga (y sus archivos). Si estaba bajando, la detiene primero.
  Future<void> delete(String id) => _remove([id]);

  Future<void> deleteMany(Iterable<String> ids) => _remove(ids.toList());

  /// Borra todos los capítulos descargados de una serie y su ficha.
  Future<void> deleteShow(String showId) =>
      _remove([for (final e in episodesOf(showId)) e.id]);

  /// Borra lo ya visto (más del 95 %). Devuelve cuántas descargas quitó.
  Future<int> deleteSeen() async {
    final ids = [
      for (final e in state.values)
        if (e.state == DlState.done && e.seen) e.id
    ];
    await _remove(ids);
    return ids.length;
  }

  Future<void> deleteAll() => _remove(state.keys.toList());

  Future<void> _remove(List<String> ids) async {
    final gone = <DownloadEntry>[];
    for (final id in ids) {
      final e = state[id];
      if (e == null) continue;
      // Las que esperan turno se pausan ya para que la cola no las arranque ahora.
      if (e.state == DlState.queued && !_running.containsKey(id)) {
        e.state = DlState.paused;
      }
      gone.add(e);
    }
    if (gone.isEmpty) return;
    for (final e in gone) {
      final run = _running[e.id];
      if (run == null) continue;
      _stop(e.id, _Stop.delete);
      try {
        await run.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    final next = Map.of(state);
    for (final e in gone) {
      next.remove(e.id);
    }
    state = next;
    final touched = {
      for (final e in gone)
        if (e.showId != null) e.showId!
    };
    final orphan = [
      for (final sid in touched)
        if (!state.values.any((e) => e.showId == sid)) sid
    ];
    for (final sid in orphan) {
      _shows.remove(sid);
    }
    _save();
    for (final e in gone) {
      try {
        final d = Directory(dirOf(e.id));
        if (d.existsSync()) await d.delete(recursive: true);
      } catch (_) {}
    }
    for (final sid in orphan) {
      try {
        final d = Directory(showDirOf(sid));
        if (d.existsSync()) await d.delete(recursive: true);
      } catch (_) {}
    }
    _pump();
  }

  void _stop(String id, _Stop why) {
    _stopWhy[id] = why;
    _cancel[id]?.cancel();
    _subs[id]?.cancel();
    final c = _finish[id];
    if (c != null && !c.isCompleted) c.complete();
  }

  // ---------- cola (hasta N descargas a la vez, según Ajustes) ----------

  void _pump() {
    final limit = ref.read(settingsProvider).parallelDownloads;
    while (_running.length < limit) {
      final next = state.values
          .where(
              (e) => e.state == DlState.queued && !_running.containsKey(e.id))
          .firstOrNull;
      if (next == null) break;
      final id = next.id;
      _running[id] = _run(next).whenComplete(() {
        _running.remove(id);
        _pump();
      });
    }
  }

  void _fail(DownloadEntry e, Object err) {
    e.state = DlState.error;
    e.error = _errMsg(err);
    _emit(save: true);
  }

  Future<void> _run(DownloadEntry e) async {
    final api = ref.read(apiProvider);
    if (api == null) {
      _fail(e, const DownloadException('Sin sesión.'));
      return;
    }
    e.state = DlState.downloading;
    e.error = null;
    _emit(save: true);
    final cancel = _cancel[e.id] = CancelToken();
    try {
      Directory(dirOf(e.id)).createSync(recursive: true);
      await _fetchMeta(api, e, cancel);
      if (!_stopWhy.containsKey(e.id)) await _fetchVideo(api, e, cancel);
      final why = _stopWhy.remove(e.id);
      if (why == _Stop.delete) return; // _remove() se encarga del resto
      if (why == _Stop.pause) {
        e.state = DlState.paused;
        _emit(save: true);
        return;
      }
      e.state = DlState.done;
      e.received = e.total;
      e.error = null;
      _emit(save: true);
    } catch (err) {
      final why = _stopWhy.remove(e.id);
      if (why == _Stop.delete) return;
      if (why == _Stop.pause) {
        e.state = DlState.paused;
        _emit(save: true);
        return;
      }
      _fail(e, err);
    } finally {
      _cancel.remove(e.id);
      _subs.remove(e.id);
      _finish.remove(e.id);
    }
  }

  // ---------- metadatos, carátulas y subtítulos ----------

  /// Descarga la ficha completa, la carátula, el fondo, la miniatura, la imagen del
  /// capítulo y los subtítulos externos. [refresh]: renueva una descarga ya completa
  /// (las imágenes que fallen conservan la copia anterior).
  Future<void> _fetchMeta(Api api, DownloadEntry e, CancelToken? cancel,
      {bool refresh = false}) async {
    final dir = dirOf(e.id);
    e.raw = await api.detailRaw(e.id, cancel: cancel);
    final it = e.detail.item;

    Future<bool> img(String kind, String file) async {
      try {
        final b = await api.imageBytes(e.id, kind, cancel: cancel);
        if (b == null || b.isEmpty) return false;
        final f = File('$dir$_sep$file');
        await f.writeAsBytes(b, flush: true);
        await FileImage(f)
            .evict(); // que no se quede la imagen anterior en caché
        return true;
      } catch (_) {
        if (cancel?.isCancelled ?? false) rethrow;
        return false;
      }
    }

    e.hasPoster = it.posterV > 0
        ? (await img('poster', 'poster.jpg') || (refresh && e.hasPoster))
        : false;
    e.hasBackdrop = it.backdropV > 0
        ? (await img('backdrop', 'backdrop.jpg') || (refresh && e.hasBackdrop))
        : false;
    e.hasThumb =
        (await img('thumbnail', 'thumb.jpg')) || (refresh && e.hasThumb);
    // Imagen propia del capítulo (si el servidor la tiene).
    e.hasStill = it.stillV > 0
        ? (await img('still', 'still.jpg') || (refresh && e.hasStill))
        : false;

    // Subtítulos externos (los incrustados ya vienen dentro del video).
    final subs = <Map<String, String>>[];
    for (final t in e.detail.subtitles) {
      if (!t.external) continue;
      try {
        final txt = await api.subtitleText(e.id, t.id, cancel: cancel);
        if (txt == null) continue;
        await File('$dir${_sep}sub_${t.id}').writeAsString(txt, flush: true);
        subs.add({'id': t.id, 'label': t.label});
      } catch (_) {
        if (cancel?.isCancelled ?? false) rethrow;
      }
    }
    e.subs = subs;

    _emit(save: true);
  }

  /// Ficha, carátula y fondo de una serie para verla sin conexión. Sin [force] solo se
  /// descarga si aún no estaba guardada.
  Future<void> _ensureShow(String showId, {bool force = false}) async {
    final api = ref.read(apiProvider);
    if (api == null || ref.read(serverOfflineProvider)) return;
    if (_shows.containsKey(showId) && !force) return;
    if (!_showBusy.add(showId)) return;
    try {
      final raw = await api.showRaw(showId);
      final m = _shows[showId] ?? ShowMeta(showId, <String, dynamic>{});
      m.raw = {
        'show': raw['show'],
        'profile': raw['profile'] ?? <String, dynamic>{},
      };
      final s = m.show;
      final dir = Directory(showDirOf(showId));
      await dir.create(recursive: true);

      Future<bool> img(String kind, String file) async {
        try {
          final b = await api.imageBytes(showId, kind, show: true);
          if (b == null || b.isEmpty) return false;
          final f = File('${dir.path}$_sep$file');
          await f.writeAsBytes(b, flush: true);
          await FileImage(f).evict();
          return true;
        } catch (_) {
          return false;
        }
      }

      m.hasPoster = s.posterV > 0
          ? (await img('poster', 'poster.jpg') || m.hasPoster)
          : false;
      m.hasBackdrop = s.backdropV > 0
          ? (await img('backdrop', 'backdrop.jpg') || m.hasBackdrop)
          : false;
      if (state.values.any((e) => e.showId == showId)) {
        _shows[showId] = m;
        _emit(save: true);
      } else {
        // Borraron todos sus capítulos mientras se bajaba la ficha.
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {
    } finally {
      _showBusy.remove(showId);
    }
  }

  // ---------- el video (reanudable con HTTP Range) ----------

  Future<void> _fetchVideo(Api api, DownloadEntry e, CancelToken cancel) async {
    final part = partFile(e);
    var have = part.existsSync() ? part.lengthSync() : 0;
    final res = await api.streamVideo(e.id, from: have, cancel: cancel);
    final code = res.statusCode ?? 0;

    if (code == 416) {
      // El rango pedido no existe: o ya estaba completo, o el archivo cambió.
      try {
        await res.data?.stream.drain<void>();
      } catch (_) {}
      final total = _rangeTotal(res.headers.value('content-range'));
      if (total != null && total == have && have > 0) {
        e.total = total;
        e.received = have;
        await _promote(e);
        return;
      }
      if (part.existsSync()) await part.delete();
      return _fetchVideo(api, e, cancel); // otra vez, desde cero
    }

    final ct =
        (res.headers.value('content-type') ?? '').split(';').first.trim();
    e.ext = _extByMime[ct] ?? e.ext;

    // 206 = continúa donde se quedó; 200 = el servidor ignoró Range: empezar de cero.
    final append = code == 206 && have > 0;
    if (!append) have = 0;
    final cl = int.tryParse(res.headers.value('content-length') ?? '') ?? 0;
    final total = append
        ? (_rangeTotal(res.headers.value('content-range')) ?? have + cl)
        : cl;
    if (total > 0) e.total = total;
    e.received = have;
    _emit();

    final sink =
        part.openWrite(mode: append ? FileMode.append : FileMode.write);
    unawaited(sink.done.then((_) {}, onError: (Object _) {}));
    final done = Completer<void>();
    _finish[e.id] = done;
    var lastData = DateTime.now();
    var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
    var unflushed = 0;
    late StreamSubscription<Uint8List> sub;

    // Si el servidor deja de enviar datos (Wi-Fi caído, PC suspendido), se corta.
    final watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!done.isCompleted &&
          DateTime.now().difference(lastData) > const Duration(seconds: 30)) {
        done.completeError(
            const DownloadException('El servidor dejó de responder.'));
      }
    });

    sub = res.data!.stream.listen(
      (chunk) async {
        lastData = DateTime.now();
        sink.add(chunk);
        e.received += chunk.length;
        unflushed += chunk.length;
        if (lastData.difference(lastEmit) > const Duration(milliseconds: 300)) {
          lastEmit = lastData;
          _emit();
        }
        if (unflushed >= 4 * 1024 * 1024) {
          unflushed = 0;
          sub.pause(); // no acumular en memoria si el disco va más lento
          try {
            await sink.flush();
          } catch (err) {
            if (!done.isCompleted) done.completeError(err);
          } finally {
            sub.resume();
          }
        }
      },
      onError: (Object err) {
        if (!done.isCompleted) done.completeError(err);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    _subs[e.id] = sub;

    try {
      await done.future;
    } finally {
      watchdog.cancel();
      await sub.cancel();
      try {
        await sink.flush();
      } catch (_) {}
      try {
        await sink.close();
      } catch (_) {}
    }
    if (_stopWhy.containsKey(e.id))
      return; // pausa o borrado pedidos por el usuario

    final size = part.lengthSync();
    if (e.total > 0 && size != e.total) {
      throw DownloadException(
          'Descarga incompleta (${fmtBytes(size)} de ${fmtBytes(e.total)}).');
    }
    e.total = size;
    await _promote(e);
  }

  /// video.part -> video.<ext>
  Future<void> _promote(DownloadEntry e) async {
    final target = videoFile(e);
    if (target.existsSync()) await target.delete();
    await partFile(e).rename(target.path);
  }

  // ---------- progreso de reproducción (también sin servidor) ----------

  /// Guarda la posición aquí. Se sube al servidor en cuanto se pueda.
  void setPosition(String id, int ms) {
    final e = state[id];
    if (e == null) return;
    e.positionMs = ms;
    e.watchedMs = DateTime.now().millisecondsSinceEpoch;
    e.dirty = true;
    // El reproductor también llama a esto desde dispose(), y Riverpod no admite cambiar
    // un provider en ese momento: la notificación se aplaza al final del fotograma.
    Future.microtask(() {
      _emit(save: true);
      unawaited(syncProgress(only: id));
    });
  }

  /// Pasa a la cola de subida (ProgressSync) el progreso visto con la app sin conexión. Va con
  /// su marca de tiempo original: si por streaming ya se guardó algo más reciente de ese
  /// video, el servidor lo conserva en vez de pisarlo con esta posición vieja.
  Future<void> syncProgress({String? only}) async {
    final sync = ref.read(progressSyncProvider);
    var changed = false;
    for (final e in state.values
        .where((e) => e.dirty && (only == null || e.id == only))
        .toList()) {
      final ts =
          e.watchedMs > 0 ? e.watchedMs : DateTime.now().millisecondsSinceEpoch;
      sync.recordAt(
          e.id, e.positionMs, ts); // la cola persiste y reintenta sola
      e.dirty = false;
      changed = true;
    }
    if (changed) _emit(save: true);
  }

  /// Refleja en la copia descargada lo visto por streaming (ya se sube por ProgressSync), para
  /// que al abrir la descarga no arranque en un punto viejo.
  void mirrorPosition(String id, int ms) {
    final e = state[id];
    if (e == null || e.state != DlState.done || e.positionMs == ms) return;
    e.positionMs = ms;
    e.watchedMs = DateTime.now().millisecondsSinceEpoch;
    // Se llama también desde dispose() del reproductor: se aplaza al final del fotograma.
    Future.microtask(() => _emit(save: true));
  }

  /// Pone a cero el progreso guardado aquí (tras reiniciarlo en el servidor).
  void resetProgressLocal() {
    for (final e in state.values) {
      e.positionMs = 0;
      e.watchedMs = 0;
      e.dirty = false;
    }
    _emit(save: true);
  }

  // ---------- servidor encendido otra vez / biblioteca cargada ----------

  void _onOnline() {
    unawaited(syncProgress());
    // Lo interrumpido se reanuda solo (se puede desactivar en Ajustes → Descargas).
    if (ref.read(settingsProvider).autoResumeDownloads) {
      var any = false;
      for (final e in state.values) {
        if (e.state == DlState.error) {
          e.state = DlState.queued;
          e.error = null;
          any = true;
        }
      }
      if (any) {
        _emit(save: true);
        _pump();
      }
    }
    for (final id in showIds) {
      if (!_shows.containsKey(id)) unawaited(_ensureShow(id));
    }
  }

  bool _stale(DownloadEntry e, VideoItem v) {
    final o = e.detail.item;
    return o.posterV != v.posterV ||
        o.backdropV != v.backdropV ||
        o.stillV != v.stillV ||
        o.title != v.title ||
        o.epTitle != v.epTitle ||
        o.season != v.season ||
        o.episode != v.episode ||
        o.year != v.year ||
        o.overview != v.overview ||
        o.rating != v.rating ||
        o.matched != v.matched ||
        o.genres.join('|') != v.genres.join('|');
  }

  void _onLibrary(List<VideoItem> lib) {
    final byId = {for (final v in lib) v.id: v};
    var changed = false;
    for (final e in state.values) {
      final v = byId[e.id];
      if (v == null || e.state != DlState.done) continue;
      // Lo que aún no subió (cola de ProgressSync) es más reciente que lo del servidor.
      if (!e.dirty &&
          ref.read(progressSyncProvider).pendingTs(e.id) == null &&
          v.positionMs != e.positionMs) {
        e.positionMs = v.positionMs;
        if (v.watchedMs > 0) e.watchedMs = v.watchedMs;
        changed = true;
      }
      // Si se corrigió el perfil en el servidor, la copia local se actualiza sola.
      if (_stale(e, v)) unawaited(_refresh(e.id));
    }
    if (changed) _emit(save: true);
    unawaited(syncProgress());
  }

  /// Renueva la ficha de las series descargadas si cambió en el servidor.
  void _onShows(List<ShowItem> list) {
    final byId = {for (final s in list) s.id: s};
    for (final m in _shows.values.toList()) {
      final s = byId[m.id];
      if (s == null) continue;
      final o = m.show;
      final changed = o.posterV != s.posterV ||
          o.backdropV != s.backdropV ||
          o.name != s.name ||
          o.year != s.year ||
          o.rating != s.rating ||
          o.overview != s.overview ||
          o.episodes != s.episodes ||
          o.genres.join('|') != s.genres.join('|');
      final missing = (s.posterV > 0 && !m.hasPoster) ||
          (s.backdropV > 0 && !m.hasBackdrop);
      if (changed || missing) unawaited(_ensureShow(m.id, force: true));
    }
    for (final id in showIds) {
      if (!_shows.containsKey(id)) unawaited(_ensureShow(id));
    }
  }

  Future<void> _refresh(String id) async {
    final e = state[id];
    final api = ref.read(apiProvider);
    if (e == null || api == null || e.state != DlState.done) return;
    if (!_refreshing.add(id)) return;
    try {
      await _fetchMeta(api, e, null, refresh: true);
    } catch (_) {
    } finally {
      _refreshing.remove(id);
    }
  }
}

final downloadsProvider =
    NotifierProvider<DownloadsNotifier, Map<String, DownloadEntry>>(
        DownloadsNotifier.new);

// ---------------------------------------------------------------------------
//  Acciones de interfaz
// ---------------------------------------------------------------------------

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

String _pct(DownloadEntry e) =>
    e.fraction == null ? '' : '${(e.fraction! * 100).floor()}%';

String _statusText(DownloadEntry e) {
  final bytes = '${fmtBytes(e.received)} de ${fmtBytes(e.total)}';
  return switch (e.state) {
    DlState.queued => 'En cola',
    DlState.downloading => 'Descargando · $bytes',
    DlState.paused => 'Pausada · $bytes',
    DlState.error => '${e.error ?? 'Error'} · $bytes',
    DlState.done => 'En el dispositivo · ${fmtBytes(e.total)}',
  };
}

String _plural(int n, String one, String many) => '$n ${n == 1 ? one : many}';

/// Diálogo de confirmación genérico (true = el usuario aceptó).
Future<bool> confirmAction(
    BuildContext context, String title, String text, String action) async {
  // En TV el foco empieza en "Cancelar": un OK sin querer no borra ni desvincula nada.
  final tv = ProviderScope.containerOf(context).read(tvModeProvider);
  Sfx.play(Snd.alerta, force: true);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(text),
      actions: [
        TextButton(
            autofocus: tv,
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
      ],
    ),
  );
  return ok == true;
}

/// Pregunta y empieza la descarga de una película o de un capítulo.
Future<void> askDownload(
    BuildContext context, WidgetRef ref, VideoItem v) async {
  if (ref.read(serverOfflineProvider)) {
    _snack(context, 'Necesitas conexión con el servidor para descargar.');
    return;
  }
  final ok = await confirmAction(
      context,
      'Descargar',
      '¿Descargar "${v.title}" (${v.sizeLabel})?\n\n'
          'Se guardan el video original, ${v.isEpisode ? 'la imagen' : 'la carátula, el fondo'} '
          'y los datos para verlo con el servidor apagado.',
      'Descargar');
  if (!ok || !context.mounted) return;
  ref.read(downloadsProvider.notifier).start(v);
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Descargando "${v.title}"...'),
      action: SnackBarAction(
          label: 'Ver',
          onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const DownloadsScreen())))));
}

/// Pregunta y pone en cola varios capítulos. [label]: "Toda la serie", "Temporada 2"...
Future<void> askDownloadMany(BuildContext context, WidgetRef ref,
    List<VideoItem> list, String label) async {
  if (ref.read(serverOfflineProvider)) {
    _snack(context, 'Necesitas conexión con el servidor para descargar.');
    return;
  }
  final dls = ref.read(downloadsProvider);
  // Lo que falta: no está en la lista, o quedó pausado / interrumpido.
  bool pending(VideoItem v) {
    final e = dls[v.id];
    return e == null || e.state == DlState.paused || e.state == DlState.error;
  }

  bool seen(VideoItem v) => v.progress != null && v.progress! >= 0.95;
  final todo = [
    for (final v in list)
      if (pending(v)) v
  ];
  if (todo.isEmpty) {
    _snack(context, 'Ya está todo descargado o en la cola.');
    return;
  }
  final hasSeen = todo.any(seen);
  final parallel = ref.read(settingsProvider).parallelDownloads;
  var skipSeen = false;
  final chosen = await showDialog<List<VideoItem>>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final sel = skipSeen
          ? [
              for (final v in todo)
                if (!seen(v)) v
            ]
          : todo;
      final size = sel.fold<int>(0, (s, v) => s + v.size);
      return AlertDialog(
        title: Text('Descargar · $label'),
        content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  '${_plural(sel.length, 'capítulo', 'capítulos')} · ${fmtBytes(size)}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('Se guardan los videos originales, las imágenes y los datos '
                  'para verlos con el servidor apagado. Bajan '
                  '${parallel == 1 ? 'de uno en uno' : '$parallel a la vez'}; '
                  'puedes pausarlos o cancelarlos en Descargas.'),
              if (hasSeen)
                CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: skipSeen,
                    title: const Text('Omitir los ya vistos'),
                    onChanged: (v) => setS(() => skipSeen = v ?? false)),
            ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: sel.isEmpty ? null : () => Navigator.pop(ctx, sel),
              child: const Text('Descargar')),
        ],
      );
    }),
  );
  if (chosen == null || !context.mounted) return;
  final n = ref.read(downloadsProvider.notifier).startMany(chosen);
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${_plural(n, 'capítulo', 'capítulos')} en la cola.'),
      action: SnackBarAction(
          label: 'Ver',
          onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const DownloadsScreen())))));
}

Future<void> _confirmDelete(
    BuildContext context, WidgetRef ref, DownloadEntry e) async {
  final done = e.state == DlState.done;
  final ok = await confirmAction(
      context,
      done ? 'Eliminar descarga' : 'Cancelar descarga',
      done
          ? '¿Quitar "${e.item.title}" de este dispositivo? Seguirá en el servidor.'
          : '¿Cancelar y borrar lo descargado de "${e.item.title}"?',
      done ? 'Eliminar' : 'Cancelar y borrar');
  if (ok) await ref.read(downloadsProvider.notifier).delete(e.id);
}

Future<void> _confirmDeleteShow(
    BuildContext context, WidgetRef ref, String showId, String name) async {
  final dl = ref.read(downloadsProvider.notifier);
  final eps = dl.episodesOf(showId);
  if (eps.isEmpty) return;
  final ok = await confirmAction(
      context,
      'Eliminar serie',
      '¿Quitar de este dispositivo ${_plural(eps.length, 'capítulo', 'capítulos')} de "$name" '
          '(${fmtBytes(downloadsUsedBytes(eps))})? Seguirán en el servidor.',
      'Eliminar');
  if (ok) await dl.deleteShow(showId);
}

/// Elimina lo ya visto (más del 95 %) tras confirmar. Lo usan Descargas y Ajustes.
Future<void> confirmDeleteSeen(BuildContext context, WidgetRef ref) async {
  final seen = [
    for (final e in ref.read(downloadsProvider).values)
      if (e.state == DlState.done && e.seen) e
  ];
  if (seen.isEmpty) {
    _snack(context, 'No hay descargas vistas que eliminar.');
    return;
  }
  final size = downloadsUsedBytes(seen);
  final ok = await confirmAction(
      context,
      'Eliminar lo ya visto',
      'Se quitarán ${_plural(seen.length, 'descarga vista', 'descargas vistas')} de este '
          'dispositivo y se liberarán ${fmtBytes(size)}. Seguirán en el servidor.',
      'Eliminar');
  if (!ok) return;
  await ref.read(downloadsProvider.notifier).deleteSeen();
  if (context.mounted) _snack(context, 'Se liberaron ${fmtBytes(size)}.');
}

/// Elimina todas las descargas tras confirmar. Lo usan Descargas y Ajustes.
Future<void> confirmDeleteAll(BuildContext context, WidgetRef ref) async {
  final all = ref.read(downloadsProvider).values.toList();
  final dlBooks = ref.read(bookDownloadsProvider);
  final copies = dlBooks.copies.values.toList();
  if (all.isEmpty && copies.isEmpty) {
    _snack(context, 'No hay descargas.');
    return;
  }
  final ok = await confirmAction(
      context,
      'Eliminar todas las descargas',
      'Se borrarán ${_plural(all.length + copies.length, 'descarga', 'descargas')} de este dispositivo. '
          'Seguirán en el servidor.',
      'Eliminar todo');
  if (!ok) return;
  final dl = ref.read(downloadsProvider.notifier);
  final api = ref.read(apiProvider);
  final user = ref.read(prefsProvider).getString('profile_username') ?? '';
  for (final c in copies) {
    if (api != null) {
      final key = listeningKey(api, user, c.book);
      if ((await BookPlayback.status(key)).local) await BookPlayback.stop(key);
    }
    await dlBooks.remove(c.book.id);
  }
  await dl.deleteAll();
}

/// Reproduce la copia descargada (no usa el servidor).
Future<void> playDownload(
    BuildContext context, WidgetRef ref, DownloadEntry e) async {
  final dl = ref.read(downloadsProvider.notifier);
  if (!dl.videoFile(e).existsSync()) {
    _snack(context, 'El archivo descargado ya no está en el dispositivo.');
    await dl.delete(e.id);
    return;
  }
  final api = ref.read(apiProvider) ?? Api('', '');
  await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => PlayerScreen(
              api: api,
              item: e.item,
              local: e,
              resume: ResumeInfo(
                  positionMs: e.positionMs,
                  durationMs: e.item.durationMs,
                  source: ResumeSource.local))));
}

void showDownloadSheet(BuildContext context, WidgetRef ref, DownloadEntry e) {
  final dl = ref.read(downloadsProvider.notifier);
  final active = e.state == DlState.downloading || e.state == DlState.queued;
  final waiting = e.state == DlState.queued ||
      e.state == DlState.paused ||
      e.state == DlState.error;
  showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              title: Text(e.item.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(_statusText(e))),
          if (e.state == DlState.done)
            ListTile(
                leading: const Icon(Icons.play_arrow),
                title:
                    Text(e.item.progress != null ? 'Reanudar' : 'Reproducir'),
                onTap: () {
                  Navigator.pop(ctx);
                  playDownload(context, ref, e);
                }),
          if (e.state == DlState.done && e.isEpisode)
            ListTile(
                leading: const Icon(Icons.format_list_numbered),
                title: const Text('Ver capítulos descargados'),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              OfflineShowScreen(showId: e.showId!)));
                }),
          if (active)
            ListTile(
                leading: const Icon(Icons.pause),
                title: const Text('Pausar'),
                onTap: () {
                  Navigator.pop(ctx);
                  dl.pause(e.id);
                }),
          if (e.state == DlState.paused || e.state == DlState.error)
            ListTile(
                leading: const Icon(Icons.play_arrow),
                title: const Text('Reanudar descarga'),
                onTap: () {
                  Navigator.pop(ctx);
                  if (ref.read(serverOfflineProvider)) {
                    _snack(context,
                        'El servidor está apagado. Se reanudará al volver.');
                  }
                  dl.resume(e.id);
                }),
          if (waiting)
            ListTile(
                leading: const Icon(Icons.vertical_align_top),
                title: const Text('Descargar la siguiente'),
                onTap: () {
                  Navigator.pop(ctx);
                  dl.prioritize(e.id);
                }),
          ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(e.state == DlState.done
                  ? 'Eliminar descarga'
                  : 'Cancelar y borrar'),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDelete(context, ref, e);
              }),
        ]),
      ),
    ),
  );
}

/// Botón "Descargar" de la ficha de una película o capítulo; refleja el estado.
class DownloadButton extends ConsumerWidget {
  const DownloadButton({super.key, required this.video});
  final VideoItem video;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = ref.watch(downloadsProvider)[video.id];
    final icon = switch (e?.state) {
      null => Icons.download,
      DlState.queued => Icons.hourglass_top,
      DlState.downloading => Icons.downloading,
      DlState.paused => Icons.pause_circle_outline,
      DlState.error => Icons.error_outline,
      DlState.done => Icons.download_done,
    };
    final label = switch (e?.state) {
      null => 'Descargar',
      DlState.queued => 'En cola',
      DlState.downloading => 'Descargando ${_pct(e!)}',
      DlState.paused => 'Pausada ${_pct(e!)}',
      DlState.error => 'Reanudar ${_pct(e!)}',
      DlState.done => 'Descargada',
    };
    return OutlinedButton.icon(
      onPressed: () => e == null
          ? askDownload(context, ref, video)
          : showDownloadSheet(context, ref, e),
      icon: Icon(icon),
      label: Text(label.trim()),
    );
  }
}

/// Icono de descarga de un capítulo (para la lista de capítulos de una serie).
class EpisodeDownloadIcon extends ConsumerWidget {
  const EpisodeDownloadIcon({super.key, required this.video});
  final VideoItem video;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = ref.watch(downloadsProvider)[video.id];
    final Widget icon = switch (e?.state) {
      null => const Icon(Icons.download_outlined),
      DlState.queued => const Icon(Icons.hourglass_top),
      DlState.downloading => SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
              value: e!.fraction, strokeWidth: 2.5, color: _red)),
      DlState.paused => const Icon(Icons.pause_circle_outline),
      DlState.error =>
        const Icon(Icons.error_outline, color: Colors.orangeAccent),
      DlState.done => const Icon(Icons.download_done, color: Color(0xFF46D369)),
    };
    return IconButton(
      tooltip: e == null ? 'Descargar capítulo' : 'Descarga: opciones',
      icon: icon,
      onPressed: () => e == null
          ? askDownload(context, ref, video)
          : showDownloadSheet(context, ref, e),
    );
  }
}

/// Botón "Descargar" de la ficha de una serie: abre las opciones (toda la serie,
/// una temporada, lo que no has visto...) y refleja cuántos capítulos hay descargados.
class ShowDownloadButton extends ConsumerWidget {
  const ShowDownloadButton({super.key, required this.detail});
  final ShowDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dls = ref.watch(downloadsProvider);
    final eps = detail.episodes;
    var done = 0, active = 0, stuck = 0;
    for (final v in eps) {
      final e = dls[v.id];
      if (e == null) continue;
      if (e.state == DlState.done) {
        done++;
      } else if (e.state == DlState.downloading || e.state == DlState.queued) {
        active++;
      } else {
        stuck++;
      }
    }
    final IconData icon;
    final String label;
    if (active > 0) {
      icon = Icons.downloading;
      label = 'Descargando ($done/${eps.length})';
    } else if (eps.isNotEmpty && done == eps.length) {
      icon = Icons.download_done;
      label = 'Serie descargada';
    } else if (done > 0 || stuck > 0) {
      icon = stuck > 0 ? Icons.pause_circle_outline : Icons.download_done;
      label = 'Descargados $done/${eps.length}';
    } else {
      icon = Icons.download;
      label = 'Descargar';
    }
    return OutlinedButton.icon(
      onPressed: () => showShowDownloadSheet(context, ref, detail),
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

/// Opciones para descargar una serie: completa, por temporada, lo que no has visto...
/// y, si ya hay descargas, pausarlas, reanudarlas o eliminarlas.
void showShowDownloadSheet(
    BuildContext context, WidgetRef ref, ShowDetail det) {
  final eps = det.episodes;
  final dl = ref.read(downloadsProvider.notifier);
  final dls = ref.read(downloadsProvider);
  final seasons = (<int>{for (final v in eps) v.season ?? 0}.toList())..sort();
  String seasonName(int s) => s == 0 ? 'Especiales' : 'Temporada $s';
  bool seen(VideoItem v) => v.progress != null && v.progress! >= 0.95;
  final nextIdx = det.show.nextId == null
      ? -1
      : eps.indexWhere((v) => v.id == det.show.nextId);
  final unseen = [
    for (final v in eps)
      if (!seen(v)) v
  ];
  final mine = dl.episodesOf(det.show.id);
  final anyActive = mine
      .any((e) => e.state == DlState.downloading || e.state == DlState.queued);
  final anyStuck =
      mine.any((e) => e.state == DlState.paused || e.state == DlState.error);

  Widget option(
      BuildContext ctx, IconData icon, String title, List<VideoItem> list) {
    final todo = [
      for (final v in list)
        if (dls[v.id] == null ||
            dls[v.id]!.state == DlState.paused ||
            dls[v.id]!.state == DlState.error)
          v
    ];
    final size = todo.fold<int>(0, (s, v) => s + v.size);
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(todo.isEmpty
          ? 'Ya descargado o en la cola'
          : '${_plural(todo.length, 'capítulo', 'capítulos')} · ${fmtBytes(size)}'),
      enabled: todo.isNotEmpty,
      onTap: () {
        Navigator.pop(ctx);
        askDownloadMany(context, ref, list, title);
      },
    );
  }

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              title: Text(det.show.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: const Text('Descargar para ver sin servidor')),
          option(ctx, Icons.download, 'Toda la serie', eps),
          if (seasons.length > 1)
            for (final s in seasons)
              option(ctx, Icons.video_library_outlined, seasonName(s), [
                for (final v in eps)
                  if ((v.season ?? 0) == s) v
              ]),
          if (unseen.isNotEmpty && unseen.length != eps.length)
            option(ctx, Icons.visibility_off_outlined, 'Capítulos sin ver',
                unseen),
          if (nextIdx > 0)
            option(
                ctx,
                Icons.skip_next_outlined,
                'Desde el capítulo que toca (${eps[nextIdx].episodeLabel})',
                eps.sublist(nextIdx)),
          if (mine.isNotEmpty) ...[
            const Divider(height: 8),
            if (anyActive)
              ListTile(
                  leading: const Icon(Icons.pause),
                  title: const Text('Pausar las descargas de la serie'),
                  onTap: () {
                    Navigator.pop(ctx);
                    dl.pauseAll(ids: [for (final e in mine) e.id]);
                  }),
            if (anyStuck)
              ListTile(
                  leading: const Icon(Icons.play_arrow),
                  title: const Text('Reanudar las descargas de la serie'),
                  onTap: () {
                    Navigator.pop(ctx);
                    if (ref.read(serverOfflineProvider)) {
                      _snack(context,
                          'El servidor está apagado. Se reanudarán al volver.');
                    }
                    dl.resumeAll(ids: [for (final e in mine) e.id]);
                  }),
            ListTile(
                leading: const Icon(Icons.download_for_offline_outlined),
                title: const Text('Ver en Descargas'),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const DownloadsScreen()));
                }),
            ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Eliminar las descargas de la serie'),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmDeleteShow(context, ref, det.show.id, det.show.name);
                }),
          ],
        ]),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
//  Pantalla de descargas (gestión): En curso · Películas · Series
// ---------------------------------------------------------------------------

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  Future<void> _menu(BuildContext context, WidgetRef ref, String v) async {
    final dl = ref.read(downloadsProvider.notifier);
    switch (v) {
      case 'pause':
        dl.pauseAll();
      case 'resume':
        if (ref.read(serverOfflineProvider)) {
          _snack(context, 'El servidor está apagado. Se reanudarán al volver.');
        }
        dl.resumeAll();
      case 'seen':
        await confirmDeleteSeen(context, ref);
      case 'all':
        await confirmDeleteAll(context, ref);
      case 'settings':
        await Navigator.push(
            context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final map = ref.watch(downloadsProvider);
    final offline = ref.watch(serverOfflineProvider);
    final books = ref.watch(bookDownloadsProvider);
    final bookApi = ref.watch(apiProvider);
    final pendingBooks = books.copies.values
        .where((c) => books.progress.containsKey(c.book.id) || !c.complete)
        .toList();
    final all = map.values.toList(); // en el orden de la cola

    final order = {for (var i = 0; i < all.length; i++) all[i].id: i};
    int rank(DownloadEntry e) => switch (e.state) {
          DlState.downloading => 0,
          DlState.queued => 1,
          DlState.paused => 2,
          DlState.error => 3,
          DlState.done => 4,
        };
    final active = [
      for (final e in all)
        if (e.state != DlState.done) e
    ]..sort((a, b) {
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : order[a.id]!.compareTo(order[b.id]!);
      });
    // Posición de cada una en la cola de espera (1.ª, 2.ª...).
    final queuePos = <String, int>{};
    for (final e in all) {
      if (e.state == DlState.queued) queuePos[e.id] = queuePos.length;
    }
    final movies = [
      for (final e in all)
        if (e.state == DlState.done && !e.isEpisode) e
    ]..sort((a, b) => b.addedMs.compareTo(a.addedMs));
    final byShow = <String, List<DownloadEntry>>{};
    for (final e in all) {
      if (e.showId != null) (byShow[e.showId!] ??= []).add(e);
    }
    for (final l in byShow.values) {
      l.sort(_byEpisode);
    }
    final dl = ref.read(downloadsProvider.notifier);
    String showName(String id) =>
        dl.shows[id]?.show.name ??
        byShow[id]!.first.item.show ??
        byShow[id]!.first.item.title;
    final showIds = byShow.keys.toList()
      ..sort((a, b) =>
          showName(a).toLowerCase().compareTo(showName(b).toLowerCase()));

    String count(String t, int n) => n == 0 ? t : '$t ($n)';

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _bg,
          title: const Text('Descargas'),
          actions: [
            PopupMenuButton<String>(
              onSelected: (v) => _menu(context, ref, v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'pause', child: Text('Pausar videos')),
                PopupMenuItem(value: 'resume', child: Text('Reanudar videos')),
                PopupMenuItem(
                    value: 'seen', child: Text('Eliminar lo ya visto')),
                PopupMenuItem(
                    value: 'all', child: Text('Eliminar todas las descargas')),
                PopupMenuDivider(),
                PopupMenuItem(
                    value: 'settings', child: Text('Ajustes de descargas')),
              ],
            ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            indicatorColor: _red,
            tabs: [
              Tab(text: count('En curso', active.length + pendingBooks.length)),
              Tab(text: count('Películas', movies.length)),
              Tab(text: count('Series', showIds.length)),
              Tab(
                  text: count('Audiolibros',
                      ref.watch(bookDownloadsProvider).copies.length)),
            ],
          ),
        ),
        body: Column(children: [
          _DownloadsSummary(entries: all, offline: offline),
          Expanded(
            child: TabBarView(children: [
              active.isEmpty && pendingBooks.isEmpty
                  ? const _Empty(
                      icon: Icons.download_done,
                      text: 'No hay descargas en curso.')
                  : ListView(children: [
                      if (bookApi != null)
                        for (final c in pendingBooks)
                          ListTile(
                              leading: const Icon(Icons.headphones_rounded),
                              title: Text(c.book.title),
                              subtitle: Text(books.progress[c.book.id] == null
                                  ? 'Descarga pendiente'
                                  : 'Descargando · ${(books.progress[c.book.id]! * 100).round()}%'),
                              onTap: () => openBook(context, bookApi, c.book)),
                      for (final e in active)
                        _DownloadTile(entry: e, queuePos: queuePos[e.id]),
                    ]),
              movies.isEmpty
                  ? const _Empty(
                      icon: Icons.movie_outlined,
                      text: 'Aquí aparecen las películas descargadas.\n'
                          'Abre una película con el servidor encendido y pulsa "Descargar".')
                  : ListView(children: [
                      for (final e in movies) _DownloadTile(entry: e),
                    ]),
              showIds.isEmpty
                  ? const _Empty(
                      icon: Icons.tv,
                      text: 'Aquí aparecen las series descargadas.\n'
                          'Abre una serie y pulsa "Descargar" para bajar un capítulo, '
                          'una temporada o toda la serie.')
                  : ListView(children: [
                      for (final id in showIds)
                        _ShowGroup(showId: id, entries: byShow[id]!),
                    ]),
              const DownloadedBooks(),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48, color: Colors.white38),
            const SizedBox(height: 12),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70)),
          ]),
        ),
      );
}

/// Resumen de arriba: espacio usado, cuántas hay y el avance de lo pendiente.
class _DownloadsSummary extends ConsumerWidget {
  const _DownloadsSummary({required this.entries, required this.offline});
  final List<DownloadEntry> entries;
  final bool offline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dl = ref.read(downloadsProvider.notifier);
    final done = entries.where((e) => e.state == DlState.done).length;
    final pending = [
      for (final e in entries)
        if (e.state != DlState.done) e
    ];
    final running = pending.where((e) => e.state == DlState.downloading).length;
    final queued = pending.where((e) => e.state == DlState.queued).length;
    final paused = pending.where((e) => e.state == DlState.paused).length;
    final failed = pending.where((e) => e.state == DlState.error).length;
    final recv = pending.fold<int>(0, (s, e) => s + e.received);
    final tot = pending.fold<int>(0, (s, e) => s + (e.total > 0 ? e.total : 0));
    final parts = [
      if (running > 0) 'bajando $running',
      if (queued > 0) 'en cola $queued',
      if (paused > 0) 'pausadas $paused',
      if (failed > 0) 'con error $failed',
    ];
    return Card(
      color: Colors.white10,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.sd_storage_outlined, color: Colors.white70),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('${fmtBytes(dl.usedBytes)} de video en este dispositivo',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text(
                      '${_plural(done, 'descargada', 'descargadas')}'
                      '${pending.isEmpty ? '' : ' · ${_plural(pending.length, 'pendiente', 'pendientes')}'}',
                      style:
                          const TextStyle(color: Colors.white60, fontSize: 12)),
                ])),
          ]),
          if (pending.isNotEmpty) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
                value: tot > 0 ? (recv / tot).clamp(0.0, 1.0).toDouble() : null,
                color: _red,
                backgroundColor: Colors.white12),
            const SizedBox(height: 6),
            Text('${fmtBytes(recv)} de ${fmtBytes(tot)} · ${parts.join(' · ')}',
                style: const TextStyle(color: Colors.white60, fontSize: 12)),
            if (offline)
              const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                      'Servidor apagado: seguirán al volver a encenderse.',
                      style:
                          TextStyle(color: Colors.orangeAccent, fontSize: 12))),
            Row(children: [
              if (running + queued > 0)
                TextButton.icon(
                    onPressed: dl.pauseAll,
                    icon: const Icon(Icons.pause, size: 18),
                    label: const Text('Pausar todo')),
              if (paused + failed > 0)
                TextButton.icon(
                    onPressed: dl.resumeAll,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Reanudar todo')),
            ]),
          ] else
            const SizedBox(height: 4),
        ]),
      ),
    );
  }
}

/// Fila de una descarga (película o capítulo). [inGroup]: dentro de una serie, donde el
/// título es solo "N. Nombre del capítulo". [queuePos]: puesto en la cola de espera.
class _DownloadTile extends ConsumerWidget {
  const _DownloadTile(
      {required this.entry, this.queuePos, this.inGroup = false});
  final DownloadEntry entry;
  final int? queuePos;
  final bool inGroup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dl = ref.read(downloadsProvider.notifier);
    final e = entry, v = e.item;
    final img =
        (e.isEpisode ? dl.stillOf(e) : null) ?? dl.thumbOf(e) ?? dl.posterOf(e);
    final active = e.state == DlState.downloading || e.state == DlState.queued;
    final title = inGroup && v.episode != null
        ? '${v.episode}. ${v.epTitle ?? v.title}'
        : v.title;
    final status = e.state == DlState.queued && queuePos != null
        ? 'En cola · n.º ${queuePos! + 1}'
        : _statusText(e);
    return ListTile(
      contentPadding: EdgeInsets.only(left: inGroup ? 24 : 16, right: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 96,
          height: 54,
          child: img != null
              ? Image.file(img,
                  fit: BoxFit.cover,
                  cacheWidth: 192,
                  errorBuilder: (_, __, ___) => const ColoredBox(
                      color: Colors.black26, child: Icon(Icons.movie)))
              : const ColoredBox(
                  color: Colors.black26, child: Icon(Icons.movie)),
        ),
      ),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(status,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: e.state == DlState.error ? Colors.orangeAccent : null)),
        if (e.state != DlState.done)
          Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                  value: e.state == DlState.queued ? null : e.fraction,
                  color: _red,
                  backgroundColor: Colors.white12)),
      ]),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (e.state == DlState.done)
          IconButton(
              icon: const Icon(Icons.play_arrow),
              tooltip: 'Reproducir',
              onPressed: () => playDownload(context, ref, e))
        else
          IconButton(
              icon: Icon(active ? Icons.pause : Icons.play_arrow),
              tooltip: active ? 'Pausar' : 'Reanudar',
              onPressed: () => active ? dl.pause(e.id) : dl.resume(e.id)),
        IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: 'Opciones',
            onPressed: () => showDownloadSheet(context, ref, e)),
      ]),
      onTap: () {
        if (e.state != DlState.done) {
          showDownloadSheet(context, ref, e);
        } else if (e.isEpisode) {
          playDownload(context, ref, e);
        } else {
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => OfflineDetailScreen(videoId: e.id)));
        }
      },
      onLongPress: () => showDownloadSheet(context, ref, e),
    );
  }
}

/// Una serie en la pestaña "Series": al abrirla muestra sus capítulos por temporada y
/// los botones para pausar, reanudar, abrirla o eliminarla entera.
class _ShowGroup extends ConsumerWidget {
  const _ShowGroup({required this.showId, required this.entries});
  final String showId;
  final List<DownloadEntry> entries; // ya ordenados por temporada y capítulo

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dl = ref.read(downloadsProvider.notifier);
    final meta = dl.shows[showId];
    final name = meta?.show.name ?? entries.first.item.show ?? 'Serie';
    final poster = dl.showPosterOf(showId);
    final done = entries.where((e) => e.state == DlState.done).length;
    final pending = [
      for (final e in entries)
        if (e.state != DlState.done) e
    ];
    final anyActive = pending.any(
        (e) => e.state == DlState.downloading || e.state == DlState.queued);
    final anyStuck = pending
        .any((e) => e.state == DlState.paused || e.state == DlState.error);
    final total = math.max(meta?.show.episodes ?? 0, entries.length);
    final recv = pending.fold<int>(0, (s, e) => s + e.received);
    final tot = pending.fold<int>(0, (s, e) => s + (e.total > 0 ? e.total : 0));
    final seasons = <int, List<DownloadEntry>>{};
    for (final e in entries) {
      (seasons[e.item.season ?? 0] ??= []).add(e);
    }
    final keys = seasons.keys.toList()..sort();

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: PageStorageKey('dl_show_$showId'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            width: 40,
            height: 60,
            child: poster != null
                ? Image.file(poster,
                    fit: BoxFit.cover,
                    cacheWidth: 120,
                    errorBuilder: (_, __, ___) => const ColoredBox(
                        color: Colors.black26, child: Icon(Icons.tv)))
                : const ColoredBox(
                    color: Colors.black26, child: Icon(Icons.tv)),
          ),
        ),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              '$done de ${_plural(total, 'capítulo', 'capítulos')} · ${fmtBytes(downloadsUsedBytes(entries))}'
              '${pending.isEmpty ? '' : ' · ${pending.length} pendientes'}',
              style: const TextStyle(color: Colors.white60, fontSize: 12)),
          if (pending.isNotEmpty)
            Padding(
                padding: const EdgeInsets.only(top: 4),
                child: LinearProgressIndicator(
                    value: tot > 0
                        ? (recv / tot).clamp(0.0, 1.0).toDouble()
                        : null,
                    color: _red,
                    backgroundColor: Colors.white12)),
        ]),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(spacing: 4, children: [
                if (done > 0)
                  TextButton.icon(
                      onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  OfflineShowScreen(showId: showId))),
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('Abrir serie')),
                if (anyActive)
                  TextButton.icon(
                      onPressed: () =>
                          dl.pauseAll(ids: [for (final e in entries) e.id]),
                      icon: const Icon(Icons.pause, size: 18),
                      label: const Text('Pausar')),
                if (anyStuck)
                  TextButton.icon(
                      onPressed: () =>
                          dl.resumeAll(ids: [for (final e in entries) e.id]),
                      icon: const Icon(Icons.play_arrow, size: 18),
                      label: const Text('Reanudar')),
                TextButton.icon(
                    style:
                        TextButton.styleFrom(foregroundColor: Colors.redAccent),
                    onPressed: () =>
                        _confirmDeleteShow(context, ref, showId, name),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Eliminar')),
              ]),
            ),
          ),
          for (final k in keys) ...[
            if (keys.length > 1)
              Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 16, 0),
                  child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(k == 0 ? 'Especiales' : 'Temporada $k',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.white70)))),
            for (final e in seasons[k]!) _DownloadTile(entry: e, inGroup: true),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  Ficha de una película o capítulo descargado (todo sale de archivos locales)
// ---------------------------------------------------------------------------

class OfflineDetailScreen extends ConsumerWidget {
  const OfflineDetailScreen({super.key, required this.videoId});
  final String videoId;

  String? _runtime(DownloadEntry e) {
    final m = e.profile.runtime;
    if (m == null)
      return e.item.durationMs != null ? e.item.durationLabel : null;
    return m >= 60 ? '${m ~/ 60}h ${m % 60}m' : '${m}m';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = ref.watch(downloadsProvider)[videoId];
    if (e == null || e.state != DlState.done) {
      return Scaffold(
          backgroundColor: _bg,
          appBar: AppBar(backgroundColor: _bg),
          body: const Center(
              child: Text('Esta descarga ya no está disponible.')));
    }
    final dl = ref.read(downloadsProvider.notifier);
    final v = e.item, pr = e.profile;
    final backdrop = dl.backdropOf(e) ?? dl.stillOf(e) ?? dl.thumbOf(e);
    final poster = dl.posterOf(e);
    final w = MediaQuery.of(context).size.width;
    final headerH = (w * 0.56).clamp(240.0, 380.0);
    final title = v.isEpisode ? (v.epTitle ?? v.title) : v.title;
    final meta = <String>[
      if (v.isEpisode) '${v.show} · ${v.episodeLabel}',
      if ((pr.year ?? v.year) != null) '${pr.year ?? v.year}',
      if (_runtime(e) != null) _runtime(e)!,
      if ((pr.rating ?? v.rating) != null)
        '★ ${(pr.rating ?? v.rating)!.toStringAsFixed(1)}',
      if (pr.imdbId != null) 'IMDb ${pr.imdbId}',
    ];
    final overview = pr.overview ?? v.overview;
    final genres = pr.genres.isNotEmpty ? pr.genres : v.genres;

    return Scaffold(
      backgroundColor: _bg,
      extendBodyBehindAppBar: true,
      appBar:
          AppBar(backgroundColor: Colors.transparent, elevation: 0, actions: [
        IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Eliminar descarga',
            onPressed: () async {
              await _confirmDelete(context, ref, e);
              if (context.mounted &&
                  ref.read(downloadsProvider)[videoId] == null) {
                Navigator.of(context).maybePop();
              }
            }),
      ]),
      body: ListView(padding: EdgeInsets.zero, children: [
        SizedBox(
          height: headerH,
          child: Stack(fit: StackFit.expand, children: [
            backdrop != null
                ? Image.file(backdrop,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                    errorBuilder: (_, __, ___) =>
                        const ColoredBox(color: Colors.black26))
                : const ColoredBox(color: Colors.black26),
            const DecoratedBox(
                decoration: BoxDecoration(
                    gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: [0.5, 1.0],
                        colors: [Colors.transparent, _bg]))),
            Positioned(
                left: 16,
                right: 16,
                bottom: 8,
                child: Text(title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        shadows: [
                          Shadow(blurRadius: 12, color: Colors.black87)
                        ]))),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!v.isEpisode && pr.oscars.any) OscarBanner(pr.oscars),
            if (pr.tagline != null)
              Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(pr.tagline!,
                      style: const TextStyle(
                          fontStyle: FontStyle.italic, color: Colors.white60))),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (poster != null)
                Padding(
                    padding: const EdgeInsets.only(right: 14),
                    child: PosterCard(
                        api: ref.read(apiProvider) ?? Api('', ''),
                        item: v,
                        posterFile: poster,
                        width: 110,
                        focusable: false,
                        onTap: () {})),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Wrap(spacing: 12, runSpacing: 4, children: [
                      for (final m in meta)
                        Text(m, style: const TextStyle(color: Colors.white70)),
                    ]),
                    const SizedBox(height: 12),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      FilledButton.icon(
                          autofocus: ref.watch(tvModeProvider),
                          style: FilledButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: Colors.black),
                          onPressed: () => playDownload(context, ref, e),
                          icon: const Icon(Icons.play_arrow),
                          label: Text(
                              v.progress != null ? 'Reanudar' : 'Reproducir')),
                      if (e.isEpisode)
                        OutlinedButton.icon(
                            onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) =>
                                        OfflineShowScreen(showId: e.showId!))),
                            icon: const Icon(Icons.format_list_numbered),
                            label: const Text('Todos los capítulos')),
                    ]),
                    if (v.progress != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: LinearProgressIndicator(
                              value: v.progress,
                              color: _red,
                              backgroundColor: Colors.white12)),
                  ])),
            ]),
            if (overview != null && overview.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(overview, style: const TextStyle(fontSize: 15, height: 1.4)),
            ],
            if (genres.isNotEmpty) ...[
              const SizedBox(height: 16),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final g in genres)
                  Chip(
                      label: Text(g),
                      backgroundColor: Colors.white10,
                      side: BorderSide.none,
                      visualDensity: VisualDensity.compact),
              ]),
            ],
            if (pr.directors.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text('Dirección: ${pr.directors.join(', ')}',
                      style: const TextStyle(color: Colors.white70))),
            if (pr.cast.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Reparto: ${pr.cast.join(', ')}',
                      style: const TextStyle(color: Colors.white70))),
            Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text('${v.infoLabel} · guardada en este dispositivo',
                    style: const TextStyle(color: Colors.white38))),
          ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
//  Ficha de una serie descargada: solo los capítulos que están en el dispositivo
// ---------------------------------------------------------------------------

class OfflineShowScreen extends ConsumerWidget {
  const OfflineShowScreen({super.key, required this.showId});
  final String showId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(downloadsProvider); // se redibuja al cambiar cualquier descarga
    final dl = ref.read(downloadsProvider.notifier);
    final eps = dl.doneEpisodes(showId);
    if (eps.isEmpty) {
      return Scaffold(
          backgroundColor: _bg,
          appBar: AppBar(backgroundColor: _bg),
          body: const Center(
              child: Text('Esta serie ya no tiene capítulos descargados.')));
    }
    final meta = dl.shows[showId];
    final s = meta?.show;
    final pr = meta?.profile ?? const Profile();
    final name = s?.name ?? eps.first.item.show ?? 'Serie';
    final backdrop = dl.showBackdropOf(showId) ??
        dl.stillOf(eps.first) ??
        dl.thumbOf(eps.first);
    final poster = dl.showPosterOf(showId);
    final next = dl.nextEpisode(showId) ?? eps.first;
    final nv = next.item;
    final resuming = nv.progress != null && nv.progress! < 0.95;
    final w = MediaQuery.of(context).size.width;
    final headerH = (w * 0.56).clamp(240.0, 380.0);
    final year = pr.year ?? s?.year;
    final rating = pr.rating ?? s?.rating;
    final overview = pr.overview ?? s?.overview;
    final genres =
        pr.genres.isNotEmpty ? pr.genres : (s?.genres ?? const <String>[]);
    final seasons = ({for (final e in eps) e.item.season ?? 0}.toList())
      ..sort();
    final metaLine = <String>[
      if (year != null) '$year',
      _plural(eps.length, 'capítulo descargado', 'capítulos descargados'),
      if (rating != null) '★ ${rating.toStringAsFixed(1)}',
      if (pr.imdbId != null) 'IMDb ${pr.imdbId}',
    ];
    final rows =
        <Object>[]; // int = título de temporada, DownloadEntry = capítulo
    int? last;
    for (final e in eps) {
      final sn = e.item.season ?? 0;
      if (seasons.length > 1 && sn != last) {
        rows.add(sn);
        last = sn;
      }
      rows.add(e);
    }

    return Scaffold(
      backgroundColor: _bg,
      extendBodyBehindAppBar: true,
      appBar:
          AppBar(backgroundColor: Colors.transparent, elevation: 0, actions: [
        IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Eliminar serie',
            onPressed: () async {
              await _confirmDeleteShow(context, ref, showId, name);
              if (context.mounted && dl.episodesOf(showId).isEmpty) {
                Navigator.of(context).maybePop();
              }
            }),
      ]),
      body: ListView(padding: EdgeInsets.zero, children: [
        SizedBox(
          height: headerH,
          child: Stack(fit: StackFit.expand, children: [
            backdrop != null
                ? Image.file(backdrop,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                    errorBuilder: (_, __, ___) =>
                        const ColoredBox(color: Colors.black26))
                : const ColoredBox(color: Colors.black26),
            const DecoratedBox(
                decoration: BoxDecoration(
                    gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: [0.5, 1.0],
                        colors: [Colors.transparent, _bg]))),
            Positioned(
                left: 16,
                right: 16,
                bottom: 8,
                child: Text(name,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        shadows: [
                          Shadow(blurRadius: 12, color: Colors.black87)
                        ]))),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (pr.oscars.any) OscarBanner(pr.oscars),
            if (pr.tagline != null)
              Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(pr.tagline!,
                      style: const TextStyle(
                          fontStyle: FontStyle.italic, color: Colors.white60))),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (poster != null)
                Padding(
                    padding: const EdgeInsets.only(right: 14),
                    child: PosterCard(
                        api: ref.read(apiProvider) ?? Api('', ''),
                        item: dl.showCard(showId),
                        posterFile: poster,
                        width: 110,
                        focusable: false,
                        onTap: () {})),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Wrap(spacing: 12, runSpacing: 4, children: [
                      for (final m in metaLine)
                        Text(m, style: const TextStyle(color: Colors.white70)),
                    ]),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                        autofocus: ref.watch(tvModeProvider),
                        style: FilledButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.black),
                        onPressed: () => playDownload(context, ref, next),
                        icon: const Icon(Icons.play_arrow),
                        label: Text(
                            '${resuming ? 'Reanudar' : 'Reproducir'} ${nv.episodeLabel}')),
                  ])),
            ]),
            if (overview != null && overview.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(overview, style: const TextStyle(fontSize: 15, height: 1.4)),
            ],
            if (genres.isNotEmpty) ...[
              const SizedBox(height: 16),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final g in genres)
                  Chip(
                      label: Text(g),
                      backgroundColor: Colors.white10,
                      side: BorderSide.none,
                      visualDensity: VisualDensity.compact),
              ]),
            ],
            if (pr.cast.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text('Reparto: ${pr.cast.join(', ')}',
                      style: const TextStyle(color: Colors.white70))),
          ]),
        ),
        for (final r in rows)
          if (r is int)
            Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(r == 0 ? 'Especiales' : 'Temporada $r',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)))
          else
            _OfflineEpisodeTile(entry: r as DownloadEntry),
        const SizedBox(height: 32),
      ]),
    );
  }
}

/// Fila de un capítulo descargado: imagen, "N. Nombre", duración, progreso y sinopsis.
class _OfflineEpisodeTile extends ConsumerWidget {
  const _OfflineEpisodeTile({required this.entry});
  final DownloadEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dl = ref.read(downloadsProvider.notifier);
    final e = entry, v = e.item;
    final img = dl.stillOf(e) ?? dl.thumbOf(e);
    final seen = e.seen;
    final meta = [
      if (v.durationMs != null) v.durationLabel,
      fmtBytes(e.total),
      if (seen) 'Visto',
    ];
    return InkWell(
      focusColor: Colors.white12,
      onTap: () => playDownload(context, ref, e),
      onLongPress: () => showDownloadSheet(context, ref, e),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 136,
              height: 77,
              child: Stack(fit: StackFit.expand, children: [
                img != null
                    ? Image.file(img,
                        fit: BoxFit.cover,
                        cacheWidth: 272,
                        errorBuilder: (_, __, ___) => const ColoredBox(
                            color: Colors.black26,
                            child: Icon(Icons.play_circle_outline,
                                color: Colors.white38)))
                    : const ColoredBox(
                        color: Colors.black26,
                        child: Icon(Icons.play_circle_outline,
                            color: Colors.white38)),
                if (v.progress != null && !seen)
                  Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                          value: v.progress,
                          minHeight: 3,
                          color: _red,
                          backgroundColor: Colors.black54)),
                if (seen)
                  const Positioned(
                      top: 4,
                      right: 4,
                      child: Icon(Icons.check_circle,
                          size: 18, color: Color(0xFF46D369))),
              ]),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(
                    v.episode == null
                        ? v.title
                        : '${v.episode}. ${v.epTitle ?? v.title}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(meta.join(' · '),
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12))),
                if (v.overview != null && v.overview!.isNotEmpty)
                  Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(v.overview!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white60, fontSize: 12))),
              ])),
          IconButton(
              icon: const Icon(Icons.more_vert, size: 20),
              tooltip: 'Opciones',
              visualDensity: VisualDensity.compact,
              onPressed: () => showDownloadSheet(context, ref, e)),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  Modo teatro sin conexión: solo lo descargado (películas y series)
// ---------------------------------------------------------------------------

class OfflineTheaterScreen extends ConsumerStatefulWidget {
  const OfflineTheaterScreen({super.key});
  @override
  ConsumerState<OfflineTheaterScreen> createState() =>
      _OfflineTheaterScreenState();
}

class _OfflineTheaterScreenState extends ConsumerState<OfflineTheaterScreen> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  bool _searching = false, _solid = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final solid = _scroll.hasClients && _scroll.offset > 60;
      if (solid != _solid) setState(() => _solid = solid);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Una serie abre sus capítulos descargados; una película, su ficha.
  void _open(VideoItem v) => Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => v.isShow
              ? OfflineShowScreen(showId: v.id)
              : OfflineDetailScreen(videoId: v.id)));

  void _play(Map<String, DownloadEntry> dls, VideoItem v) {
    final dl = ref.read(downloadsProvider.notifier);
    final e = v.isShow
        ? (dl.nextEpisode(v.id) ?? dl.doneEpisodes(v.id).firstOrNull)
        : dls[v.id];
    if (e != null) playDownload(context, ref, e);
  }

  void _options(Map<String, DownloadEntry> dls, VideoItem v) {
    if (!v.isShow) {
      final e = dls[v.id];
      if (e != null) showDownloadSheet(context, ref, e);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              title:
                  Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: const Text('Serie descargada')),
          ListTile(
              leading: const Icon(Icons.format_list_numbered),
              title: const Text('Ver capítulos descargados'),
              onTap: () {
                Navigator.pop(ctx);
                _open(v);
              }),
          ListTile(
              leading: const Icon(Icons.play_arrow),
              title: const Text('Reproducir siguiente capítulo'),
              onTap: () {
                Navigator.pop(ctx);
                _play(dls, v);
              }),
          ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Eliminar serie'),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDeleteShow(context, ref, v.id, v.title);
              }),
        ]),
      ),
    );
  }

  Widget _bar(double top) {
    final solid = _solid || _searching;
    return Container(
      height: top + 56,
      padding: EdgeInsets.only(top: top, left: 16, right: 4),
      decoration: BoxDecoration(
          color: solid ? _bg : null,
          gradient: solid
              ? null
              : const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black87, Colors.transparent])),
      child: Row(children: [
        if (_searching)
          Expanded(
              child: TvTextEntry(startEditing: true, child: TextField(
                  controller: _search,
                  autofocus: true,
                  decoration: const InputDecoration(
                      hintText: 'Títulos, géneros, años...',
                      border: InputBorder.none),
                  onChanged: (_) => setState(() {}))))
        else
          Expanded(
            child: Row(children: [
              const Flexible(
                child: Text('LUMEN',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: _red,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.5)),
              ),
              const SizedBox(width: 8),
              // Solo el icono: con el texto "SIN CONEXIÓN" la barra se desbordaba en móviles.
              Tooltip(
                message: 'Sin conexión con el servidor',
                child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                        color: Colors.orange.shade900,
                        borderRadius: BorderRadius.circular(4)),
                    child: const Icon(Icons.cloud_off, size: 14)),
              ),
            ]),
          ),
        IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            tooltip: 'Buscar',
            onPressed: () => setState(() {
                  _searching = !_searching;
                  if (!_searching) _search.clear();
                })),
      ]),
    );
  }

  Widget _empty(bool pending) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off, size: 56, color: Colors.white38),
            const SizedBox(height: 16),
            const Text('Servidor apagado',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
                pending
                    ? 'Aún no hay nada descargado por completo. Las descargas '
                        'pendientes continuarán cuando el servidor vuelva a encenderse.'
                    : 'Aquí aparecen las películas y series que descargues. Con el '
                        'servidor encendido, abre una película o una serie y pulsa "Descargar".',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
            if (pending)
              OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const DownloadsScreen())),
                  icon: const Icon(Icons.download_for_offline_outlined),
                  label: const Text('Ver descargas')),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(apiProvider) ?? Api('', '');
    final dls = ref.watch(downloadsProvider);
    final dl = ref.read(downloadsProvider.notifier);
    final done = dls.values.where((e) => e.state == DlState.done).toList();
    final top = MediaQuery.of(context).padding.top;

    // Películas sueltas + una "carátula" por serie con capítulos descargados.
    final movies = [
      for (final e in done)
        if (!e.isEpisode) e.item
    ];
    final showIds = {
      for (final e in done)
        if (e.showId != null) e.showId!
    }.toList();
    final series = [for (final id in showIds) dl.showCard(id)];
    final items = [...movies, ...series];
    final books =
        ref.watch(bookDownloadsProvider).ready.map((c) => c.book).toList();

    File? posterFile(VideoItem v) {
      if (v.isShow) return dl.showPosterOf(v.id);
      final e = dls[v.id];
      return e == null ? null : dl.posterOf(e);
    }

    File? heroImage(VideoItem v) {
      if (v.isShow) {
        final first = dl.doneEpisodes(v.id).firstOrNull;
        return dl.showBackdropOf(v.id) ??
            (first == null ? null : (dl.stillOf(first) ?? dl.thumbOf(first)));
      }
      final e = dls[v.id];
      return e == null ? null : (dl.backdropOf(e) ?? dl.thumbOf(e));
    }

    Widget content;
    if (items.isEmpty && books.isEmpty) {
      content = _empty(dls.isNotEmpty);
    } else if (_searching && _search.text.trim().isNotEmpty) {
      final q = _search.text.trim().toLowerCase();
      final found = items
          .where((v) =>
              v.title.toLowerCase().contains(q) ||
              '${v.year ?? ''}'.contains(q) ||
              v.genres.any((g) => g.toLowerCase().contains(q)))
          .toList();
      final foundBooks = books
          .where((b) => [b.title, b.author, b.narrator]
              .any((v) => v.toLowerCase().contains(q)))
          .toList();
      content = found.isEmpty && foundBooks.isEmpty
          ? const Center(child: Text('Sin resultados'))
          : GridView.builder(
              padding: EdgeInsets.fromLTRB(12, top + 64, 12, 12),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 150,
                  childAspectRatio: 2 / 3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8),
              itemCount: found.length + foundBooks.length,
              itemBuilder: (_, i) => i >= found.length
                  ? AudioBookCard(api: api, book: foundBooks[i - found.length])
                  : PosterCard(
                      api: api,
                      item: found[i],
                      posterFile: posterFile(found[i]),
                      onTap: () => _open(found[i]),
                      onLong: () => _options(dls, found[i])),
            );
    } else {
      // "Continuar viendo": películas a medias y UNA tarjeta por serie en curso
      // (con el capítulo descargado que toca).
      final cont = <VideoItem>[
        for (final v in movies)
          if (v.progress != null && v.progress! < 0.95) v,
        for (final id in showIds)
          if (dl.showInProgress(id)) dl.showCard(id, forContinue: true),
      ]..sort((a, b) => b.watchedMs.compareTo(a.watchedMs));
      final recent = [...items]..sort((a, b) => b.addedMs.compareTo(a.addedMs));
      final hero = cont.isNotEmpty ? cont.first : recent.firstOrNull;

      final rows = <Widget>[];
      void add(String title, List<VideoItem> list,
          {void Function(VideoItem)? onTap, bool newBadge = false}) {
        if (list.isEmpty) return;
        rows.add(ShelfRow(
            title: title,
            items: list,
            api: api,
            newBadge: newBadge,
            posterFile: posterFile,
            onTap: onTap ?? _open,
            onLong: (v) => _options(dls, v)));
      }

      add('Continuar viendo', cont, onTap: (v) => _play(dls, v));
      add('Descargadas recientemente', recent.take(20).toList(),
          newBadge: true);
      if (series.isNotEmpty && movies.isNotEmpty) {
        add('Series', series);
        add('Películas', movies);
      }
      final byGenre = <String, List<VideoItem>>{};
      for (final v in items) {
        for (final g in v.genres) {
          (byGenre[g] ??= []).add(v);
        }
      }
      final genres = byGenre.entries.where((e) => e.value.length >= 2).toList()
        ..sort((a, b) => b.value.length.compareTo(a.value.length));
      for (final g in genres.take(8)) {
        add(g.key, g.value);
      }
      add('Todas las descargas', items);

      content =
          ListView(controller: _scroll, padding: EdgeInsets.zero, children: [
        if (hero == null)
          SizedBox(height: top + 60)
        else
          FeaturedHero(
              api: api,
              item: hero,
              imageFile: heroImage(hero),
              onPlay: () => _play(dls, hero),
              onInfo: () => _open(hero)),
        if (books.isNotEmpty) OfflineBookShelf(api: api, books: books),
        ...rows,
        const SizedBox(height: 32),
      ]);
    }

    return Scaffold(
      backgroundColor: _bg,
      body: Stack(children: [
        Positioned.fill(child: content),
        Positioned(top: 0, left: 0, right: 0, child: _bar(top)),
      ]),
    );
  }
}
