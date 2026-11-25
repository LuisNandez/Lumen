import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shared/shared.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'audiobooks.dart';
import 'avatar_tool.dart';
import 'discovery.dart';
import 'media.dart';
import 'metadata.dart';
import 'remote.dart';
import 'requests.dart';
import 'segments.dart';
import 'series.dart';
import 'transcode.dart';
import 'updates.dart';
import 'users.dart';

const _mimes = {
  '.mp4': 'video/mp4',
  '.m4v': 'video/mp4',
  '.mkv': 'video/x-matroska',
  '.webm': 'video/webm',
  '.avi': 'video/x-msvideo',
  '.mov': 'video/quicktime',
  '.wmv': 'video/x-ms-wmv',
  '.flv': 'video/x-flv',
  '.ts': 'video/mp2t',
};

class Video {
  Video(this.id, this.title, this.path, this.size, this.mtime);
  final String id, title, path;
  final int size, mtime;
  Meta? meta;

  /// Cuándo se añadió a la biblioteca (ms). Se anota la primera vez que se ve el archivo
  /// y no cambia aunque el archivo se modifique después.
  int addedMs = 0;

  /// Datos de capítulo (null = película) y serie a la que pertenece.
  EpisodeInfo? ep;
  String? showId;
}

/// Serie: agrupa los capítulos que comparten carpeta/nombre de serie.
class Show {
  Show(this.id, this.name, this.year);
  final String id, name;
  final int? year;
  final episodes = <Video>[];
}

final videos = <String, Video>{};
final shows = <String, Show>{};
String serverName = Platform.localHostname;

/// Se invoca cuando cambia la biblioteca (p. ej. al terminar de analizar metadatos).
void Function()? onLibraryChanged;

/// Se invoca cuando llega o se quita una petición (para refrescar la ventana del servidor).
void Function()? onRequestsChanged;

/// Se invoca cuando un dispositivo hace una petición nueva (para notificar al dueño).
void Function(NewRequestEvent)? onRequestArrived;
late Tools tools;
late Thumbs thumbs;
late JsonFile metaCache; // id -> {size, mtime, meta}
late Transcoder transcoder;
late Directory subsDir;
late JsonFile
    progress; // id -> positionMs (compartido por todos los dispositivos)
late MetadataStore profiles; // perfiles tipo Plex (TMDB + ediciones manuales)
Auth? _authTop; // para nombrar dispositivos fuera de la clase del servidor
late RequestStore requests; // peticiones de películas (ids de TMDB)
late JsonFile watched; // id -> cuándo (ms) se guardó progreso por última vez
late JsonFile added; // id -> cuándo (ms) se añadió a la biblioteca
late UpdateStore updateStore; // .apk del cliente Android que deja el dueño
late AvatarStore avatars; // .jpg de avatares que deja el dueño del servidor
late UserStore
    users; // perfiles de usuario (nombre, avatar, PIN) y perfil activo por dispositivo
late JsonFile
    news; // novedades: fecha base, primer capítulo de cada serie y lo leído por perfil

/// Dispositivo y perfil de la petición en curso (los fija el middleware mediante una Zone).
const _devKey = #miDevice;
const _userKey = #miUser;
String? _dev() => Zone.current[_devKey] as String?;

/// Nombre de usuario (tal como se escribió) del perfil con el que actúa este dispositivo.
String? _userName() => Zone.current[_userKey] as String?;

/// Clave bajo la que se guarda el progreso en progress.json / watched.json: el perfil activo.
/// (Las claves antiguas, por dispositivo, son 12 caracteres hex y no chocan con "u:...".)
String? _prof() {
  final u = _userName();
  return u == null ? null : 'u:${normalizeUsername(u)}';
}

/// Identificador estable (no reversible) de un dispositivo a partir de su token.
String deviceKeyOf(String token) =>
    sha1.convert(utf8.encode(token)).toString().substring(0, 12);

/// Mapa videoId -> valor del perfil actual dentro de progress.json / watched.json.
/// Cada perfil empieza limpio; sin perfil elegido no se lee ni se guarda nada.
Map<String, dynamic> _mine(JsonFile f) {
  final d = _prof();
  if (d == null) return <String, dynamic>{}; // sin perfil: nada se guarda
  var m = f.data[d];
  if (m is! Map) {
    m = <String, dynamic>{};
    f.data[d] = m;
  }
  return (m as Map).cast<String, dynamic>();
}

Meta? _cached(Video v) {
  final e = metaCache.data[v.id];
  if (e is Map && e['v'] == 2 && e['size'] == v.size && e['mtime'] == v.mtime) {
    return Meta.fromJson((e['meta'] as Map).cast<String, dynamic>());
  }
  return null;
}

Future<void> scan(String root) async {
  final found = <String, Video>{};
  final foundShows = <String, Show>{};
  final loose =
      <Video>[]; // videos que no traen formato de capítulo (S01E02, 1x02...)
  var addedDirty = false;
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  await for (final e in Directory(root).list(recursive: true)) {
    if (e is! File) continue;
    final ext = p.extension(e.path).toLowerCase();
    if (!_mimes.containsKey(ext)) continue;
    final id = sha1.convert(utf8.encode(e.path)).toString().substring(0, 12);
    final st = await e.stat();
    final v = Video(id, p.basenameWithoutExtension(e.path), e.path, st.size,
        st.modified.millisecondsSinceEpoch);
    v.meta = _cached(v);
    // Fecha de alta: la primera vez que se ve el archivo. El mayor entre fecha de
    // modificación y de creación evita que un archivo copiado/movido salga como antiguo.
    final prevAdded = added.data[id];
    if (prevAdded is int) {
      v.addedMs = prevAdded;
    } else {
      final seed = min(
          max(st.modified.millisecondsSinceEpoch,
              st.changed.millisecondsSinceEpoch),
          nowMs);
      v.addedMs = seed;
      added.data[id] = seed;
      addedDirty = true;
    }
    // ¿Es un capítulo? Se mira la carpeta y el nombre del archivo.
    final info = parseEpisode(root, e.path);
    if (info != null) {
      v.ep = info;
      final sid = sha1
          .convert(utf8.encode('show:${info.key}'))
          .toString()
          .substring(0, 12);
      v.showId = sid;
      (foundShows[sid] ??= Show(sid, info.show, info.year)).episodes.add(v);
    } else {
      loose.add(v);
    }
    found[id] = v;
  }

  if (addedDirty) added.save();

  // Videos sin formato de capítulo: 2 o más en la misma carpeta forman una serie.
  final groups = <String, List<Video>>{};
  for (final v in loose) {
    final g = folderGroup(root, v.path);
    if (g != null) (groups[g.key] ??= []).add(v);
  }
  for (final list in groups.values) {
    final g = folderGroup(root, list.first.path)!;
    final sid =
        sha1.convert(utf8.encode('show:${g.key}')).toString().substring(0, 12);
    final existing = foundShows[sid];
    if (existing == null && list.length < 2) continue;
    list.sort((a, b) {
      final c = folderGroup(root, a.path)!
          .season
          .compareTo(folderGroup(root, b.path)!.season);
      return c != 0 ? c : a.path.compareTo(b.path);
    });
    // Siguiente número de capítulo libre en cada temporada.
    final next = <int, int>{};
    for (final v in existing?.episodes ?? const <Video>[]) {
      next[v.ep!.season] = max(next[v.ep!.season] ?? 0, v.ep!.episode);
    }
    final show = existing ?? (foundShows[sid] = Show(sid, g.name, g.year));
    for (final v in list) {
      final season = folderGroup(root, v.path)!.season;
      final n = (next[season] ?? 0) + 1;
      next[season] = n;
      v.ep = EpisodeInfo(g.name, g.key, season, n,
          year: g.year,
          title: v.title.replaceAll(RegExp(r'[._]+'), ' ').trim());
      v.showId = sid;
      show.episodes.add(v);
    }
  }

  for (final s in foundShows.values) {
    s.episodes.sort((a, b) {
      final c = a.ep!.season.compareTo(b.ep!.season);
      if (c != 0) return c;
      final d = a.ep!.episode.compareTo(b.ep!.episode);
      return d != 0 ? d : a.path.compareTo(b.path);
    });
  }
  _migrateMovedProgress(found);
  videos
    ..clear()
    ..addAll(found);
  shows
    ..clear()
    ..addAll(foundShows);
  print(
      'Biblioteca: ${videos.length} videos (${shows.length} series) en $root');
  _updateNewsAnchors();
  unawaited(_probeMissing());
  unawaited(_scrapeAll());
}

/// El id de un video sale de su ruta: si se mueve o renombra el archivo (o cambia la carpeta
/// raíz) el id cambia y el progreso quedaba huérfano. Aquí se busca, por cada id con progreso que
/// ya no existe, UN video nuevo con el mismo tamaño y fecha de modificación (mover o renombrar
/// los conserva; el tamaño y la fecha viejos están en la caché de metadatos) y se le pasa el
/// progreso. Si hay más de un candidato no se toca nada.
void _migrateMovedProgress(Map<String, Video> found) {
  final bySig = <String, List<Video>>{};
  for (final v in found.values) {
    (bySig['${v.size}|${v.mtime}'] ??= []).add(v);
  }
  var moved = 0;
  for (final f in [progress, watched]) {
    var changed = false;
    for (final entry in f.data.entries) {
      final m = entry.value;
      if (m is! Map) continue;
      for (final oldId in m.keys.map((k) => '$k').toList()) {
        if (found.containsKey(oldId)) continue;
        final old = metaCache.data[oldId];
        if (old is! Map) continue;
        final cands = bySig['${old['size']}|${old['mtime']}'];
        if (cands == null || cands.length != 1) continue;
        final target = cands.first.id;
        if (target == oldId || m.containsKey(target)) continue;
        m[target] = m.remove(oldId);
        changed = true;
        if (identical(f, progress)) moved++;
      }
    }
    if (changed) f.save();
  }
  if (moved > 0)
    print(
        '[progreso] $moved posiciones pasadas a archivos movidos o renombrados');
}

bool _scrapingAll = false, _scrapeAgain = false;

/// Identifica en TMDB, en segundo plano, las películas, las series y los nombres de sus capítulos.
Future<void> _scrapeAll() async {
  if (!profiles.enabled) return;
  if (_scrapingAll) {
    _scrapeAgain = true; // llegaron archivos nuevos mientras se identificaba
    return;
  }
  _scrapingAll = true;
  try {
    do {
      _scrapeAgain = false;
      await profiles.autoScrape([
        for (final v in videos.values)
          if (v.ep == null) (id: v.id, title: v.title)
      ], onChange: () => onLibraryChanged?.call());
      for (final s in shows.values.toList()) {
        if (profiles.profile(s.id) == null && !profiles.tried(s.id)) {
          try {
            final r = await profiles.autoMatch(s.id, s.name,
                type: 'tv', year: s.year);
            if (r == null) {
              profiles.markTried(s.id); // sin coincidencia: se corrige a mano
            } else {
              onLibraryChanged?.call();
            }
          } catch (e) {
            print('[serie] TMDB no disponible, se reintentará luego: $e');
            break;
          }
        }
        if (await _syncEpisodes(s) > 0) onLibraryChanged?.call();
      }
    } while (_scrapeAgain);
    // Óscares ganados (Wikidata) de lo ya identificado.
    await profiles.backfillOscars(onChange: () => onLibraryChanged?.call());
    // Clasificación de edades de lo ya identificado.
    await profiles.backfillCertifications(
        onChange: () => onLibraryChanged?.call());
  } finally {
    _scrapingAll = false;
  }
}

/// Pone nombre, sinopsis e imagen a los capítulos de [s] según la ficha de la serie.
/// Con [force] reescribe también los que ya tenían datos (al corregir la serie).
Future<int> _syncEpisodes(Show s, {bool force = false}) async {
  final tmdbId = profiles.profile(s.id)?['tmdbId'];
  if (!profiles.enabled || tmdbId is! int) return 0;
  var n = 0;
  for (final v in s.episodes) {
    final cur = profiles.profile(v.id);
    final legacy = cur?['tmdbId'] !=
        null; // perfil de película puesto por error a un capítulo
    if (!force && ((cur != null && !legacy) || profiles.tried(v.id))) continue;
    try {
      if (await profiles.applyEpisode(
              v.id, tmdbId, v.ep!.season, v.ep!.episode) !=
          null) {
        n++;
      }
    } catch (e) {
      print(
          '[serie] no se pudo leer la temporada ${v.ep!.season} de "${s.name}": $e');
      break;
    }
    await Future.delayed(const Duration(milliseconds: 50));
  }
  return n;
}

bool _probing = false;

/// Analiza en segundo plano (3 a la vez) los videos sin metadatos en caché.
Future<void> _probeMissing() async {
  if (_probing || tools.ffprobe == null) return;
  _probing = true;
  try {
    final todo = videos.values.where((v) => v.meta == null).toList();
    if (todo.isEmpty) return;
    print('Analizando ${todo.length} videos...');
    var i = 0;
    Future<void> worker() async {
      while (i < todo.length) {
        final v = todo[i++];
        final m = await tools.probe(v.path);
        if (m == null) continue;
        v.meta = m;
        metaCache.data[v.id] = {
          'v': 2,
          'size': v.size,
          'mtime': v.mtime,
          'meta': m.toJson()
        };
      }
    }

    await Future.wait(List.generate(3, (_) => worker()));
    metaCache.save();
    print('Metadatos listos.');
    onLibraryChanged?.call();
  } finally {
    _probing = false;
  }
}

// ---------- novedades: capítulos nuevos de series que ya existían ----------
//
// Un capítulo es "nuevo" si su serie ya estaba en la biblioteca cuando llegó: se compara su
// fecha de alta con la del PRIMER capítulo de la serie. Una serie que se añade de golpe (todos
// sus capítulos dentro de [_newsBatchWindowMs] desde el primero) no avisa: lo que llega después
// de esa ventana, sí. Lo anterior a la primera vez que el servidor ejecutó esta función
// ("baselineMs") tampoco avisa, para no llenar las novedades con toda la biblioteca existente.
// Cada perfil tiene lo suyo: qué novedades ya abrió y qué capítulos ya vio.

const _newsBatchWindowMs = 24 * 3600 * 1000;
const _newsKeepMs = 30 * 24 * 3600 * 1000;
const _newsMaxItems = 50;
const _newsMaxRead = 1000;

Map<String, dynamic> _newsMap(Map<String, dynamic> parent, String key) {
  var m = parent[key];
  if (m is! Map) {
    m = <String, dynamic>{};
    parent[key] = m;
  }
  return (m as Map).cast<String, dynamic>();
}

/// Anota la fecha del primer capítulo de cada serie. Nunca se adelanta: si se borran los
/// capítulos antiguos, la serie sigue contando como "ya existente".
void _updateNewsAnchors() {
  final anchors = _newsMap(news.data, 'anchors');
  var dirty = false;
  for (final s in shows.values) {
    if (s.episodes.isEmpty) continue;
    final first = s.episodes.map((v) => v.addedMs).reduce(min);
    final old = anchors[s.id];
    if (old is! int || first < old) {
      anchors[s.id] = first;
      dirty = true;
    }
  }
  if (dirty) news.save();
}

/// Capítulos nuevos de [s] (los que llegaron después del lote inicial de la serie).
List<Video> _newEpisodesOf(Show s, int nowMs) {
  if (s.episodes.isEmpty) return const [];
  final base = (news.data['baselineMs'] as int?) ?? nowMs;
  final stored = (news.data['anchors'] as Map?)?[s.id];
  final anchor =
      stored is int ? stored : s.episodes.map((v) => v.addedMs).reduce(min);
  return [
    for (final v in s.episodes)
      if (v.addedMs > anchor + _newsBatchWindowMs &&
          v.addedMs >= base &&
          nowMs - v.addedMs <= _newsKeepMs)
        v
  ];
}

/// Ids de capítulos cuya novedad el perfil activo ya abrió (null sin perfil).
List<dynamic>? _readNewsIds({bool create = false}) {
  final key = _prof();
  if (key == null) return null;
  final profs = _newsMap(news.data, 'profiles');
  var st = profs[key];
  if (st is! Map) {
    if (!create) return const [];
    st = <String, dynamic>{};
    profs[key] = st;
  }
  final m = (st as Map).cast<String, dynamic>();
  var l = m['read'];
  if (l is! List) {
    if (!create) return const [];
    l = <dynamic>[];
    m['read'] = l;
  }
  return l;
}

/// Novedades del perfil activo: una entrada por serie, la más reciente primero.
Response _getNews(Request req) {
  if (_dev() == null) return Response(401, body: 'No autorizado');
  final now = DateTime.now().millisecondsSinceEpoch;
  final read = <dynamic>{...?_readNewsIds()};
  final rows = <({int latest, Map<String, dynamic> json, bool unread})>[];
  for (final s in shows.values) {
    final eps = _newEpisodesOf(s, now);
    if (eps.isEmpty) continue;
    // Si el perfil ya vio todos los capítulos nuevos, no queda nada que avisar.
    final pending = eps.where((v) => _frac(v) < 0.95).toList();
    if (pending.isEmpty) continue;
    final pr = profiles.profile(s.id);
    final latest = eps.map((v) => v.addedMs).reduce(max);
    final unread = pending.any((v) => !read.contains(v.id));
    rows.add((
      latest: latest,
      unread: unread,
      json: {
        'showId': s.id,
        'show': (pr?['title'] as String?) ?? s.name,
        'posterV': (pr?['posterV'] as int?) ?? 0,
        'backdropV': (pr?['backdropV'] as int?) ?? 0,
        'latestMs': latest,
        'unread': unread,
        'episodes': [
          for (final v in eps)
            () {
              final it = _item(v);
              return {
                'id': v.id,
                'season': v.ep!.season,
                'episode': v.ep!.episode,
                'addedMs': v.addedMs,
                'title': it.epTitle,
                'stillV': it.stillV,
                'durationMs': v.meta?.durationMs,
                'watched': _frac(v) >= 0.95,
              };
            }()
        ],
      },
    ));
  }
  rows.sort((a, b) => b.latest.compareTo(a.latest));
  final top = rows.take(_newsMaxItems).toList();
  return _json({
    'items': [for (final r in top) r.json],
    'unread': top.where((r) => r.unread).length,
  });
}

/// Marca como abierta la novedad de una serie (`{"showId": ...}`) o todas (cuerpo vacío).
Future<Response> _markNewsRead(Request req) async {
  if (_dev() == null) return Response(401, body: 'No autorizado');
  if (_prof() == null) return Response(409, body: 'Elige un perfil primero.');
  final b = await _body(req) ?? <String, dynamic>{};
  final only = _str(b['showId']);
  final now = DateTime.now().millisecondsSinceEpoch;
  final read = _readNewsIds(create: true)!;
  final have = {...read};
  for (final s in shows.values) {
    if (only != null && s.id != only) continue;
    for (final v in _newEpisodesOf(s, now)) {
      if (have.add(v.id)) read.add(v.id);
    }
  }
  // Para que el archivo no crezca sin límite se olvidan los más antiguos.
  if (read.length > _newsMaxRead)
    read.removeRange(0, read.length - _newsMaxRead);
  news.save();
  return _json({'ok': true});
}

VideoItem _item(Video v) {
  final ep = v.ep;
  // Un capítulo que una versión anterior identificó como película (tiene tmdbId) se ignora
  // hasta que se vuelva a sincronizar con los datos de su serie.
  final raw = profiles.profile(v.id);
  final pr = (ep != null && raw?['tmdbId'] != null) ? null : raw;
  final sid = v.showId;
  final sp = sid == null ? null : profiles.profile(sid);
  final showName =
      (sp?['title'] as String?) ?? (sid == null ? null : shows[sid]?.name);
  var title = (pr?['title'] as String?) ?? v.title;
  String? epTitle;
  if (ep != null) {
    // Capítulo: nombre de TMDB, o el que venía en el archivo, o "Episodio N".
    epTitle = (pr?['title'] as String?) ??
        ep.title ??
        (ep.season == 0 ? 'Especial ${ep.episode}' : 'Episodio ${ep.episode}');
    title =
        '$showName · T${ep.season}E${ep.episode.toString().padLeft(2, '0')} · $epTitle';
  }
  final genres =
      (pr?['genres'] as List?) ?? (sp?['genres'] as List?) ?? const [];
  // Un capítulo cuenta como identificado si su serie tiene ficha de TMDB.
  final isMatched = (ep != null ? sp : pr)?['tmdbId'] != null;
  return VideoItem(v.id, title, v.size,
      durationMs: v.meta?.durationMs,
      width: v.meta?.width,
      height: v.meta?.height,
      vcodec: v.meta?.vcodec,
      acodec: v.meta?.acodec,
      positionMs: (_mine(progress)[v.id] as num?)?.toInt() ?? 0,
      year: pr?['year'] as int?,
      rating: (pr?['rating'] as num?)?.toDouble(),
      overview: pr?['overview'] as String?,
      genres: [for (final g in genres) '$g'],
      // Los capítulos heredan la carátula y el fondo de su serie.
      posterV: (pr?['posterV'] as int?) ?? (sp?['posterV'] as int?) ?? 0,
      backdropV: (pr?['backdropV'] as int?) ?? (sp?['backdropV'] as int?) ?? 0,
      addedMs: v.addedMs,
      watchedMs: _watchedAt(v),
      matched: isMatched,
      showId: sid,
      show: showName,
      season: ep?.season,
      episode: ep?.episode,
      epTitle: epTitle,
      stillV: (pr?['stillV'] as int?) ?? 0);
}

int _watchedAt(Video v) => (_mine(watched)[v.id] as num?)?.toInt() ?? 0;

/// Fracción vista de un capítulo (0 = sin empezar).
double _frac(Video v) {
  final pos = (_mine(progress)[v.id] as num?)?.toInt() ?? 0;
  if (pos <= 0) return 0;
  final d = v.meta?.durationMs ?? 0;
  return d > 0 ? pos / d : 0.5;
}

/// Qué toca ver de una serie y si está "en curso".
/// - Se parte del capítulo visto MÁS RECIENTEMENTE (no el de número más alto).
///   Sin fechas (progreso antiguo) gana el de número más alto.
/// - A medias (<95 %): se reanuda ese. Terminado: el siguiente.
/// - Terminado el último capítulo: la serie ya no está en curso.
/// - Los especiales (temporada 0) no cuentan, salvo que sean lo único que hay.
({Video? next, bool inProgress, int watchedMs}) _continueFor(Show s) {
  final all = s.episodes;
  if (all.isEmpty) return (next: null, inProgress: false, watchedMs: 0);
  final main = all.where((v) => v.ep!.season != 0).toList();
  final eps = main.isEmpty ? all : main;
  var li = -1, lt = -1;
  for (var i = 0; i < eps.length; i++) {
    if (_frac(eps[i]) <= 0) continue;
    final t = _watchedAt(eps[i]);
    if (t >= lt) {
      lt = t;
      li = i;
    }
  }
  if (li < 0) return (next: eps.first, inProgress: false, watchedMs: 0);
  if (_frac(eps[li]) < 0.95) {
    return (next: eps[li], inProgress: true, watchedMs: lt);
  }
  if (li + 1 < eps.length) {
    return (next: eps[li + 1], inProgress: true, watchedMs: lt);
  }
  return (next: eps.first, inProgress: false, watchedMs: lt); // serie terminada
}

ShowItem _showItem(Show s) {
  final pr = profiles.profile(s.id);
  final seasons = {for (final v in s.episodes) v.ep!.season};
  final c = _continueFor(s);
  final n = c.next;
  final nFrac = n == null ? 0.0 : _frac(n);
  return ShowItem(s.id, (pr?['title'] as String?) ?? s.name,
      episodes: s.episodes.length,
      seasons: seasons.length,
      year: (pr?['year'] as int?) ?? s.year,
      rating: (pr?['rating'] as num?)?.toDouble(),
      overview: pr?['overview'] as String?,
      genres: [for (final g in (pr?['genres'] as List? ?? const [])) '$g'],
      posterV: (pr?['posterV'] as int?) ?? 0,
      backdropV: (pr?['backdropV'] as int?) ?? 0,
      addedMs: s.episodes.map((v) => v.addedMs).reduce(max),
      matched: pr?['tmdbId'] != null,
      nextId: n?.id,
      inProgress: c.inProgress,
      watchedMs: c.watchedMs,
      nextPositionMs: (n != null && nFrac > 0 && nFrac < 0.95)
          ? ((_mine(progress)[n.id] as num?)?.toInt() ?? 0)
          : 0,
      nextDurationMs: n?.meta?.durationMs,
      nextSeason: n?.ep?.season,
      nextEpisode: n?.ep?.episode);
}

bool _exists(String id) => videos.containsKey(id) || shows.containsKey(id);

Response _json(Object data) => Response.ok(jsonEncode(data),
    headers: {'content-type': 'application/json; charset=utf-8'});

Future<Response> _thumb(Request req, String id) async {
  final v = videos[id];
  if (v == null) return Response.notFound('No existe');
  final f = await thumbs.get(id, v.path, v.meta?.durationMs);
  if (f == null) return Response.notFound('Sin miniatura');
  return Response.ok(f.openRead(), headers: {
    'content-type': p.extension(f.path) == '.png' ? 'image/png' : 'image/jpeg',
    'content-length': '${await f.length()}',
    'cache-control': 'private, max-age=86400',
  });
}

/// Última marca de orden recibida por (dispositivo, video): una posición más vieja que otra ya
/// guardada (petición que llegó tarde y desordenada) se ignora y no pisa la más reciente.
final Map<String, int> _progressTs = {};

Future<Response> _saveProgress(Request req, String id) async {
  if (!videos.containsKey(id)) return Response.notFound('No existe');
  if (_dev() == null) return Response(401, body: 'No autorizado');
  if (_prof() == null) {
    return Response(409, body: 'Elige un perfil para guardar el progreso.');
  }
  var pos = 0;
  int? ts;
  try {
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final n = body['positionMs'] as num;
    pos = n.toInt() < 0 ? 0 : n.toInt();
    ts = (body['ts'] as num?)?.toInt();
  } catch (_) {
    return Response(400, body: 'JSON inválido');
  }
  final key = '${_dev()}|${_prof()}|$id';
  final last = _progressTs[key];
  if (ts != null && last != null && ts < last) {
    // Ya hay una posición con marca mayor de este dispositivo. Se dice cuál es: si el reloj del
    // cliente se atrasó, él sube de nuevo con una marca por encima (no se pierde en silencio).
    return _json({'stale': true, 'lastTs': last});
  }
  if (ts != null) {
    if (_progressTs.length > 5000) _progressTs.clear();
    _progressTs[key] = ts;
  }
  try {
    _mine(progress)[id] = pos;
    progress.save();
    _mine(watched)[id] = DateTime.now().millisecondsSinceEpoch;
    watched.save();
    return Response.ok('ok');
  } catch (e) {
    // Fallo de disco, no del cliente: 500 para que el cliente lo reintente más tarde.
    return Response.internalServerError(
        body: 'No se pudo guardar el progreso.');
  }
}

/// Posición guardada de un video para el perfil que pregunta (ligera: sin sondear el archivo).
Response _getProgress(Request req, String id) {
  if (!videos.containsKey(id)) return Response.notFound('No existe');
  if (_dev() == null) return Response(401, body: 'No autorizado');
  return _json({
    'positionMs': (_mine(progress)[id] as num?)?.toInt() ?? 0,
    'watchedMs': (_mine(watched)[id] as num?)?.toInt() ?? 0,
  });
}

/// Borra todo el progreso y el "Continuar viendo" del perfil que lo pide.
Response _resetProgress(Request req) {
  final d = _prof();
  if (_dev() == null) return Response(401, body: 'No autorizado');
  if (d == null) return Response(409, body: 'Elige un perfil primero.');
  if (progress.data.remove(d) != null) progress.save();
  if (watched.data.remove(d) != null) watched.save();
  _progressTs.removeWhere((k, _) => k.contains('|$d|'));
  return Response.ok('ok');
}

// ---------- perfiles (carátulas, sinopsis, valoración...) ----------
Response _artResponse(String id, String kind) {
  final v = videos[id];
  if (v == null && !shows.containsKey(id))
    return Response.notFound('No existe');
  var f = profiles.art(id, kind);
  // Un capítulo sin imagen propia usa la carátula/fondo de su serie.
  if (f == null && v?.showId != null && kind != 'still') {
    f = profiles.art(v!.showId!, kind);
  }
  if (f == null) return Response.notFound('Sin imagen');
  return Response.ok(f.openRead(), headers: {
    'content-type': 'image/jpeg',
    'content-length': '${f.lengthSync()}',
    'cache-control':
        'private, max-age=604800', // el cliente añade ?v=<versión> al cambiar
  });
}

Response _profileJson(String id) {
  final v = videos[id];
  final base =
      v != null ? _item(v).toJson() : _showItem(shows[id]!).toCard().toJson();
  return _json(
      {'item': base, 'profile': profiles.profile(id) ?? <String, dynamic>{}});
}

Future<Map<String, dynamic>?> _body(Request req) async {
  try {
    return jsonDecode(await req.readAsString()) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

/// Ejecuta una operación de perfil y traduce los fallos a respuestas HTTP claras.
Future<Response> _profileOp(String id, Future<Object?> Function() op) async {
  if (!_exists(id)) return Response.notFound('No existe');
  try {
    final r = await op();
    if (r == null) return Response.notFound('Sin coincidencias en TMDB');
    onLibraryChanged?.call();
    return _profileJson(id);
  } on StateError catch (e) {
    return Response(400, body: e.message);
  } on ArgumentError catch (e) {
    return Response(400, body: '${e.message}');
  } catch (e) {
    print('[perfil] error: $e');
    return Response(502, body: 'No se pudo consultar TMDB: $e');
  }
}

Future<Response> _getProfile(Request req, String id) async =>
    _exists(id) ? _profileJson(id) : Response.notFound('No existe');

Future<Response> _putProfile(Request req, String id) async {
  final b = await _body(req);
  if (b == null) return Response(400, body: 'JSON inválido');
  return _profileOp(id, () => profiles.update(id, b));
}

Future<Response> _deleteProfile(Request req, String id) async {
  if (!_exists(id)) return Response.notFound('No existe');
  profiles.reset(id);
  final s = shows[id];
  if (s != null)
    profiles.forget(s.episodes.map((v) => v.id)); // también sus capítulos
  onLibraryChanged?.call();
  return _profileJson(id);
}

Future<Response> _matchProfile(Request req, String id) async {
  final b = await _body(req);
  final tmdbId = b?['tmdbId'], type = b?['type'];
  if (tmdbId is! int || type is! String)
    return Response(400, body: 'Faltan tmdbId y type');
  // Un capítulo o una serie se enlazan como serie completa.
  final show = shows[videos[id]?.showId ?? id];
  if (show != null) {
    if (type != 'tv')
      return Response(400,
          body: 'Para una serie elige un resultado de tipo Serie.');
    return _profileOp(id, () async {
      final r = await profiles.match(show.id, tmdbId, 'tv');
      await _syncEpisodes(show, force: true);
      return r;
    });
  }
  return _profileOp(id, () => profiles.match(id, tmdbId, type));
}

Future<Response> _autoProfile(Request req, String id) async {
  final v = videos[id];
  final show = shows[v?.showId ?? id];
  if (show != null) {
    return _profileOp(id, () async {
      final r = await profiles.autoMatch(show.id, show.name,
          type: 'tv', year: show.year);
      if (r != null) await _syncEpisodes(show, force: true);
      return r;
    });
  }
  if (v == null) return Response.notFound('No existe');
  return _profileOp(id, () => profiles.autoMatch(id, v.title));
}

Future<Response> _getShow(Request req, String id) async {
  final s = shows[id];
  if (s == null) return Response.notFound('No existe');
  return _json({
    'show': _showItem(s).toJson(),
    'profile': profiles.profile(id) ?? <String, dynamic>{},
    'episodes': [for (final v in s.episodes) _item(v).toJson()],
  });
}

Future<Response> _tmdbSearch(Request req) async {
  if (!profiles.enabled)
    return Response(400, body: 'Falta la clave de TMDB en el servidor.');
  try {
    final q = req.url.queryParameters['q'] ?? '';
    final y = int.tryParse(req.url.queryParameters['year'] ?? '');
    final t = req.url.queryParameters['type'];
    return _json({
      'results': await profiles.search(q,
          year: y, type: (t == 'tv' || t == 'movie') ? t : null)
    });
  } catch (e) {
    return Response(502, body: 'No se pudo consultar TMDB: $e');
  }
}

// ---------- perfiles de usuario (¿quién está viendo?) ----------
// Ojo: nada que ver con los "perfiles" de arriba (fichas de TMDB). Aquí un perfil es una
// persona: nombre de usuario (el identificador), avatar y PIN opcional. El progreso, el
// "Continuar viendo" y las peticiones pertenecen al perfil, no al dispositivo.

String? _str(Object? o) => o is String ? o : null;

String _pathUser(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

Response _userErr(ProfileException e) =>
    Response(e.status, body: e.message, headers: {
      if (e.retryAfterSeconds != null) 'retry-after': '${e.retryAfterSeconds}'
    });

/// ¿Este dispositivo guardó progreso antes de que existieran los perfiles?
bool _hasDeviceProgress() {
  final d = _dev();
  if (d == null) return false;
  final m = progress.data[d];
  return m is Map && m.isNotEmpty;
}

/// Pasa el progreso que el dispositivo [dk] tenía de antes al perfil [username]. Mezcla: lo que
/// el perfil ya tiene se respeta y solo se añade lo que le falta. Devuelve cuántos videos
/// había en el progreso del dispositivo.
int _adoptDeviceProgress(String dk, String username) {
  final key = 'u:${normalizeUsername(username)}';
  var n = 0;
  for (final f in [progress, watched]) {
    final src = f.data[dk];
    if (src is! Map || src.isEmpty) continue;
    if (identical(f, progress)) n = src.length;
    final dst = f.data[key];
    final merged =
        dst is Map ? Map<String, dynamic>.from(dst) : <String, dynamic>{};
    src.forEach((k, v) => merged.putIfAbsent('$k', () => v));
    f.data[key] = merged;
    f.data.remove(dk);
    f.save();
  }
  return n;
}

/// `POST /api/profiles/current/import-progress`: trae al perfil activo el progreso que este
/// dispositivo guardó antes de que existieran los perfiles (se puede pedir en cualquier momento).
Response _importDeviceProgress(Request req) {
  final dk = _dev();
  if (dk == null) return Response(401, body: 'No autorizado');
  final u = _userName();
  if (u == null) return Response(409, body: 'Elige un perfil primero.');
  if (!_hasDeviceProgress()) return _json({'imported': 0});
  final n = _adoptDeviceProgress(dk, u);
  print('[perfil] progreso anterior importado a $u: $n videos');
  return _json({'imported': n});
}

/// Borra lo que colgaba de un perfil: progreso, "Continuar viendo" y sus peticiones.
void _purgeUserData(String username) {
  final key = 'u:${normalizeUsername(username)}';
  if (progress.data.remove(key) != null) progress.save();
  if (watched.data.remove(key) != null) watched.save();
  if (_newsMap(news.data, 'profiles').remove(key) != null) news.save();
  requests.removeUser(username);
  onRequestsChanged?.call();
}

Response _listUsers(Request req) => _json({
      'items': [for (final u in users.list()) u.toJson()],
      'current': _userName(),
      'max': maxProfiles,
      'avatarCount': avatars.scan().length,
      'hasDeviceProgress': _hasDeviceProgress(),
    });

Future<Response> _createUser(Request req) async {
  final dk = _dev();
  if (dk == null) return Response(401, body: 'No autorizado');
  final b = await _body(req);
  if (b == null) return Response(400, body: 'JSON inválido');
  try {
    final pin = _str(b['pin']);
    final u = users.create('${b['username'] ?? ''}',
        avatar: _str(b['avatar']), pin: pin);
    users.select(dk, u.username,
        pin: pin); // el dispositivo pasa a usar el perfil nuevo
    if (b['importProgress'] == true) _adoptDeviceProgress(dk, u.username);
    print('[perfil] nuevo perfil: ${u.username}');
    return _json({'item': u.toJson(), 'current': u.username});
  } on ProfileException catch (e) {
    return _userErr(e);
  }
}

Future<Response> _updateUser(Request req, String name) async {
  final b = await _body(req);
  if (b == null) return Response(400, body: 'JSON inválido');
  try {
    final u = users.update(_pathUser(name),
        setAvatar: b.containsKey('avatar'),
        avatar: _str(b['avatar']),
        newPin: _str(b['pin']),
        removePin: b['removePin'] == true,
        currentPin: _str(b['currentPin']));
    return _json({'item': u.toJson()});
  } on ProfileException catch (e) {
    return _userErr(e);
  }
}

/// El PIN para borrar va en un encabezado (un DELETE no lleva cuerpo y la URL se registra).
Response _deleteUser(Request req, String name) {
  try {
    final n = _pathUser(name);
    final real = users.get(n)?.username ?? n;
    users.delete(n, pin: req.headers['x-profile-pin']);
    _purgeUserData(real);
    print('[perfil] perfil eliminado: $real');
    return _json({'ok': true});
  } on ProfileException catch (e) {
    return _userErr(e);
  }
}

Future<Response> _selectUser(Request req, String name) async {
  final dk = _dev();
  if (dk == null) return Response(401, body: 'No autorizado');
  final b = await _body(req) ?? <String, dynamic>{};
  try {
    final u = users.select(dk, _pathUser(name), pin: _str(b['pin']));
    return _json({'item': u.toJson(), 'current': u.username});
  } on ProfileException catch (e) {
    return _userErr(e);
  }
}

Response _updateInfo(Request req) => _json(
    (updateStore.current?.toInfo() ?? const AppUpdateInfo(available: false))
        .toJson());

Future<Response> _updateApk(Request req) async {
  final a = updateStore.current;
  if (a == null || !a.file.existsSync()) {
    return Response.notFound('No hay actualización');
  }
  final length = a.file.lengthSync();
  final headers = {
    'content-type': 'application/vnd.android.package-archive',
    'accept-ranges': 'bytes',
    'etag': '"${a.sha256}"',
    'content-disposition': 'attachment; filename="${p.basename(a.file.path)}"',
  };
  final range = req.headers['range'];
  if (range == null) {
    return Response.ok(a.file.openRead(),
        headers: {...headers, 'content-length': '$length'});
  }
  final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
  if (m == null || (m.group(1)!.isEmpty && m.group(2)!.isEmpty)) {
    return Response(416, headers: {'content-range': 'bytes */$length'});
  }
  final s = m.group(1)!, e = m.group(2)!;
  int start, end;
  if (s.isEmpty) {
    start = max(0, length - int.parse(e));
    end = length - 1;
  } else {
    start = int.parse(s);
    end = e.isEmpty ? length - 1 : min(int.parse(e), length - 1);
  }
  if (start > end || start >= length) {
    return Response(416, headers: {'content-range': 'bytes */$length'});
  }
  return Response(206, body: a.file.openRead(start, end + 1), headers: {
    ...headers,
    'content-length': '${end - start + 1}',
    'content-range': 'bytes $start-$end/$length',
  });
}

Response _listAvatars(Request req) => _json({
      'items': [for (final a in avatars.list()) a.toJson()]
    });

Response _avatarImage(Request req, String id) {
  final f = avatars.file(_pathUser(id));
  if (f == null) return Response.notFound('No existe ese avatar');
  return Response.ok(f.openRead(), headers: {
    'content-type': 'image/jpeg',
    'content-length': '${f.lengthSync()}',
    'cache-control': 'private, max-age=604800', // el cliente añade ?v=<versión>
  });
}

// ---------- peticiones: explorar TMDB y pedir películas ----------
/// Claves (requestKey) de lo que ya está en la biblioteca: películas y series.
Set<String> _libraryTmdbIds() {
  final out = <String>{};
  for (final v in videos.values) {
    if (v.ep != null) continue;
    final pr = profiles.profile(v.id);
    final t = pr?['tmdbId'];
    if (t is int && pr?['mediaType'] == 'movie') {
      out.add(requestKey(t, 'movie'));
    }
  }
  for (final s in shows.values) {
    final pr = profiles.profile(s.id);
    final t = pr?['tmdbId'];
    if (t is int && pr?['mediaType'] == 'tv') out.add(requestKey(t, 'tv'));
  }
  return out;
}

/// Nombre con el que el dueño del servidor llamó al dispositivo [original] (o el mismo).
String _aliasOf(String original) {
  final au = _authTop;
  if (au == null) return original;
  for (final e in au.devices.entries) {
    if (e.value == original) {
      final a = au.aliases[e.key];
      if (a != null) return a;
    }
  }
  return original;
}

/// El título con sus marcas: si está pedido (y por quién) y si ya está en la biblioteca.
Map<String, dynamic> _requestView(Map<String, dynamic> m, Set<String> owned) {
  final id = m['id'] as int;
  final type = m['type'] == 'tv' ? 'tv' : 'movie';
  final saved = requests.get(id, type);
  return {
    ...m,
    'type': type,
    'requested': saved != null,
    'inLibrary': owned.contains(requestKey(id, type)),
    'by': saved?['by'] ?? const <String>[],
    // Mismos dispositivos con el nombre que les puso el dueño del servidor.
    'byNames': [
      for (final d in (saved?['by'] as List? ?? const [])) _aliasOf('$d')
    ],
    'createdMs': saved?['createdMs'],
  };
}

Future<Response> _discover(Request req) async {
  if (!profiles.enabled) {
    return Response(400, body: 'Falta la clave de TMDB en el servidor.');
  }
  final q = req.url.queryParameters;
  try {
    final r = await profiles.discover(
        list: q['list'] ?? 'popular',
        page: int.tryParse(q['page'] ?? '') ?? 1,
        filters: ExploreFilters.fromQuery(q),
        query: q['q'],
        type: q['type'] == 'tv' ? 'tv' : 'movie');
    final owned = _libraryTmdbIds();
    return _json({
      'page': r.page,
      'totalPages': r.totalPages,
      'totalResults': r.totalResults,
      'items': [for (final m in r.items) _requestView(m, owned)],
    });
  } on ArgumentError catch (e) {
    return Response(400, body: '${e.message}');
  } on StateError catch (e) {
    return Response(400, body: e.message);
  } catch (e) {
    return Response(502, body: 'No se pudo consultar TMDB: $e');
  }
}

Future<Response> _genres(Request req) async {
  if (!profiles.enabled) {
    return Response(400, body: 'Falta la clave de TMDB en el servidor.');
  }
  final type = req.url.queryParameters['type'] == 'tv' ? 'tv' : 'movie';
  try {
    return _json({'genres': await profiles.genres(type)});
  } catch (e) {
    return Response(502, body: 'No se pudo consultar TMDB: $e');
  }
}

/// Tráiler (clave de YouTube) de una película de TMDB, en español latino si existe.
Future<Response> _trailer(Request req, String type, String id) async {
  if (!profiles.enabled) {
    return Response(400, body: 'Falta la clave de TMDB en el servidor.');
  }
  final tmdbId = int.tryParse(id);
  if (tmdbId == null || (type != 'movie' && type != 'tv')) {
    return Response(400, body: 'Id inválido.');
  }
  try {
    return _json({'trailer': await profiles.movieTrailer(tmdbId, type)});
  } catch (e) {
    return Response(502, body: 'No se pudo consultar TMDB: $e');
  }
}

/// Estado de una película o serie (en emisión, finalizada, temporadas...).
Future<Response> _tmdbInfo(Request req, String type, String id) async {
  if (!profiles.enabled) {
    return Response(400, body: 'Falta la clave de TMDB en el servidor.');
  }
  final tmdbId = int.tryParse(id);
  if (tmdbId == null || (type != 'movie' && type != 'tv')) {
    return Response(400, body: 'Id inválido.');
  }
  try {
    return _json(await profiles.info(tmdbId, type));
  } catch (e) {
    return Response(502, body: 'No se pudo consultar TMDB: $e');
  }
}

/// Títulos parecidos a uno de TMDB (sugerencias), con las marcas de pedida y biblioteca.
Future<Response> _recommendations(Request req, String type, String id) async {
  if (!profiles.enabled) {
    return Response(400, body: 'Falta la clave de TMDB en el servidor.');
  }
  final tmdbId = int.tryParse(id);
  if (tmdbId == null || (type != 'movie' && type != 'tv')) {
    return Response(400, body: 'Id inválido.');
  }
  try {
    final r = await profiles.recommendations(tmdbId, type,
        page: int.tryParse(req.url.queryParameters['page'] ?? '') ?? 1);
    final owned = _libraryTmdbIds();
    return _json({
      'page': r.page,
      'totalPages': r.totalPages,
      'totalResults': r.totalResults,
      'items': [for (final m in r.items) _requestView(m, owned)],
    });
  } catch (e) {
    return Response(502, body: 'No se pudo consultar TMDB: $e');
  }
}

Response _listRequests(Request req) {
  final owned = _libraryTmdbIds();
  return _json({
    'items': [for (final e in requests.list()) _requestView(e, owned)],
    // Claves de TMDB de lo que ya está en la biblioteca (para las etiquetas del catálogo).
    'owned': owned.toList(),
  });
}

/// Guarda la petición de una película por su id de TMDB (solo el id y un resumen).
Future<Response> _addRequest(Request req, String device,
    {String? label}) async {
  final b = await _body(req);
  final id = b?['tmdbId'];
  if (id is! int) return Response(400, body: 'Falta tmdbId.');
  final type = b?['type'] == 'tv' ? 'tv' : 'movie';
  final owned = _libraryTmdbIds();
  if (owned.contains(requestKey(id, type))) {
    return Response(409, body: 'Ya está en la biblioteca.');
  }
  var summary =
      requests.get(id, type); // ya pedida: no hace falta volver a TMDB
  if (summary == null) {
    try {
      summary = await profiles.summary(id, type);
    } on StateError catch (e) {
      return Response(400, body: e.message);
    } catch (e) {
      return Response(502, body: 'No se pudo consultar TMDB: $e');
    }
    if (summary == null)
      return Response(404, body: 'TMDB no conoce ese título.');
  }
  final before = [
    for (final e in (summary['by'] as List? ?? const [])) '$e',
  ];
  final saved = requests.add(id, device, summary, type);
  print(
      '[peticion] ${label ?? device} pidió: ${saved['title']} (${saved['year'] ?? '?'})');
  onRequestsChanged?.call();
  // Solo avisa si este dispositivo no la había pedido ya (pedir dos veces no duplica).
  if (!before.contains(device)) {
    onRequestArrived?.call(NewRequestEvent(id, '${saved['title'] ?? ''}',
        year: saved['year'] as int?,
        posterUrl: saved['posterUrl'] as String?,
        device: label ?? device,
        alsoBy: before));
  }
  return _json({'item': _requestView(saved, owned)});
}

/// Quita la petición del dispositivo que llama (si otros la pidieron, siguen pedida).
Response _removeRequest(String rawId, String device, String? rawType) {
  final id = int.tryParse(rawId);
  if (id == null) return Response(400, body: 'Id inválido.');
  final type = rawType == 'tv' ? 'tv' : 'movie';
  final before = requests.get(id, type);
  requests.remove(id, device, type);
  onRequestsChanged?.call();
  return _json({
    'item': before == null ? null : _requestView(before, _libraryTmdbIds())
  });
}

/// Nombre de archivo válido en Windows a partir de un título.
String _safeName(String s) {
  final t = s
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[\s.]+|[\s.]+$'), '');
  return t.isEmpty ? 'Pelicula' : t;
}

/// Copia [src] a [target]. Primero la copia nativa (rápida); si Windows la rechaza (File.copy
/// falla con "no se encuentra" en enlaces simbólicos y archivos de OneDrive), copia leyendo
/// el archivo por streaming. Escribe en "<destino>.part" y lo renombra al terminar, para que
/// el vigilante de la carpeta no tome por video un archivo a medias.
Future<void> _copyFile(File src, String target) async {
  try {
    await src.copy(target);
    return;
  } on FileSystemException catch (e) {
    print(
        '[peticion] copia nativa rechazada (${e.osError?.errorCode}), se copia por streaming');
  }
  final tmp = File('$target.part');
  try {
    final sink = tmp.openWrite();
    await sink.addStream(src.openRead());
    await sink.close();
    await tmp.rename(target);
  } catch (_) {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {}
    rethrow;
  }
}

/// Deja [source] en [target]: lo mueve ([move]) o lo copia. Devuelve true si al mover no se
/// pudo borrar el original (se copió, pero el original sigue donde estaba).
Future<bool> _placeFile(String source, String target,
    {required bool move}) async {
  final src = File(source);
  if (!move) {
    await _copyFile(src, target);
    return false;
  }
  try {
    await src.rename(target);
  } on FileSystemException {
    // Otra unidad o archivo especial (OneDrive...): copiar y borrar el original.
    await _copyFile(src, target);
    try {
      await src.delete();
    } catch (_) {
      return true;
    }
  }
  return false;
}

/// Pone el archivo [source] en la biblioteca como la película pedida [tmdbId] y la enlaza
/// con su ficha de TMDB por id (sin adivinar por el nombre). Va directamente a la raíz:
/// dos videos sueltos en una misma subcarpeta se tomarían por una serie.
Future<String> _fulfillRequest(String root, int tmdbId, String source,
    {required bool move}) async {
  final req = requests.get(tmdbId);
  if (req == null) throw StateError('Esa petición ya no existe.');
  final src = File(source);
  if (!src.existsSync()) throw StateError('No se encuentra el archivo.');
  final ext = p.extension(source).toLowerCase();
  if (!_mimes.containsKey(ext))
    throw StateError('Formato no compatible ($ext).');
  final title = '${req['title'] ?? 'Película $tmdbId'}';
  final year = req['year'];
  final base = _safeName(year is int ? '$title ($year)' : title);
  final target = p.join(root, '$base$ext');
  if (File(target).existsSync()) {
    throw StateError('Ya existe "$base$ext" en la biblioteca.');
  }
  // Ya está identificada: que el escaneo no la busque por el nombre del archivo.
  final newId = sha1.convert(utf8.encode(target)).toString().substring(0, 12);
  profiles.markTried(newId);
  // Mover un archivo conserva su fecha antigua: se marca como añadido ahora.
  added.data[newId] = DateTime.now().millisecondsSinceEpoch;
  added.save();

  final note = await _placeFile(source, target, move: move)
      ? ' (no se pudo borrar el original)'
      : '';

  await scan(root);
  Video? v;
  for (final x in videos.values) {
    if (p.equals(x.path, target)) {
      v = x;
      break;
    }
  }
  if (v == null) {
    throw StateError('Se copió "$base$ext", pero el escaneo no lo encontró.');
  }
  try {
    await profiles.match(v.id, tmdbId, 'movie');
  } catch (e) {
    onLibraryChanged?.call();
    onRequestsChanged?.call();
    return 'Añadida "$base"$note, pero no se pudo traer su ficha de TMDB: $e';
  }
  onLibraryChanged?.call();
  onRequestsChanged?.call();
  return 'Añadida a la biblioteca: $base$note';
}

/// Un capítulo ya decidido: de dónde sale y adónde va.
class _EpisodePlan {
  _EpisodePlan(this.source, this.target, this.season, this.episode);
  final String source, target;
  final int season, episode;
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Añade a la biblioteca los capítulos [eps] de la serie pedida [tmdbId].
///
/// Quedan en `<serie (año)>/Temporada NN/<Serie> SxxExx.ext`, o sea, cada temporada en su
/// subcarpeta dentro de la carpeta de la serie. Si la serie ya está en la biblioteca se usa
/// su misma carpeta (y la subcarpeta de la temporada, si ya existía), así que sirve igual
/// para empezar una serie, completar una temporada o añadir una temporada nueva.
Future<String> _fulfillSeries(String root, int tmdbId, List<EpisodeImport> eps,
    {required bool move}) async {
  final req = requests.get(tmdbId, 'tv');
  if (req == null) throw StateError('Esa petición ya no existe.');
  if (eps.isEmpty) throw StateError('No elegiste ningún capítulo.');

  // Todo se comprueba antes de tocar un solo archivo.
  final seen = <String>{};
  for (final e in eps) {
    final name = p.basename(e.path);
    if (e.season < 0 || e.season > 99) {
      throw StateError('Temporada inválida (${e.season}) en "$name".');
    }
    if (e.episode < 1 || e.episode > 999) {
      throw StateError('Capítulo inválido (${e.episode}) en "$name".');
    }
    if (!seen.add('${e.season}x${e.episode}')) {
      throw StateError(
          'Hay dos archivos para la temporada ${e.season}, capítulo ${e.episode}.');
    }
    if (!File(e.path).existsSync()) {
      throw StateError('No se encuentra "$name".');
    }
    final ext = p.extension(e.path).toLowerCase();
    if (!_mimes.containsKey(ext)) {
      throw StateError('Formato no compatible ($ext) en "$name".');
    }
  }

  final title = '${req['title'] ?? 'Serie $tmdbId'}';
  final year = req['year'];
  final fileBase = _safeName(title);

  // ¿Ya está la serie en la biblioteca? Entonces se sigue usando su carpeta.
  Show? existing;
  for (final s in shows.values) {
    final pr = profiles.profile(s.id);
    if (pr?['tmdbId'] == tmdbId && pr?['mediaType'] == 'tv') {
      existing = s;
      break;
    }
  }
  String? found;
  for (final v in existing?.episodes ?? const <Video>[]) {
    found = showFolder(root, v.path);
    if (found != null) break;
  }
  final showDir =
      found ?? p.join(root, _safeName(year is int ? '$title ($year)' : title));

  String seasonDir(int season) {
    for (final v in existing?.episodes ?? const <Video>[]) {
      if (v.ep!.season != season) continue;
      final d = p.dirname(v.path);
      // Su subcarpeta de temporada, tal como la tenga el usuario ("Season 1"...).
      if (p.isWithin(showDir, d)) return d;
    }
    return p.join(showDir, seasonFolderName(season));
  }

  final plan = <_EpisodePlan>[];
  final skipped = <String>[];
  for (final e in eps) {
    final tag = 'T${e.season} cap. ${e.episode}';
    final inLibrary = existing?.episodes.any(
            (v) => v.ep!.season == e.season && v.ep!.episode == e.episode) ??
        false;
    final ext = p.extension(e.path).toLowerCase();
    final target = p.join(seasonDir(e.season),
        '$fileBase S${_two(e.season)}E${_two(e.episode)}$ext');
    if (inLibrary || File(target).existsSync()) {
      skipped.add(tag);
      continue;
    }
    plan.add(_EpisodePlan(e.path, target, e.season, e.episode));
  }
  if (plan.isEmpty) {
    throw StateError(
        'Esos capítulos ya están en la biblioteca (${skipped.join(', ')}).');
  }

  // La serie ya está identificada: que el escaneo no la busque por el nombre de la carpeta.
  final info = parseEpisode(root, plan.first.target);
  if (info != null) {
    final sid = sha1
        .convert(utf8.encode('show:${info.key}'))
        .toString()
        .substring(0, 12);
    if (profiles.profile(sid) == null) profiles.markTried(sid);
  }

  // Mover un archivo conserva su fecha antigua: se marca como añadido ahora.
  final now = DateTime.now().millisecondsSinceEpoch;
  final placed = <_EpisodePlan>[];
  final failed = <String>[];
  var keptOriginals = 0;
  for (final it in plan) {
    try {
      Directory(p.dirname(it.target)).createSync(recursive: true);
      final id =
          sha1.convert(utf8.encode(it.target)).toString().substring(0, 12);
      added.data[id] = now;
      if (await _placeFile(it.source, it.target, move: move)) keptOriginals++;
      placed.add(it);
    } catch (e) {
      failed.add('T${it.season} cap. ${it.episode}');
      print('[peticion] no se pudo añadir "${p.basename(it.source)}": $e');
    }
  }
  added.save();
  if (placed.isEmpty) {
    throw StateError('No se pudo copiar ningún capítulo.');
  }

  await scan(root);

  // Enlaza la serie con su ficha de TMDB por id y trae los nombres de los capítulos.
  var tmdbNote = '';
  Show? show;
  for (final v in videos.values) {
    if (p.equals(v.path, placed.first.target)) {
      show = shows[v.showId];
      break;
    }
  }
  if (show == null) {
    tmdbNote = ' No se reconocieron como capítulos de una serie.';
  } else {
    try {
      if (profiles.profile(show.id) == null) {
        await profiles.match(show.id, tmdbId, 'tv');
      }
      await _syncEpisodes(show);
    } catch (e) {
      tmdbNote = ' No se pudo traer la ficha de TMDB: $e';
    }
  }
  onLibraryChanged?.call();
  onRequestsChanged?.call();

  final seasons = (placed.map((e) => e.season).toSet().toList()..sort())
      .map((s) => s == 0 ? 'Especiales' : 'T$s')
      .join(', ');
  final n = placed.length;
  final sb = StringBuffer(n == 1
      ? 'Se añadió 1 capítulo a "$title" ($seasons).'
      : 'Se añadieron $n capítulos a "$title" ($seasons).');
  if (skipped.isNotEmpty) sb.write(' Ya estaban: ${skipped.join(', ')}.');
  if (failed.isNotEmpty) sb.write(' Fallaron: ${failed.join(', ')}.');
  if (keptOriginals > 0) {
    sb.write(' No se pudo borrar el original de $keptOriginals.');
  }
  sb.write(tmdbNote);
  return sb.toString();
}

const _textSubs = {'subrip', 'srt', 'ass', 'ssa', 'mov_text', 'webvtt', 'text'};

String _trackLabel(Map<String, dynamic> t, int i) {
  final title = t['title'] as String?, lang = t['lang'] as String?;
  final parts = [
    if (title != null && title.isNotEmpty) title,
    if (lang != null && lang.isNotEmpty) lang.toUpperCase(),
    if (t['codec'] != null) '${t['codec']}',
    if (t['ch'] != null) '${t['ch']}ch',
  ];
  return parts.isEmpty ? 'Pista ${i + 1}' : parts.join(' · ');
}

/// Subtítulos junto al video: "Nombre.es.srt", "Nombre.srt", etc.
List<File> _sidecars(Video v) {
  final base = p.basenameWithoutExtension(v.path).toLowerCase();
  try {
    return Directory(p.dirname(v.path)).listSync().whereType<File>().where((f) {
      final n = p.basename(f.path).toLowerCase();
      return const ['.srt', '.vtt', '.ass', '.ssa'].contains(p.extension(n)) &&
          n.startsWith(base);
    }).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  } catch (_) {
    return [];
  }
}

Future<Response> _detail(Request req, String id) async {
  final sh = shows[id];
  if (sh != null) {
    // Una serie se edita con el mismo editor de perfil que una película.
    return _json({
      'item': _showItem(sh).toCard().toJson(),
      'audio': <Object>[],
      'subtitles': <Object>[],
      'profile': profiles.profile(id) ?? <String, dynamic>{},
    });
  }
  final v = videos[id];
  if (v == null) return Response.notFound('No existe');
  v.meta ??= await tools.probe(v.path);
  final m = v.meta;
  final audio = [
    for (var i = 0; i < (m?.audio.length ?? 0); i++)
      TrackInfo('$i', _trackLabel(m!.audio[i], i)),
  ];
  final subs = <TrackInfo>[
    for (var i = 0; i < (m?.subs.length ?? 0); i++)
      TrackInfo('e$i.srt', 'Incrustado: ${_trackLabel(m!.subs[i], i)}',
          text: _textSubs.contains(m.subs[i]['codec'])),
  ];
  final side = _sidecars(v);
  final base = p.basenameWithoutExtension(v.path);
  for (var k = 0; k < side.length; k++) {
    final tag = p
        .basenameWithoutExtension(side[k].path)
        .substring(base.length)
        .replaceAll(RegExp(r'^[.\s_-]+'), '');
    subs.add(TrackInfo('x$k${p.extension(side[k].path)}',
        'Externo: ${tag.isEmpty ? p.extension(side[k].path).substring(1).toUpperCase() : tag}',
        external: true));
  }
  final prof = <String, dynamic>{...?profiles.profile(id)};
  // Un capítulo hereda la clasificación de edades de su serie.
  final sp = v.showId == null ? null : profiles.profile(v.showId!);
  if (prof['certification'] == null && sp?['certification'] != null) {
    prof['certification'] = sp!['certification'];
    prof['certCountry'] = sp['certCountry'];
  }
  return _json({
    'item': _item(v).toJson(),
    'audio': audio.map((t) => t.toJson()).toList(),
    'subtitles': subs.map((t) => t.toJson()).toList(),
    'profile': prof,
  });
}

/// Marcas para saltar intro/resumen y datos del capítulo siguiente.
Future<Response> _segments(Request req, String id) async {
  final v = videos[id];
  if (v == null) return Response.notFound('No existe');
  final ep = v.ep;
  var found = <String, List<Map<String, int?>>>{};
  Map<String, String>? next;
  if (ep != null) {
    // TheIntroDB identifica el capítulo por el id de TMDB de la serie + temporada + número.
    final sid = v.showId;
    final tmdb = sid == null ? null : profiles.profile(sid)?['tmdbId'];
    if (tmdb is int) {
      found =
          await introDb.lookup(tmdb, ep.season, ep.episode, v.meta?.durationMs);
    }
    final sh = sid == null ? null : shows[sid];
    if (sh != null) {
      final i = sh.episodes.indexWhere((e) => e.id == v.id);
      if (i >= 0 && i + 1 < sh.episodes.length) {
        final n = sh.episodes[i + 1];
        // No saltar de un capítulo normal a los "especiales" (temporada 0).
        if (ep.season == 0 || (n.ep?.season ?? 1) != 0) {
          final it = _item(n);
          next = {'id': n.id, 'title': it.epTitle ?? it.title};
        }
      }
    }
  }
  return _json({...found, 'next': next});
}

final _subInflight = <String, Future<File?>>{};

Future<File?> _extractSub(Video v, int n) {
  final key = '${v.id}_$n';
  return _subInflight.putIfAbsent(
      key,
      () => _doExtractSub(v, n).whenComplete(() {
            _subInflight.remove(key); // con llaves: no debe devolver la Future
          }));
}

Future<File?> _doExtractSub(Video v, int n) async {
  final out = File(p.join(subsDir.path, '${v.id}_$n.srt'));
  if (out.existsSync()) return out;
  final ff = tools.ffmpeg;
  if (ff == null) return null;
  final tmp = '${out.path}.tmp.srt';
  try {
    final r = await Process.run(ff, [
      '-y',
      '-v',
      'error',
      '-i',
      v.path,
      '-map',
      '0:s:$n',
      '-c:s',
      'srt',
      tmp
    ]);
    if (r.exitCode == 0 && File(tmp).existsSync()) {
      await File(tmp).rename(out.path);
      return out;
    }
  } catch (_) {}
  return null;
}

/// Entrega subtítulos siempre en UTF-8 (muchos .srt en español vienen en Latin-1).
Future<Response> _subtitle(Request req, String id, String sid) async {
  final v = videos[id];
  if (v == null) return Response.notFound('No existe');
  final key = sid.split('.').first;
  final idx = int.tryParse(key.length > 1 ? key.substring(1) : '');
  if (idx == null) return Response.notFound('Subtítulo inválido');
  File? file;
  if (key.startsWith('x')) {
    final list = _sidecars(v);
    if (idx < list.length) file = list[idx];
  } else if (key.startsWith('e')) {
    file = await _extractSub(v, idx);
  }
  if (file == null) return Response.notFound('No disponible');
  final bytes = await file.readAsBytes();
  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    text = latin1.decode(bytes);
  }
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  return Response.ok(text,
      headers: {'content-type': 'text/plain; charset=utf-8'});
}

/// Playlist VOD completa (se conoce la duración) y segmentos generados al vuelo.
Future<Response> _hls(Request req, String id, String name) async {
  final v = videos[id];
  if (v == null) return Response.notFound('No existe');
  final q = int.tryParse(req.url.queryParameters['q'] ?? '') ?? 720;
  final a = int.tryParse(req.url.queryParameters['a'] ?? '') ?? 0;
  if (!hlsRates.containsKey(q) || a < 0)
    return Response(400, body: 'Parámetros inválidos');
  if (tools.ffmpeg == null) return Response(501, body: 'ffmpeg no disponible');
  v.meta ??= await tools.probe(v.path);
  final durMs = v.meta?.durationMs;
  if (durMs == null) return Response(500, body: 'Duración desconocida');
  final total = (durMs / (segLen * 1000)).ceil();

  if (name == 'index.m3u8') {
    final qs =
        'q=$q&a=$a&token=${Uri.encodeQueryComponent(requestToken(req) ?? '')}';
    final b = StringBuffer(
        '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:$segLen\n'
        '#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n');
    for (var s = 0; s < total; s++) {
      final d = s < total - 1 ? segLen.toDouble() : durMs / 1000 - s * segLen;
      b.write('#EXTINF:${d.toStringAsFixed(3)},\nseg_$s.ts?$qs\n');
    }
    b.write('#EXT-X-ENDLIST\n');
    return Response.ok(b.toString(), headers: {
      'content-type': 'application/vnd.apple.mpegurl',
      'cache-control': 'no-store',
    });
  }

  final m = RegExp(r'^seg_(\d+)\.ts$').firstMatch(name);
  if (m == null) return Response.notFound('No existe');
  final i = int.parse(m.group(1)!);
  if (i >= total) return Response.notFound('Fuera de rango');
  final f = await transcoder.segment(id, v.path, q, a, i);
  if (f == null)
    return Response(504, body: 'La transcodificación falló o tardó demasiado');
  return Response.ok(f.openRead(), headers: {
    'content-type': 'video/mp2t',
    'content-length': '${await f.length()}',
    'cache-control': 'no-store',
  });
}

/// Sirve el archivo con soporte de HTTP Range (206) para poder hacer seek.
Future<Response> _stream(Request req, String id) async {
  final v = videos[id];
  if (v == null) return Response.notFound('No existe');
  return _serveFile(
      req, File(v.path), _mimes[p.extension(v.path).toLowerCase()]!);
}

Future<Response> _serveFile(Request req, File file, String mime) async {
  if (!await file.exists()) return Response.notFound('Archivo no disponible');
  final length = await file.length();
  final headers = {
    'content-type': mime,
    'accept-ranges': 'bytes',
  };

  final range = req.headers['range'];
  if (range == null) {
    return Response.ok(file.openRead(),
        headers: {...headers, 'content-length': '$length'});
  }

  final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
  if (m == null)
    return Response(416, headers: {'content-range': 'bytes */$length'});

  final a = m.group(1)!, b = m.group(2)!;
  int start, end;
  if (a.isEmpty) {
    if (b.isEmpty)
      return Response(416, headers: {'content-range': 'bytes */$length'});
    start = max(0, length - int.parse(b));
    end = length - 1;
  } else {
    start = int.parse(a);
    end = b.isEmpty ? length - 1 : min(int.parse(b), length - 1);
  }
  if (start > end || start >= length) {
    return Response(416, headers: {'content-range': 'bytes */$length'});
  }

  return Response(206, body: file.openRead(start, end + 1), headers: {
    ...headers,
    'content-length': '${end - start + 1}',
    'content-range': 'bytes $start-$end/$length',
  });
}

/// Una película o serie de la biblioteca tal como la ve la ventana del servidor.
class LibraryEntry {
  const LibraryEntry({
    required this.id,
    required this.title,
    required this.fileName,
    required this.isShow,
    required this.matched,
    required this.hasPoster,
    this.hasBackdrop = false,
    this.year,
    this.rating,
    this.overview,
    this.episodes = 0,
    this.sizeBytes = 0,
    this.addedMs = 0,
    this.posterV = 0,
    this.backdropV = 0,
    this.guessTitle = '',
    this.guessYear,
  });
  final String id, title, fileName, guessTitle;
  final bool isShow, matched, hasPoster, hasBackdrop;
  final int? year, guessYear;
  final double? rating;
  final String? overview;
  final int episodes, sizeBytes, addedMs;

  /// Cambia cada vez que se cambia la carátula (sirve para refrescar la imagen).
  final int posterV;

  /// Igual, para el fondo horizontal.
  final int backdropV;
}

/// Un capítulo de una serie tal como lo ve la ventana del servidor.
class EpisodeRow {
  const EpisodeRow({
    required this.id,
    required this.season,
    required this.episode,
    required this.title,
    required this.fileName,
    required this.manual,
  });
  final String id, title, fileName;
  final int season, episode;

  /// true si el nombre lo escribió el usuario (no viene de TMDB ni del archivo).
  final bool manual;
}

class ServerConfig {
  const ServerConfig(
      {required this.root,
      required this.dataDir,
      this.port = 8080,
      this.name,
      this.tmdbKey,
      this.avatarsDir,
      this.updatesDir,
      this.openAccess = true,
      this.language = 'es-MX'});
  final String root, dataDir, language;
  final int port;
  final String? name;

  /// Carpeta con los avatares (.jpg). Por defecto, `avatars/` dentro de [dataDir].
  final String? avatarsDir;

  /// Carpeta con el .apk del cliente Android. Por defecto, `updates/` dentro de [dataDir].
  final String? updatesDir;

  /// Clave de TMDB (v3) o token de lectura (v4). Sin ella no hay carátulas automáticas,
  /// pero los perfiles se siguen pudiendo editar a mano.
  final String? tmdbKey;

  /// Conexión automática: los dispositivos con la app entran sin PIN (red de confianza).
  final bool openAccess;
}

/// Servidor completo (API, streaming, HLS, WebSocket, descubrimiento).
/// Solo puede haber una instancia en ejecución por proceso.
class MediaServer {
  MediaServer(this.config);
  final ServerConfig config;
  late AudioBookStore audioBooks;
  final hub = RemoteHub();
  Auth? _auth;
  HttpServer? _http;
  RawDatagramSocket? _discovery;
  StreamSubscription<FileSystemEvent>? _watch;
  final _subs = <StreamSubscription<void>>[];
  final _changes = StreamController<void>.broadcast();
  final _arrivals = StreamController<NewRequestEvent>.broadcast();
  Timer? _debounce, _updDebounce, _presenceTimer;
  StreamSubscription<FileSystemEvent>? _updWatch;

  bool get running => _http != null;
  String get pin => _auth?.pin ?? '';

  /// ¿Se deja entrar sin PIN? Se puede cambiar con el servidor en marcha.
  bool get openAccess => _auth?.open ?? config.openAccess;
  void setOpenAccess(bool v) => _auth?.setOpen(v);
  Map<String, String> get pairedDevices => _auth?.devices ?? const {};
  List<String> get connectedDevices => hub.names;

  /// Dispositivos emparejados con su estado: conectado (WebSocket abierto) o no.
  List<PairedDevice> get pairedList {
    final a = _auth;
    if (a == null) return const [];
    final on = hub.connectedTokens;
    return [
      for (final e in a.devices.entries)
        PairedDevice(e.key, e.value,
            alias: a.aliases[e.key],
            connected: on.contains(e.key),
            version: a.versionOf(e.key),
            versionCode: a.versionCodeOf(e.key),
            lastSeen: a.lastSeenOf(e.key))
    ];
  }

  /// versionCode del APK que se ofrece a los clientes (null si no hay).
  int? get updateCode => running ? updateStore.current?.versionCode : null;

  /// Pone nombre a un dispositivo emparejado (vacío = volver al original).
  /// Los dispositivos conectados ven el cambio en su lista de "cast" al momento.
  void renameDevice(String token, String name) {
    _auth?.rename(token, name);
    hub.refresh();
  }

  /// Las peticiones guardan el nombre original del dispositivo; para mostrarlo se usa
  /// el que le puso el dueño del servidor, si lo hay.
  String _shown(String deviceName) {
    final a = _auth;
    if (a == null) return deviceName;
    for (final e in a.devices.entries) {
      final alias = a.aliases[e.key];
      if (e.value == deviceName && alias != null) return alias;
    }
    return deviceName;
  }

  // ---------- perfiles de usuario (para la ventana del servidor) ----------
  /// Perfiles de usuario, en orden de creación.
  List<UserProfile> get profileList => running ? users.list() : const [];

  /// Cuántos dispositivos usan ahora cada perfil (clave = nombre de usuario en minúsculas).
  Map<String, int> get profileDevices =>
      running ? users.deviceCounts() : const {};

  /// Carpeta donde se deja el .apk del cliente Android.
  String get updatesPath => running
      ? updateStore.dir.path
      : (config.updatesDir ?? p.join(config.dataDir, 'updates'));

  /// Versión del APK que se ofrece a los clientes (null si no hay).
  String? get updateVersion {
    final a = running ? updateStore.current : null;
    return a == null ? null : '${a.versionName} (${a.versionCode})';
  }

  /// .apk de la carpeta que no son válidos, con el motivo.
  Map<String, String> get updateSkipped =>
      running ? Map.unmodifiable(updateStore.skipped) : const {};

  /// Carpeta donde se dejan los avatares (.jpg).
  String get avatarsPath => running
      ? avatars.dir.path
      : (config.avatarsDir ?? p.join(config.dataDir, 'avatars'));

  /// Avatares válidos que hay en la carpeta.
  int get avatarCount => running ? avatars.scan().length : 0;

  /// Archivos de la carpeta que se ignoran, con el motivo.
  Map<String, String> get avatarProblems {
    if (!running) return const {};
    avatars.scan();
    return Map.unmodifiable(avatars.skipped);
  }

  /// Archivo del avatar de un perfil (null si no tiene o ya no está en la carpeta).
  File? avatarFileOf(String? avatarId) =>
      (running && avatarId != null) ? avatars.file(avatarId) : null;

  // ---------- herramienta de avatares: recortar / centrar cualquier imagen ----------
  // Dejan el JPG de 512 x 512 px directamente en la carpeta de avatares; como esta
  // se relee en cada consulta, el avatar aparece en la app sin reiniciar nada.
  AvatarWorkshop get _workshop => AvatarWorkshop(avatarsPath);

  /// Lee una imagen (JPG, PNG, WebP, GIF, BMP...) para el editor de recorte.
  /// Lanza [FormatException] si no se puede leer.
  Future<AvatarSource> openAvatarImage(String path) => _workshop.open(path);

  /// Paquetes que ya existen: las subcarpetas de la carpeta de avatares, por nombre.
  List<String> avatarPacks() {
    try {
      final d = Directory(avatarsPath);
      if (!d.existsSync()) return const [];
      return [
        for (final e in d.listSync(followLinks: false))
          if (e is Directory) p.basename(e.path)
      ].where(_isPackName).toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    } catch (_) {
      return const [];
    }
  }

  bool _isPackName(String n) =>
      isValidAvatarPack(n) && n.toLowerCase() != AvatarWorkshop.originalsFolder;

  /// Crea un paquete nuevo (una subcarpeta) y devuelve su nombre. Si ya existe uno con
  /// ese nombre (sin distinguir mayúsculas) devuelve el existente.
  /// Lanza [FormatException] si el nombre no es válido.
  String createAvatarPack(String name) {
    final n = name.trim();
    if (!_isPackName(n)) {
      throw const FormatException(
          'Nombre de paquete no válido: máximo 64 caracteres, sin \\ / : * ? " < > | % '
          'y sin empezar por punto.');
    }
    for (final e in avatarPacks()) {
      if (e.toLowerCase() == n.toLowerCase()) return e;
    }
    Directory(p.join(avatarsPath, n)).createSync(recursive: true);
    return n;
  }

  /// Carpeta donde se guarda un avatar: la principal ([pack] null o vacío) o la de un paquete.
  AvatarWorkshop _workshopFor(String? pack) {
    if (pack == null || pack.isEmpty) return _workshop;
    if (!_isPackName(pack)) {
      throw const FormatException('El nombre del paquete no es válido.');
    }
    return AvatarWorkshop(p.join(avatarsPath, pack));
  }

  /// Id libre para un avatar nuevo, a partir del nombre del archivo.
  String suggestAvatarId(String path, {String? pack}) =>
      _workshopFor(pack).uniqueId(AvatarWorkshop.suggestId(path));

  /// ¿Ya existe un avatar con ese id (en la carpeta principal o en [pack])?
  bool avatarIdTaken(String id, {String? pack}) =>
      _workshopFor(pack).isTaken(id);

  /// Recorta/centra la imagen y la guarda como avatar, en la carpeta principal o en el
  /// paquete [pack]. Devuelve el id completo (`Paquete|nombre` si es de un paquete).
  Future<String> importAvatar(String path,
      {String? id,
      String? pack,
      AvatarCrop crop = const AvatarCrop(),
      bool overwrite = false}) async {
    final saved = await _workshopFor(pack)
        .importFile(path, id: id, crop: crop, overwrite: overwrite);
    return (pack == null || pack.isEmpty) ? saved : '$pack$avatarPackSep$saved';
  }

  /// Convierte las imágenes de la carpeta que no cumplan (recorte centrado) y aparta
  /// los originales en la subcarpeta `originales`.
  Future<List<AvatarFixResult>> fixAvatarFolder() async {
    final out = [...await _workshop.fixFolder()];
    // También las subcarpetas (paquetes): cada una con sus propios originales.
    final packs = running ? avatars.packDirs() : const <Directory>[];
    for (final d in packs) {
      final pack = p.basename(d.path);
      if (!isValidAvatarPack(pack)) continue;
      for (final r in await AvatarWorkshop(d.path).fixFolder()) {
        out.add(AvatarFixResult('$pack/${r.file}', r.ok, r.message,
            id: r.id == null ? null : '$pack$avatarPackSep${r.id}'));
      }
    }
    return out;
  }

  /// Quita el PIN de un perfil sin pedirlo (por si se le olvidó a alguien).
  void resetProfilePin(String username) {
    if (running) users.resetPin(username);
  }

  /// Borra un perfil con su progreso y sus peticiones.
  void deleteProfile(String username) {
    if (!running) return;
    final real = users.get(username)?.username ?? username;
    users.delete(username, force: true);
    _purgeUserData(real);
  }

  /// Emite cada vez que llega una petición nueva.
  Stream<NewRequestEvent> get requestArrivals => _arrivals.stream;
  bool get hasFfmpeg =>
      running && tools.ffmpeg != null && tools.ffprobe != null;
  int get videoCount => videos.length;
  bool get tmdbEnabled => running && profiles.enabled;

  // ---------- biblioteca y carátulas (para la ventana del servidor) ----------
  /// Películas y series (los capítulos no aparecen sueltos), ordenadas por título.
  List<LibraryEntry> get libraryEntries {
    if (!running) return const [];
    final out = <LibraryEntry>[];
    for (final v in videos.values) {
      if (v.ep != null) continue;
      final pr = profiles.profile(v.id);
      final g = MetadataStore.parseName(v.title);
      out.add(LibraryEntry(
        id: v.id,
        title: (pr?['title'] as String?) ?? v.title,
        fileName: p.basename(v.path),
        isShow: false,
        matched: pr?['tmdbId'] != null,
        hasPoster: profiles.art(v.id, 'poster') != null,
        hasBackdrop: profiles.art(v.id, 'backdrop') != null,
        year: pr?['year'] as int?,
        rating: (pr?['rating'] as num?)?.toDouble(),
        overview: pr?['overview'] as String?,
        sizeBytes: v.size,
        addedMs: v.addedMs,
        posterV: (pr?['posterV'] as int?) ?? 0,
        backdropV: (pr?['backdropV'] as int?) ?? 0,
        guessTitle: g.title.isEmpty ? v.title : g.title,
        guessYear: g.year,
      ));
    }
    for (final s in shows.values) {
      final pr = profiles.profile(s.id);
      out.add(LibraryEntry(
        id: s.id,
        title: (pr?['title'] as String?) ?? s.name,
        fileName: '${s.episodes.length} capítulos',
        isShow: true,
        matched: pr?['tmdbId'] != null,
        hasPoster: profiles.art(s.id, 'poster') != null,
        hasBackdrop: profiles.art(s.id, 'backdrop') != null,
        year: (pr?['year'] as int?) ?? s.year,
        rating: (pr?['rating'] as num?)?.toDouble(),
        overview: pr?['overview'] as String?,
        episodes: s.episodes.length,
        sizeBytes: s.episodes.fold<int>(0, (a, v) => a + v.size),
        addedMs: s.episodes.map((v) => v.addedMs).fold<int>(0, max),
        posterV: (pr?['posterV'] as int?) ?? 0,
        backdropV: (pr?['backdropV'] as int?) ?? 0,
        guessTitle: s.name,
        guessYear: s.year,
      ));
    }
    out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return out;
  }

  /// Carátula guardada de una película o serie (null si no tiene).
  File? posterFile(String id) => running ? profiles.art(id, 'poster') : null;

  /// Fondo horizontal guardado de una película o serie (null si no tiene).
  File? backdropFile(String id) =>
      running ? profiles.art(id, 'backdrop') : null;

  /// Fotograma del video (o del primer capítulo de una serie), para ver algo cuando no hay carátula.
  Future<File?> thumbnailFile(String id) async {
    if (!running) return null;
    final v = videos[id] ?? shows[id]?.episodes.firstOrNull;
    if (v == null) return null;
    return thumbs.get(v.id, v.path, v.meta?.durationMs);
  }

  void _entryChanged() {
    onLibraryChanged?.call();
    _changes.add(null);
  }

  void _requireEntry(String id) {
    if (!running) throw StateError('El servidor está detenido.');
    if (!videos.containsKey(id) && !shows.containsKey(id)) {
      throw StateError('Ya no existe en la biblioteca.');
    }
  }

  /// Busca en TMDB (películas y series). Lanza StateError si falta la clave.
  Future<List<Map<String, dynamic>>> searchTmdb(String query,
      {int? year, String? type}) {
    if (!running || !profiles.enabled) {
      throw StateError('Falta la clave de TMDB.');
    }
    return profiles.search(query, year: year, type: type);
  }

  /// Enlaza [id] con una ficha de TMDB y descarga su carátula, fondo y datos.
  /// Una serie solo admite resultados de tipo 'tv' (y se actualizan sus capítulos).
  Future<void> applyTmdb(String id, int tmdbId, String type) async {
    _requireEntry(id);
    final show = shows[id];
    if (show != null) {
      if (type != 'tv') {
        throw StateError('Para una serie elige un resultado de tipo Serie.');
      }
      await profiles.match(show.id, tmdbId, 'tv');
      await _syncEpisodes(show, force: true);
    } else {
      if (type != 'movie') {
        throw StateError(
            'Para una película elige un resultado de tipo Película.');
      }
      await profiles.match(id, tmdbId, 'movie');
    }
    _entryChanged();
  }

  /// Intenta identificarlo solo por el nombre del archivo. false si no hay coincidencia clara.
  Future<bool> autoMatchEntry(String id) async {
    _requireEntry(id);
    if (!profiles.enabled) throw StateError('Falta la clave de TMDB.');
    final show = shows[id];
    Object? r;
    if (show != null) {
      r = await profiles.autoMatch(show.id, show.name,
          type: 'tv', year: show.year);
      if (r != null) await _syncEpisodes(show, force: true);
    } else {
      r = await profiles.autoMatch(id, videos[id]!.title);
    }
    if (r != null) _entryChanged();
    return r != null;
  }

  /// Pone como carátula una imagen del disco.
  Future<void> setPosterFromFile(String id, String imagePath) async {
    _requireEntry(id);
    await profiles.setPosterFile(id, imagePath);
    _entryChanged();
  }

  /// Descarga una imagen de internet y la pone como carátula.
  Future<void> setPosterFromUrl(String id, String url) async {
    _requireEntry(id);
    final before = profiles.profile(id)?['posterV'];
    final prof = await profiles.update(id, {'posterUrl': url});
    if (prof['posterV'] == before) {
      throw StateError('No se pudo descargar la imagen de esa dirección.');
    }
    _entryChanged();
  }

  /// Ficha guardada de una película o serie (vacía si no tiene), para rellenar el editor.
  Map<String, dynamic> entryProfile(String id) =>
      running ? <String, dynamic>{...?profiles.profile(id)} : const {};

  /// Guarda a mano los datos de la ficha (título, sinopsis, clasificación, géneros...).
  /// Solo se cambian las claves que vienen en [fields]. Un video con ficha propia ya no
  /// lo vuelve a identificar el escaneo automático.
  Future<void> updateEntryInfo(String id, Map<String, dynamic> fields) async {
    _requireEntry(id);
    await profiles.update(id, fields);
    _entryChanged();
  }

  /// Capítulos de la serie [showId] con el nombre que se les muestra hoy.
  List<EpisodeRow> episodeRows(String showId) {
    final s = running ? shows[showId] : null;
    if (s == null) return const [];
    return [
      for (final v in s.episodes)
        EpisodeRow(
          id: v.id,
          season: v.ep!.season,
          episode: v.ep!.episode,
          title: _item(v).epTitle ?? '',
          fileName: p.basename(v.path),
          manual: profiles.profile(v.id)?['titleManual'] == true,
        ),
    ];
  }

  /// Cambia el nombre de varios capítulos: `{idDelCapítulo: nombreNuevo}`. Un nombre vacío
  /// quita el nombre propio y vuelve al de TMDB (si la serie está identificada) o al del archivo.
  /// Devuelve cuántos capítulos se cambiaron.
  Future<int> renameEpisodes(Map<String, String> names) async {
    if (!running) throw StateError('El servidor está detenido.');
    var n = 0;
    for (final entry in names.entries) {
      final v = videos[entry.key];
      if (v?.ep == null) continue; // ya no existe o no es un capítulo
      final name = entry.value.trim();
      if (name.isNotEmpty) {
        await profiles.update(v!.id, {'title': name, 'titleManual': true});
        n++;
        continue;
      }
      // Quitar el nombre propio: se pide de nuevo a TMDB o se limpia el perfil.
      await profiles.update(v!.id, {'title': '', 'titleManual': false});
      final tmdbId = v.showId == null ? null : profiles.profile(v.showId!)?['tmdbId'];
      var restored = false;
      if (tmdbId is int && profiles.enabled) {
        try {
          restored = await profiles.applyEpisode(
                  v.id, tmdbId, v.ep!.season, v.ep!.episode) !=
              null;
        } catch (_) {}
      }
      final cur = profiles.profile(v.id);
      if (!restored && cur != null && cur['overview'] == null && cur['season'] == null) {
        profiles.forget([v.id]); // perfil vacío: el escaneo podrá rellenarlo luego
      }
      n++;
    }
    if (n > 0) _entryChanged();
    return n;
  }

  /// Pone como fondo horizontal una imagen del disco.
  Future<void> setBackdropFromFile(String id, String imagePath) async {
    _requireEntry(id);
    await profiles.setBackdropFile(id, imagePath);
    _entryChanged();
  }

  /// Descarga una imagen de internet y la pone como fondo horizontal.
  Future<void> setBackdropFromUrl(String id, String url) async {
    _requireEntry(id);
    final before = profiles.profile(id)?['backdropV'];
    final prof = await profiles.update(id, {'backdropUrl': url});
    if (prof['backdropV'] == before) {
      throw StateError('No se pudo descargar la imagen de esa dirección.');
    }
    _entryChanged();
  }

  /// Borra la ficha y las imágenes: vuelve a mostrarse con el nombre del archivo.
  void resetEntry(String id) {
    _requireEntry(id);
    profiles.reset(id);
    final s = shows[id];
    if (s != null) profiles.forget(s.episodes.map((v) => v.id));
    _entryChanged();
  }

  /// Identifica por nombre todo lo que aún no tiene ficha (en segundo plano).
  void autoScrapeAll() {
    if (running) unawaited(_scrapeAll());
  }

  /// Peticiones de los dispositivos, las más recientes primero.
  List<MovieRequestInfo> get requestList {
    if (!running) return const [];
    final owned = _libraryTmdbIds();
    return [
      for (final e in requests.list())
        MovieRequestInfo(e['id'] as int, '${e['title'] ?? ''}',
            type: e['type'] == 'tv' ? 'tv' : 'movie',
            year: e['year'] as int?,
            posterUrl: e['posterUrl'] as String?,
            by: [for (final d in (e['by'] as List? ?? const [])) _shown('$d')],
            createdMs: (e['createdMs'] as int?) ?? 0,
            inLibrary: owned.contains(
                requestKey(e['id'] as int, e['type'] == 'tv' ? 'tv' : 'movie')))
    ];
  }

  /// Añade [sourcePath] a la biblioteca como la película pedida [tmdbId].
  /// Con [move] mueve el archivo; si no, lo copia. Devuelve un mensaje para mostrar.
  Future<String> fulfillRequest(int tmdbId, String sourcePath,
      {bool move = false}) {
    if (!running) throw StateError('El servidor está detenido.');
    return _fulfillRequest(config.root, tmdbId, sourcePath, move: move);
  }

  /// Añade [episodes] a la biblioteca como capítulos de la serie pedida [tmdbId]: cada
  /// temporada en su subcarpeta dentro de la carpeta de la serie. Sirve para una serie
  /// nueva o para completar/añadir temporadas de una que ya está. Devuelve un mensaje.
  Future<String> fulfillSeriesRequest(int tmdbId, List<EpisodeImport> episodes,
      {bool move = false}) {
    if (!running) throw StateError('El servidor está detenido.');
    return _fulfillSeries(config.root, tmdbId, episodes, move: move);
  }

  /// Borra una petición del todo (para todos los dispositivos).
  void deleteRequest(int tmdbId, [String type = 'movie']) {
    if (!running) return;
    requests.removeAll(tmdbId, type);
    _changes.add(null);
  }

  /// Emite cuando cambia algo visible: PIN, emparejados, conectados, estado.
  Stream<void> get changes => _changes.stream;
  void revoke(String token) {
    final k = deviceKeyOf(token);
    if (progress.data.remove(k) != null) progress.save();
    if (watched.data.remove(k) != null) watched.save();
    if (running) users.forgetDevice(k);
    _auth?.revoke(token);
    hub.dropToken(token); // si estaba conectado, se le corta la conexión
  }

  static Future<List<String>> localAddresses(int port) async => [
        for (final i
            in await NetworkInterface.list(type: InternetAddressType.IPv4))
          for (final a in i.addresses) '${a.address}:$port'
      ];

  Future<void> start() async {
    if (running) return;
    final root = config.root;
    if (!Directory(root).existsSync())
      throw StateError('La carpeta "$root" no existe.');
    try {
      serverName = config.name ?? Platform.localHostname;
      final data = Directory(config.dataDir)..createSync(recursive: true);
      audioBooks = AudioBookStore(Directory(p.join(data.path, 'audiobooks')),
          onChanged: () => onLibraryChanged?.call());
      tools = await Tools.locate();
      thumbs = Thumbs(tools, p.join(data.path, 'thumbs'));
      metaCache = JsonFile(p.join(data.path, 'meta.json'));
      progress = JsonFile(p.join(data.path, 'progress.json'));
      watched = JsonFile(p.join(data.path, 'watched.json'));
      added = JsonFile(p.join(data.path, 'added.json'));
      subsDir = Directory(p.join(data.path, 'subs'))
        ..createSync(recursive: true);
      profiles = MetadataStore(data.path,
          apiKey: config.tmdbKey, language: config.language);
      requests = RequestStore(data.path);
      avatars = AvatarStore(config.avatarsDir ?? p.join(data.path, 'avatars'));
      users = UserStore(data.path, avatars);
      news = JsonFile(p.join(data.path, 'news.json'));
      // Primera vez con novedades: lo que ya hay en la biblioteca no cuenta como nuevo.
      if (news.data['baselineMs'] is! int) {
        news.data['baselineMs'] = DateTime.now().millisecondsSinceEpoch;
        news.save();
      }
      updateStore =
          UpdateStore(config.updatesDir ?? p.join(data.path, 'updates'));
      await updateStore.scan();
      transcoder = Transcoder(tools, p.join(data.path, 'hls'));
      await scan(root);
      final auth = _auth = _authTop = Auth(p.join(data.path, 'tokens.json'))
        ..open = config.openAccess;
      hub.aliasOf = (t) => auth.aliases[t];
      hub.onHello = (token, name) {
        final old = auth.updateName(token, name);
        if (old != null) {
          requests.renameDevice(old, name);
          print('[dispositivo] "$old" ahora se llama "$name".');
        }
      };
      // Versión del cliente y última conexión de cada dispositivo.
      hub.onVersion =
          (token, version, code) => auth.setVersion(token, version, code);
      hub.onPresence = (token) {
        auth.touch(token);
        _changes.add(null);
      };
      // Mientras sigue conectado, se refresca su "última conexión" cada minuto
      // (así, si el servidor se apaga de golpe, la hora guardada sigue siendo reciente).
      _presenceTimer?.cancel();
      _presenceTimer = Timer.periodic(const Duration(seconds: 60), (_) {
        for (final t in hub.connectedTokens) {
          auth.touch(t);
        }
      });

      final router = Router()
        ..get(
            '/api/info',
            (Request r) => _json(ServerInfo(serverName, config.port, '0.6.0',
                    tmdb: profiles.enabled, open: auth.open)
                .toJson()))
        ..get('/api/library', (Request r) {
          final q = r.url.queryParameters['q']?.toLowerCase();
          final items = videos.values
              .map(_item)
              .where((v) => q == null || v.title.toLowerCase().contains(q))
              .toList()
            ..sort((a, b) =>
                a.title.toLowerCase().compareTo(b.title.toLowerCase()));
          return _json({'items': items.map((v) => v.toJson()).toList()});
        })
        ..post('/api/library/scan', (Request r) async {
          await scan(root);
          hub.notifyLibrary();
          return _json({'count': videos.length});
        })
        ..post('/api/pair', auth.pair)
        ..get('/ws', hub.handler)
        ..post('/api/library/autoscrape', (Request r) {
          unawaited(_scrapeAll());
          return _json({'started': profiles.enabled});
        })
        ..get('/api/shows', (Request r) {
          final items = shows.values.map(_showItem).toList()
            ..sort(
                (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
          return _json({'items': items.map((s) => s.toJson()).toList()});
        })
        ..get(
            '/api/audiobooks',
            (Request r) => _json({
                  'items': [for (final book in audioBooks.books) book.toJson()]
                }))
        ..get('/api/audiobooks/<id>/tracks/<track>',
            (Request r, String id, String track) {
          final book = audioBooks.get(id);
          if (book == null || !book.tracks.any((t) => t.id == track))
            return Response.notFound('Pista no disponible');
          return _serveFile(
              r, File(audioBooks.assetPath(book, track)), bookMime(track)!);
        })
        ..get('/api/audiobooks/<id>/art/<kind>',
            (Request r, String id, String kind) {
          final book = audioBooks.get(id);
          if (book == null)
            return Response.notFound('Audiolibro no disponible');
          final asset = switch (kind) {
            'poster' => book.poster,
            'backdrop' => book.backdrop,
            _ => null
          };
          if (asset == null) return Response.notFound('Portada no disponible');
          return _serveFile(
              r, File(audioBooks.assetPath(book, asset)), bookMime(asset)!);
        })
        ..get('/api/news', _getNews)
        ..post('/api/news/read', _markNewsRead)
        ..get('/api/shows/<id>', _getShow)
        ..get('/api/shows/<id>/poster',
            (Request r, String id) => _artResponse(id, 'poster'))
        ..get('/api/shows/<id>/backdrop',
            (Request r, String id) => _artResponse(id, 'backdrop'))
        ..get('/api/videos/<id>/still',
            (Request r, String id) => _artResponse(id, 'still'))
        ..get(
            '/api/tmdb/key',
            (Request r) => _json({
                  // Solo llega a dispositivos emparejados (el middleware exige token).
                  'key': config.tmdbKey ?? '',
                  'language': config.language,
                }))
        ..get('/api/tmdb/search', _tmdbSearch)
        ..get('/api/tmdb/discover', _discover)
        ..get('/api/tmdb/genres', _genres)
        ..get('/api/tmdb/<type>/<id>/trailer', _trailer)
        ..get('/api/tmdb/<type>/<id>/info', _tmdbInfo)
        ..get('/api/tmdb/<type>/<id>/recommendations', _recommendations)
        ..get('/api/requests', _listRequests)
        ..post('/api/requests', (Request r) {
          final t = requestToken(r);
          // Con perfil activo, la petición es del perfil (su nombre de usuario).
          final u = _userName();
          return _addRequest(r, u ?? auth.devices[t] ?? 'dispositivo',
              label: u ?? (t == null ? null : auth.displayName(t)));
        })
        ..delete(
            '/api/requests/<id>',
            (Request r, String id) => _removeRequest(
                id,
                _userName() ?? auth.devices[requestToken(r)] ?? 'dispositivo',
                r.url.queryParameters['type']))
        ..get('/api/profiles', _listUsers)
        ..post('/api/profiles', _createUser)
        ..post('/api/profiles/current/import-progress', _importDeviceProgress)
        ..put('/api/profiles/<name>', _updateUser)
        ..delete('/api/profiles/<name>', _deleteUser)
        ..post('/api/profiles/<name>/select', _selectUser)
        ..get('/api/update/android', _updateInfo)
        ..get('/api/update/android/apk', _updateApk)
        ..get('/api/avatars', _listAvatars)
        ..get('/api/avatars/<id>', _avatarImage)
        ..get('/api/videos/<id>', _detail)
        ..get('/api/videos/<id>/segments', _segments)
        ..get('/api/videos/<id>/poster',
            (Request r, String id) => _artResponse(id, 'poster'))
        ..get('/api/videos/<id>/backdrop',
            (Request r, String id) => _artResponse(id, 'backdrop'))
        ..get('/api/videos/<id>/profile', _getProfile)
        ..put('/api/videos/<id>/profile', _putProfile)
        ..delete('/api/videos/<id>/profile', _deleteProfile)
        ..post('/api/videos/<id>/profile/match', _matchProfile)
        ..post('/api/videos/<id>/profile/auto', _autoProfile)
        ..get('/api/videos/<id>/stream', _stream)
        ..get('/api/videos/<id>/thumbnail', _thumb)
        ..get('/api/videos/<id>/subtitles/<sid>', _subtitle)
        ..get('/api/videos/<id>/hls/<name>', _hls)
        ..put('/api/videos/<id>/progress', _saveProgress)
        ..get('/api/videos/<id>/progress', _getProgress)
        ..delete('/api/progress', _resetProgress);

      final handler = Pipeline()
          .addMiddleware(logRequests(
              logger: (msg, isError) =>
                  print(msg.replaceAll(RegExp(r'token=[^&\s]+'), 'token=***'))))
          .addMiddleware(auth.middleware)
          .addMiddleware((inner) => (req) {
                final t = requestToken(req);
                final dk = t == null ? null : deviceKeyOf(t);
                // Perfil con el que está actuando este dispositivo (null = aún ninguno).
                final u = dk == null ? null : users.activeFor(dk);
                return runZoned(() => inner(req),
                    zoneValues: {_devKey: dk, _userKey: u});
              })
          .addHandler(router.call);
      _http = await io.serve(handler, InternetAddress.anyIPv4, config.port);
      _discovery =
          await startDiscovery(serverName, config.port, open: () => _auth?.open ?? false);

      _subs
        ..add(auth.changes.listen((_) => _changes.add(null)))
        ..add(users.changes.listen((_) {
          _changes.add(null);
          hub.notifyProfiles();
        }))
        ..add(hub.changes.listen((_) => _changes.add(null)));
      _watchLibrary(root, data.path);
      _watchUpdates();
      onLibraryChanged = () {
        hub.notifyLibrary();
        _changes.add(null);
      };
      onRequestsChanged = () => _changes.add(null);
      onRequestArrived = (e) => _arrivals.add(NewRequestEvent(e.tmdbId, e.title,
          year: e.year,
          posterUrl: e.posterUrl,
          device: e.device,
          alsoBy: [for (final d in e.alsoBy) _shown(d)]));
      _changes.add(null);

      print(
          'Servidor escuchando en el puerto ${config.port}. Conecta desde el cliente a:');
      for (final a in await localAddresses(config.port)) {
        print('  $a');
      }
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  /// Reescanea la biblioteca (tras 5 s sin cambios) cuando se añaden o quitan archivos.
  void _watchLibrary(String root, String dataPath) {
    try {
      _watch = Directory(root).watch(recursive: true).listen((e) {
        if (e.path.startsWith(dataPath)) return;
        _debounce?.cancel();
        _debounce = Timer(const Duration(seconds: 5), () async {
          await scan(root);
          hub.notifyLibrary();
          _changes.add(null);
        });
      }, onError: (_) {});
    } catch (_) {}
  }

  /// Vigila `updates/`: al soltar/cambiar/quitar un .apk reescanea y avisa a los clientes.
  void _watchUpdates() {
    try {
      _updWatch = updateStore.dir.watch().listen((_) {
        _updDebounce?.cancel();
        _updDebounce = Timer(const Duration(seconds: 4), () async {
          final before = updateStore.current?.sha256;
          await updateStore.scan();
          // Archivo aún copiándose: reintenta una vez.
          if (updateStore.skipped.values.any((v) => v == 'se está copiando')) {
            _updDebounce = Timer(const Duration(seconds: 5), () async {
              await updateStore.scan();
              hub.notifyUpdate();
              _changes.add(null);
            });
          }
          if (before != updateStore.current?.sha256) hub.notifyUpdate();
          _changes.add(null);
        });
      }, onError: (_) {});
    } catch (_) {}
  }

  Future<void> stop() async {
    _presenceTimer?.cancel();
    _presenceTimer = null;
    final a = _auth;
    if (a != null) {
      for (final t in hub.connectedTokens) {
        a.touch(t); // los que estaban conectados se van ahora
      }
      a.flush();
    }
    _updDebounce?.cancel();
    await _updWatch?.cancel();
    _updWatch = null;
    onLibraryChanged = null;
    onRequestsChanged = null;
    onRequestArrived = null;
    _debounce?.cancel();
    await _watch?.cancel();
    _watch = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _discovery?.close();
    _discovery = null;
    hub.closeAll();
    try {
      transcoder.dispose();
    } catch (_) {}
    try {
      profiles.dispose();
    } catch (_) {}
    await _http?.close(force: true);
    _http = null;
    _auth = null;
    _authTop = null;
    _changes.add(null);
  }
}
