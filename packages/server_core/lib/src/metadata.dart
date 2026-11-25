import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shared/shared.dart'
    show ExploreFilters, buildDiscoverQuery, parseTmdbInfo, cleanOscarCategory, isBestPictureLabel;

import 'media.dart';

/// Perfiles de películas tipo Plex: datos de TMDB (carátula, fondo, sinopsis,
/// valoración, reparto...) más los cambios manuales del usuario.
///
/// Todo se guarda en `profiles.json` y `art/` dentro de la carpeta de datos.
/// La clave de TMDB nunca sale del servidor: el cliente pide búsquedas y
/// emparejados a través de la API del servidor.
class MetadataStore {
  MetadataStore(String dataDir, {String? apiKey, this.language = 'es-MX'})
      : apiKey = (apiKey ?? '').trim(),
        _store = JsonFile(p.join(dataDir, 'profiles.json')),
        _art = Directory(p.join(dataDir, 'art'))..createSync(recursive: true);

  final String apiKey, language;
  final JsonFile _store;
  final Directory _art;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  bool _scraping = false, _oscarBusy = false, _certBusy = false;

  static const _api = 'https://api.themoviedb.org/3';
  static const _img = 'https://image.tmdb.org/t/p';

  bool get enabled => apiKey.isNotEmpty;

  /// Ids que ya se intentaron emparejar sin éxito (para no repetir en cada escaneo).
  Map<String, dynamic> get _tried =>
      (_store.data['_tried'] ??= <String, dynamic>{}) as Map<String, dynamic>;

  Map<String, dynamic>? profile(String id) {
    final e = _store.data[id];
    return e is Map ? e.cast<String, dynamic>() : null;
  }

  File? art(String id, String kind) {
    final f = File(p.join(_art.path, '${id}_$kind.jpg'));
    return f.existsSync() ? f : null;
  }

  // ---------- TMDB ----------
  // Acepta la clave v3 (32 caracteres) o el "token de acceso de lectura" v4 (JWT largo).
  bool get _bearer => apiKey.length > 40;

  Uri _uri(String path, [Map<String, String> q = const {}]) {
    final params = {'language': language, ...q};
    if (!_bearer) params['api_key'] = apiKey;
    return Uri.parse('$_api$path').replace(queryParameters: params);
  }

  Future<Map<String, dynamic>> _getJson(Uri u) async {
    final req = await _http.getUrl(u).timeout(const Duration(seconds: 15));
    req.headers.set('accept', 'application/json');
    if (_bearer) req.headers.set('authorization', 'Bearer $apiKey');
    final res = await req.close().timeout(const Duration(seconds: 20));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw HttpException('TMDB respondió ${res.statusCode}');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<bool> _download(String url, File out) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https'))
      return false;
    final tmp = File('${out.path}.tmp');
    try {
      final req = await _http.getUrl(uri).timeout(const Duration(seconds: 15));
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return false;
      }
      await res.pipe(tmp.openWrite());
      await tmp.rename(out.path);
      return true;
    } catch (e) {
      print('[perfil] no se pudo descargar $url: $e');
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      return false;
    }
  }

  static List<String> _names(Object? list, {String? job, int max = 10}) => [
        for (final e in (list as List? ?? const []))
          if (job == null || (e as Map)['job'] == job)
            (e as Map)['name'].toString()
      ].take(max).toList();

  static String? _trailer(Object? videos) {
    final list = [
      for (final e in ((videos as Map?)?['results'] as List? ?? const []))
        if ((e as Map)['site'] == 'YouTube') (e as Map).cast<String, dynamic>()
    ];
    for (final t in const ['Trailer', 'Teaser']) {
      for (final v in list) {
        if (v['type'] == t) return v['key'] as String?;
      }
    }
    return null;
  }

  /// Países por orden de preferencia para la clasificación de edades.
  static const _certCountries = ['MX', 'US', 'ES', 'AR', 'CL', 'CO', 'GB'];

  /// Saca la clasificación de `release_dates` (películas) o `content_ratings` (series).
  static ({String cert, String country})? _certification(Object? block) {
    final results = [
      for (final e in ((block as Map?)?['results'] as List? ?? const []))
        if (e is Map) e.cast<String, dynamic>()
    ];
    String? pick(Map<String, dynamic> r) {
      final rd = r['release_dates'];
      if (rd is List) {
        for (final x in rd) {
          final c = '${(x as Map)['certification'] ?? ''}'.trim();
          if (c.isNotEmpty) return c;
        }
        return null;
      }
      final c = '${r['rating'] ?? ''}'.trim();
      return c.isEmpty ? null : c;
    }

    for (final country in _certCountries) {
      for (final r in results) {
        if (r['iso_3166_1'] != country) continue;
        final c = pick(r);
        if (c != null) return (cert: c, country: country);
      }
    }
    for (final r in results) {
      final c = pick(r);
      if (c != null) return (cert: c, country: '${r['iso_3166_1'] ?? ''}');
    }
    return null;
  }

  static final _reLatino = RegExp(
      r'latino|latam|latinoam|hispanoam|m[eé]xico|\bmx\b',
      caseSensitive: false);
  static final _reCastellano =
      RegExp(r'castellano|espa[ñn]a|\bspain\b', caseSensitive: false);
  static const _latamRegions = {
    'MX',
    'AR',
    'CO',
    'CL',
    'PE',
    'VE',
    'EC',
    'UY',
    'PY',
    'BO',
    'CR',
    'PA',
    'GT',
    'HN',
    'SV',
    'NI',
    'DO',
    'CU',
    'PR',
    'US'
  };

  /// Mejor tráiler de YouTube de una película: español latino > español > inglés.
  /// En TMDB la región de un video no es fiable, así que también se mira el nombre
  /// ("Español Latino", "Castellano"...). `latino` solo es true si hay indicios claros.
  Future<Map<String, dynamic>?> movieTrailer(int tmdbId,
      [String type = 'movie']) async {
    if (!enabled) throw StateError('Falta la clave de TMDB.');
    final j = await _getJson(_uri(
        '/$type/$tmdbId/videos', {'include_video_language': 'es,en,null'}));
    Map<String, dynamic>? best;
    var bestScore = -1, bestLatino = false;
    for (final e in (j['results'] as List? ?? const [])) {
      final v = (e as Map).cast<String, dynamic>();
      if (v['site'] != 'YouTube') continue;
      var s = v['type'] == 'Trailer'
          ? 50
          : v['type'] == 'Teaser'
              ? 10
              : -1;
      if (s < 0) continue;
      final lang = v['iso_639_1'], region = v['iso_3166_1'];
      final name = '${v['name'] ?? ''}';
      final nameLat = _reLatino.hasMatch(name);
      final nameCast = _reCastellano.hasMatch(name);
      var latino = false;
      if (lang == 'es') {
        latino = nameLat || (_latamRegions.contains(region) && !nameCast);
        final spain = nameCast || (region == 'ES' && !nameLat);
        s += latino
            ? 400
            : spain
                ? 150
                : 250;
      } else if (lang == 'en') {
        s += 100;
      }
      if (v['official'] == true) s += 5;
      if (s > bestScore) {
        bestScore = s;
        best = v;
        bestLatino = latino;
      }
    }
    if (best == null) return null;
    return {
      'key': best['key'],
      'name': best['name'],
      'lang': best['iso_639_1'],
      'latino': bestLatino,
    };
  }

  /// Busca películas y series. Si hay [year], los resultados de ese año van primero.
  /// Con [type] ('movie' o 'tv') solo devuelve ese tipo.
  Future<List<Map<String, dynamic>>> search(String query,
      {int? year, String? type}) async {
    if (!enabled || query.trim().isEmpty) return [];
    final j = await _getJson(_uri(
        '/search/multi', {'query': query.trim(), 'include_adult': 'false'}));
    final out = <Map<String, dynamic>>[];
    for (final r in (j['results'] as List? ?? const [])) {
      final m = (r as Map).cast<String, dynamic>();
      final kind = m['media_type'];
      if (kind != 'movie' && kind != 'tv') continue;
      if (type != null && kind != type) continue;
      final date = ((m['release_date'] ?? m['first_air_date']) ?? '') as String;
      final poster = m['poster_path'] as String?;
      out.add({
        'id': m['id'],
        'type': kind,
        'title': (m['title'] ?? m['name'] ?? '').toString(),
        'year': date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null,
        'overview': (m['overview'] ?? '').toString(),
        'rating': (m['vote_average'] as num?)?.toDouble(),
        'posterUrl': poster == null ? null : '$_img/w185$poster',
      });
    }
    if (year == null) return out;
    return [
      ...out.where((c) => c['year'] == year),
      ...out.where((c) => c['year'] != year),
    ];
  }

  /// Enlaza el video [id] con una ficha de TMDB: descarga datos, carátula y fondo.
  Future<Map<String, dynamic>> match(String id, int tmdbId, String type) async {
    if (!enabled) throw StateError('Falta la clave de TMDB.');
    if (type != 'movie' && type != 'tv')
      throw ArgumentError('Tipo inválido: $type');
    final d = await _getJson(_uri('/$type/$tmdbId', {
      'append_to_response':
          'credits,videos,external_ids,${type == 'tv' ? 'content_ratings' : 'release_dates'}',
      'include_video_language': 'es,en,null',
    }));
    final tv = type == 'tv';
    final date =
        ((tv ? d['first_air_date'] : d['release_date']) ?? '') as String;
    final credits = (d['credits'] as Map?)?.cast<String, dynamic>() ?? const {};
    final votes = (d['vote_average'] as num?)?.toDouble() ?? 0;
    final runtime =
        tv ? (d['episode_run_time'] as List?)?.firstOrNull : d['runtime'];
    final old = profile(id);
    final external = d['external_ids'];
    final Object? imdbId =
        tv ? (external is Map ? external['imdb_id'] : null) : d['imdb_id'];

    final prof = <String, dynamic>{
      'title': tv ? d['name'] : d['title'],
      'originalTitle': tv ? d['original_name'] : d['original_title'],
      'year': date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null,
      'overview': _clean(d['overview']),
      'tagline': _clean(d['tagline']),
      'rating': votes > 0 ? double.parse(votes.toStringAsFixed(1)) : null,
      'runtime': runtime is int && runtime > 0 ? runtime : null,
      'genres': _names(d['genres']),
      'cast': _names(credits['cast']),
      'directors': tv
          ? _names(d['created_by'], max: 3)
          : _names(credits['crew'], job: 'Director', max: 3),
      'tmdbId': tmdbId,
      'imdbId': imdbId,
      'mediaType': type,
      'trailerKey': _trailer(d['videos']),
      'posterV': old?['posterV'] ?? 0,
      'backdropV': old?['backdropV'] ?? 0,
    };

    // Clasificación de edades (México primero). Si TMDB no la tiene, se guarda vacía
    // junto con la fecha para no volver a preguntar en cada escaneo.
    final cert = _certification(d[tv ? 'content_ratings' : 'release_dates']);
    prof['certification'] = cert?.cert;
    prof['certCountry'] = cert?.country;
    prof['certAt'] = DateTime.now().millisecondsSinceEpoch;

    // Óscares (Wikidata). Si falla, no se bloquea el emparejado: backfillOscars() lo reintenta.
    if (imdbId is String && imdbId.isNotEmpty) {
      try {
        final o = await fetchOscars(imdbId).timeout(const Duration(seconds: 8));
        prof['oscars'] = o;
        prof['oscarsAt'] = DateTime.now().millisecondsSinceEpoch;
      } catch (e) {
        print('[óscar] no se pudo consultar Wikidata ($imdbId): $e');
      }
    }

    final poster = d['poster_path'] as String?;
    final backdrop = d['backdrop_path'] as String?;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (poster != null &&
        await _download(
            '$_img/w500$poster', File(p.join(_art.path, '${id}_poster.jpg')))) {
      prof['posterV'] = now;
    }
    if (backdrop != null &&
        await _download('$_img/w1280$backdrop',
            File(p.join(_art.path, '${id}_backdrop.jpg')))) {
      prof['backdropV'] = now;
    }
    _tried.remove(id);
    _store.data[id] = prof;
    _store.save();
    return prof;
  }

  /// Deduce título y año del nombre de archivo ("Dune.Part.Two.2024.1080p.WEB-DL" → Dune Part Two, 2024).
  static ({String title, int? year}) parseName(String raw) {
    var s = raw
        .replaceAll(RegExp(r'[._]+'), ' ')
        .replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
    int? year;
    final years = RegExp(r'[\(\s]((?:19|20)\d{2})(?=[\)\s]|$)')
        .allMatches(s)
        .where((m) => m.start > 0)
        .toList();
    var cut = s.length;
    if (years.isNotEmpty) {
      year = int.parse(years.last.group(1)!);
      cut = years.last.start;
    } else {
      final tag = RegExp(
              r'\b(2160p|1080p|720p|480p|4k|uhd|bluray|blu-ray|brrip|bdrip|webrip|web-dl|webdl|hdrip|dvdrip|x264|x265|h264|h265|hevc|hdr|remux|latino|castellano|dual|multi)\b',
              caseSensitive: false)
          .firstMatch(s);
      if (tag != null && tag.start > 0) cut = tag.start;
    }
    s = s
        .substring(0, cut)
        .replaceAll(RegExp(r'[\(\)\-]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return (title: s, year: year);
  }

  static String _alnum(Object? o) => '$o'
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

  /// Busca por el nombre del archivo y enlaza el mejor resultado. null si no hay coincidencia clara.
  /// Para series se pasa `type: 'tv'` (y, si se conoce, el año de la carpeta).
  Future<Map<String, dynamic>?> autoMatch(String id, String fileTitle,
      {String? type, int? year}) async {
    final n = parseName(fileTitle);
    if (n.title.isEmpty) return null;
    final yr = year ?? n.year;
    final found = await search(n.title, year: yr, type: type);
    if (found.isEmpty) return null;
    final best = found.first;
    final y = best['year'] as int?;
    if (yr != null && (y == null || (y - yr).abs() > 1)) {
      // Una serie puede llevar en la carpeta el año de otra temporada: si el título
      // coincide exactamente, se acepta.
      final exact = type == 'tv' && _alnum(best['title']) == _alnum(n.title);
      if (!exact) return null;
    }
    return match(id, best['id'] as int, best['type'] as String);
  }

  /// Empareja en segundo plano los videos sin perfil. Devuelve cuántos enlazó.
  Future<int> autoScrape(List<({String id, String title})> items,
      {void Function()? onChange}) async {
    if (!enabled || _scraping) return 0;
    _scraping = true;
    var n = 0;
    try {
      for (final it in items) {
        if (profile(it.id) != null || _tried.containsKey(it.id)) continue;
        try {
          if (await autoMatch(it.id, it.title) == null) {
            _tried[it.id] =
                true; // sin coincidencia: no insistir (se puede hacer a mano)
          } else {
            n++;
            onChange?.call();
          }
        } catch (e) {
          print('[perfil] TMDB no disponible, se reintentará luego: $e');
          break;
        }
        _store.save();
        await Future.delayed(const Duration(milliseconds: 250));
      }
    } finally {
      _scraping = false;
    }
    if (n > 0) print('[perfil] $n perfiles nuevos desde TMDB.');
    return n;
  }

  // ---------- explorar (discover) y peticiones ----------
  /// TMDB no deja pasar de la página 500 en una misma combinación de filtros.
  static const maxDiscoverPage = 500;

  /// Respuestas recientes de discover/search (10 min) para no repetir llamadas a TMDB.
  final _discoverCache = <String, ({int at, Map<String, dynamic> data})>{};
  final _genres = <String, List<Map<String, dynamic>>>{};

  /// Película de TMDB (lista o ficha) con solo lo necesario para mostrarla.
  Map<String, dynamic> _movie(Map<String, dynamic> m, [String type = 'movie']) {
    final date = (m['release_date'] ?? m['first_air_date'] ?? '').toString();
    final poster = m['poster_path'] as String?;
    final votes = (m['vote_average'] as num?)?.toDouble() ?? 0;
    return {
      'id': m['id'],
      'type': type,
      'title': (m['title'] ?? m['name'] ?? '').toString(),
      'year': date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null,
      'overview': (m['overview'] ?? '').toString(),
      'rating': votes > 0 ? double.parse(votes.toStringAsFixed(1)) : null,
      'posterUrl': poster == null ? null : '$_img/w342$poster',
    };
  }

  /// Géneros de 'movie' o 'tv' (se piden una vez y se guardan en memoria).
  Future<List<Map<String, dynamic>>> genres([String type = 'movie']) async {
    final cached = _genres[type];
    if (cached != null) return cached;
    final j = await _getJson(_uri('/genre/$type/list'));
    final out = <Map<String, dynamic>>[];
    for (final g in (j['genres'] as List? ?? const [])) {
      final m = (g as Map).cast<String, dynamic>();
      out.add({'id': m['id'], 'name': m['name']});
    }
    return _genres[type] = out;
  }

  /// Una página de películas o series. [list] es una de [exploreLists] (populares, tendencia,
  /// mejor valoradas, más votadas, recientes, en cines/emisión, próximos, año, género o
  /// búsqueda por [query]) y [filters] los filtros que se combinan con ella.
  /// Cada página trae 20 resultados; [page] se limita a [maxDiscoverPage].
  Future<
          ({
            List<Map<String, dynamic>> items,
            int page,
            int totalPages,
            int totalResults
          })>
      discover(
          {String list = 'popular',
          int page = 1,
          ExploreFilters filters = const ExploreFilters(),
          String? query,
          String type = 'movie'}) async {
    if (!enabled) throw StateError('Falta la clave de TMDB.');
    final pg = page.clamp(1, maxDiscoverPage).toInt();
    final built = buildDiscoverQuery(
        list: list, type: type, page: pg, filters: filters, query: query);
    if (built == null) {
      return (
        items: <Map<String, dynamic>>[],
        page: 1,
        totalPages: 0,
        totalResults: 0
      );
    }
    return _page(built.path, built.params, type, pg);
  }

  /// Pide una página de TMDB (con caché de 10 min) y la deja en el formato de la app.
  Future<
          ({
            List<Map<String, dynamic>> items,
            int page,
            int totalPages,
            int totalResults
          })>
      _page(String path, Map<String, String> q, String type, int pg) async {
    final key = Uri(path: path, queryParameters: q).toString();
    final now = DateTime.now().millisecondsSinceEpoch;
    final hit = _discoverCache[key];
    Map<String, dynamic> j;
    if (hit != null && now - hit.at < 600000) {
      j = hit.data;
    } else {
      j = await _getJson(_uri(path, q));
      if (_discoverCache.length > 200) _discoverCache.clear();
      _discoverCache[key] = (at: now, data: j);
    }
    final total = (j['total_pages'] as num?)?.toInt() ?? 0;
    return (
      items: [
        for (final r in (j['results'] as List? ?? const []))
          _movie((r as Map).cast<String, dynamic>(), type)
      ],
      page: pg,
      totalPages: total < maxDiscoverPage ? total : maxDiscoverPage,
      totalResults: (j['total_results'] as num?)?.toInt() ?? 0,
    );
  }

  /// Títulos parecidos a [tmdbId] según TMDB (sugerencias).
  Future<
          ({
            List<Map<String, dynamic>> items,
            int page,
            int totalPages,
            int totalResults
          })>
      recommendations(int tmdbId, String type, {int page = 1}) async {
    if (!enabled) throw StateError('Falta la clave de TMDB.');
    if (type != 'movie' && type != 'tv') {
      throw ArgumentError('Tipo inválido: $type');
    }
    return _page('/$type/$tmdbId/recommendations', {'page': '$page'}, type, page);
  }

  final _infoCache = <String, ({int at, Map<String, dynamic> data})>{};

  /// Estado y datos extra de una película o serie (en emisión, finalizada, temporadas...).
  Future<Map<String, dynamic>> info(int tmdbId, String type) async {
    if (!enabled) throw StateError('Falta la clave de TMDB.');
    if (type != 'movie' && type != 'tv') {
      throw ArgumentError('Tipo inválido: $type');
    }
    final key = '$type$tmdbId';
    final now = DateTime.now().millisecondsSinceEpoch;
    final hit = _infoCache[key];
    if (hit != null && now - hit.at < 600000) return hit.data;
    final data =
        parseTmdbInfo(await _getJson(_uri('/$type/$tmdbId')), type).toJson();
    if (_infoCache.length > 200) _infoCache.clear();
    _infoCache[key] = (at: now, data: data);
    return data;
  }

  /// Datos básicos de una película por su id (para guardar una petición). null si no existe.
  Future<Map<String, dynamic>?> summary(int tmdbId,
      [String type = 'movie']) async {
    if (!enabled) throw StateError('Falta la clave de TMDB.');
    try {
      return _movie(await _getJson(_uri('/$type/$tmdbId')), type);
    } on HttpException catch (e) {
      if (e.message.contains('404')) return null;
      rethrow;
    }
  }

  // ---------- series: temporadas y capítulos ----------
  bool tried(String id) => _tried.containsKey(id);

  void markTried(String id) {
    _tried[id] = true;
    _store.save();
  }

  Map<String, dynamic> get _seasons =>
      (_store.data['_seasons'] ??= <String, dynamic>{}) as Map<String, dynamic>;

  /// Capítulos de una temporada según TMDB (se guardan en profiles.json para no repetir).
  Future<List<Map<String, dynamic>>> _season(int tmdbId, int season) async {
    final key = '$tmdbId:$season';
    final cached = _seasons[key];
    if (cached is List) {
      return [for (final e in cached) (e as Map).cast<String, dynamic>()];
    }
    List<Map<String, dynamic>> eps;
    try {
      final j = await _getJson(_uri('/tv/$tmdbId/season/$season'));
      eps = [
        for (final e in (j['episodes'] as List? ?? const []))
          {
            'episode': (e as Map)['episode_number'],
            'name': _clean(e['name']),
            'overview': _clean(e['overview']),
            'airDate': _clean(e['air_date']),
            'runtime': e['runtime'],
            'rating': e['vote_average'],
            'still': e['still_path'],
          }
      ];
    } on HttpException catch (e) {
      if (!e.message.contains('404'))
        rethrow; // 404: esa temporada no existe en TMDB
      eps = [];
    }
    _seasons[key] = eps;
    _store.save();
    return eps;
  }

  /// Guarda en el perfil del video [videoId] el nombre, sinopsis e imagen de su capítulo.
  /// null si TMDB no conoce ese capítulo.
  Future<Map<String, dynamic>?> applyEpisode(
      String videoId, int tmdbId, int season, int episode) async {
    final eps = await _season(tmdbId, season);
    final e = eps.where((x) => x['episode'] == episode).firstOrNull;
    if (e == null) return null;
    final old = profile(videoId);
    if (old?['tmdbId'] != null) {
      // Venía de un perfil de película: fuera su carátula y fondo (el capítulo usa los de la serie).
      for (final k in const ['poster', 'backdrop']) {
        try {
          art(videoId, k)?.deleteSync();
        } catch (_) {}
      }
    }
    final air = (e['airDate'] ?? '') as String;
    final votes = (e['rating'] as num?)?.toDouble() ?? 0;
    final rt = e['runtime'];
    final prof = <String, dynamic>{
      'title': e['name'],
      'overview': e['overview'],
      'year': air.length >= 4 ? int.tryParse(air.substring(0, 4)) : null,
      'rating': votes > 0 ? double.parse(votes.toStringAsFixed(1)) : null,
      'runtime': rt is int && rt > 0 ? rt : null,
      'airDate': air.isEmpty ? null : air,
      'season': season,
      'episode': episode,
      'showTmdbId': tmdbId,
      'stillV': old?['stillV'] ?? 0,
    };
    // Un nombre escrito a mano en el servidor no se pierde al volver a sincronizar la serie.
    if (old?['titleManual'] == true && old?['title'] != null) {
      prof['title'] = old!['title'];
      prof['titleManual'] = true;
    }
    final still = e['still'] as String?;
    if (still != null &&
        await _download('$_img/w500$still',
            File(p.join(_art.path, '${videoId}_still.jpg')))) {
      prof['stillV'] = DateTime.now().millisecondsSinceEpoch;
    }
    _tried.remove(videoId);
    _store.data[videoId] = prof;
    _store.save();
    return prof;
  }

  /// Borra los perfiles de varios videos (capítulos de una serie que se restablece).
  void forget(Iterable<String> ids) {
    for (final id in ids) {
      _store.data.remove(id);
      try {
        art(id, 'still')?.deleteSync();
      } catch (_) {}
    }
    _store.save();
  }

  // ---------- edición manual ----------
  static String? _clean(Object? o) {
    final t = o?.toString().trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  static List<String> _list(Object? o) => o is List
      ? [
          for (final e in o)
            if ('$e'.trim().isNotEmpty) '$e'.trim()
        ]
      : '${o ?? ''}'
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

  /// Aplica cambios manuales. `posterUrl` / `backdropUrl` descargan una imagen propia.
  Future<Map<String, dynamic>> update(String id, Map<String, dynamic> e) async {
    final cur = <String, dynamic>{...?profile(id)};
    for (final k in const ['title', 'originalTitle', 'overview', 'tagline']) {
      if (e.containsKey(k)) cur[k] = _clean(e[k]);
    }
    if (e.containsKey('titleManual')) cur['titleManual'] = e['titleManual'] == true;
    if (e.containsKey('year'))
      cur['year'] = int.tryParse('${e['year']}'.trim());
    if (e.containsKey('runtime'))
      cur['runtime'] = int.tryParse('${e['runtime']}'.trim());
    if (e.containsKey('rating')) {
      final r = double.tryParse('${e['rating']}'.trim().replaceAll(',', '.'));
      cur['rating'] = r == null ? null : r.clamp(0.0, 10.0);
    }
    for (final k in const ['genres', 'cast', 'directors']) {
      if (e.containsKey(k)) cur[k] = _list(e[k]);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    // Clasificación de edades escrita a mano (A, B, B15, C, PG-13, TV-MA, 12, 16...).
    // Con certAt puesto, la consulta automática a TMDB no la vuelve a tocar.
    if (e.containsKey('certification')) {
      final c = _clean(e['certification']);
      cur['certification'] = c;
      cur['certCountry'] = c == null ? null : (_clean(e['certCountry']) ?? cur['certCountry'] ?? 'MX');
      cur['certAt'] = now;
    }
    final pu = _clean(e['posterUrl']), bu = _clean(e['backdropUrl']);
    if (pu != null &&
        await _download(pu, File(p.join(_art.path, '${id}_poster.jpg')))) {
      cur['posterV'] = now;
    }
    if (bu != null &&
        await _download(bu, File(p.join(_art.path, '${id}_backdrop.jpg')))) {
      cur['backdropV'] = now;
    }
    _tried.remove(id);
    _store.data[id] = cur;
    _store.save();
    return cur;
  }

  /// Usa una imagen del disco como carátula de [id] (crea el perfil mínimo si no existía).
  Future<Map<String, dynamic>> setPosterFile(String id, String sourcePath) async {
    final src = File(sourcePath);
    if (!src.existsSync()) throw StateError('No se encontró la imagen.');
    final out = File(p.join(_art.path, '${id}_poster.jpg'));
    final tmp = File('${out.path}.tmp');
    await src.copy(tmp.path);
    await tmp.rename(out.path);
    final cur = <String, dynamic>{...?profile(id)};
    cur['posterV'] = DateTime.now().millisecondsSinceEpoch;
    _tried.remove(id);
    _store.data[id] = cur;
    _store.save();
    return cur;
  }

  /// Usa una imagen del disco como fondo horizontal de [id] (la de arriba al entrar a la
  /// película o serie). Acepta JPG, PNG, WebP, etc.: se valida, se reduce a 1920 px de ancho
  /// como máximo y se guarda como JPG real. Crea el perfil mínimo si no existía.
  Future<Map<String, dynamic>> setBackdropFile(
      String id, String sourcePath) async {
    final src = File(sourcePath);
    if (!src.existsSync()) throw StateError('No se encontró la imagen.');
    final bytes = await src.readAsBytes();
    final jpg = await Isolate.run(() => _backdropToJpg(bytes));
    if (jpg == null) throw StateError('No se pudo leer esa imagen.');
    final out = File(p.join(_art.path, '${id}_backdrop.jpg'));
    final tmp = File('${out.path}.tmp');
    await tmp.writeAsBytes(jpg, flush: true);
    await tmp.rename(out.path);
    final cur = <String, dynamic>{...?profile(id)};
    cur['backdropV'] = DateTime.now().millisecondsSinceEpoch;
    _tried.remove(id);
    _store.data[id] = cur;
    _store.save();
    return cur;
  }

  /// Decodifica cualquier imagen y la devuelve como JPG de 1920 px de ancho como máximo.
  /// null si los bytes no son una imagen.
  static Uint8List? _backdropToJpg(Uint8List bytes) {
    var im = img.decodeImage(bytes);
    if (im == null) return null;
    if (im.width > 1920) im = img.copyResize(im, width: 1920);
    return Uint8List.fromList(img.encodeJpg(im, quality: 88));
  }

  /// Borra el perfil y las imágenes (el video vuelve a mostrarse con su nombre de archivo).
  void reset(String id) {
    _store.data.remove(id);
    _tried[id] =
        true; // el usuario lo quitó a propósito: no volver a emparejar solo
    for (final k in const ['poster', 'backdrop', 'still']) {
      try {
        art(id, k)?.deleteSync();
      } catch (_) {}
    }
    _store.save();
  }

  // ---------- Óscares (Wikidata) ----------
  // TMDB no publica premios. Wikidata sí, es gratis y no pide clave: se busca el elemento
  // por su id de IMDb (P345) y se leen sus premios recibidos (P166) que sean categorías
  // de los Óscar (Q19020). Etiquetas en español y, si faltan, en inglés.
  static const _sparql = 'https://query.wikidata.org/sparql';
  static const _bestPictureQid = 'Q102427';

  /// Devuelve `{categories: [...], bestPicture: bool}` (categories vacío = sin Óscares).
  /// Lanza si Wikidata no responde, para poder reintentar más tarde.
  Future<Map<String, dynamic>> fetchOscars(String imdbId) async {
    // El id va dentro de la consulta: solo se aceptan ids de IMDb bien formados.
    if (!RegExp(r'^tt\d{5,10}$').hasMatch(imdbId)) {
      return {'categories': <String>[], 'bestPicture': false};
    }
    final query = '''
SELECT DISTINCT ?award ?awardLabel WHERE {
  ?item wdt:P345 "$imdbId" .
  ?item wdt:P166 ?award .
  ?award wdt:P31/wdt:P279* wd:Q19020 .
  SERVICE wikibase:label { bd:serviceParam wikibase:language "es,en". }
}''';
    final uri = Uri.parse(_sparql)
        .replace(queryParameters: {'query': query, 'format': 'json'});
    final req = await _http.getUrl(uri).timeout(const Duration(seconds: 15));
    req.headers
      ..set('accept', 'application/sparql-results+json')
      ..set('user-agent', 'MiStreaming/1.0 (servidor multimedia personal)');
    final res = await req.close().timeout(const Duration(seconds: 25));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw HttpException('Wikidata respondió ${res.statusCode}');
    }
    final rows = ((jsonDecode(body) as Map)['results'] as Map?)?['bindings']
            as List? ??
        const [];
    final seen = <String>{};
    final cats = <String>[];
    var best = false;
    for (final r in rows) {
      final m = (r as Map).cast<String, dynamic>();
      final qid = '${(m['award'] as Map?)?['value'] ?? ''}'.split('/').last;
      final label = '${(m['awardLabel'] as Map?)?['value'] ?? ''}'.trim();
      // Sin etiqueta, Wikidata devuelve el propio Q123: se descarta.
      if (qid.isEmpty || label.isEmpty || RegExp(r'^Q\d+$').hasMatch(label)) {
        continue;
      }
      if (!seen.add(qid)) continue;
      final clean = cleanOscarCategory(label);
      if (qid == _bestPictureQid || isBestPictureLabel(clean)) best = true;
      cats.add(clean);
    }
    // Mejor película primero; el resto por orden alfabético.
    cats.sort((a, b) {
      final x = isBestPictureLabel(a) ? 0 : 1, y = isBestPictureLabel(b) ? 0 : 1;
      return x != y ? x - y : a.compareTo(b);
    });
    return {'categories': cats, 'bestPicture': best};
  }

  /// Consulta los Óscares de los perfiles ya emparejados que aún no se han revisado.
  /// Los estrenos recientes se vuelven a revisar cada 30 días (la ceremonia es una vez al año).
  Future<int> backfillOscars({void Function()? onChange}) async {
    if (_oscarBusy) return 0;
    _oscarBusy = true;
    var changed = 0;
    try {
      final now = DateTime.now();
      const month = 30 * 24 * 3600 * 1000;
      for (final key in _store.data.keys.toList()) {
        final cur = _store.data[key];
        if (key.startsWith('_') || cur is! Map) continue;
        final imdb = cur['imdbId'];
        if (imdb is! String || imdb.isEmpty) continue;
        final at = cur['oscarsAt'] as int?;
        final year = cur['year'] as int?;
        final recent = year != null && year >= now.year - 1;
        final stale =
            at != null && recent && now.millisecondsSinceEpoch - at > month;
        if (at != null && !stale) continue;
        try {
          final o = await fetchOscars(imdb);
          // El perfil pudo cambiar o borrarse mientras se esperaba.
          final still = _store.data[key];
          if (still is! Map || still['imdbId'] != imdb) continue;
          final before = '${still['oscars']}';
          still['oscars'] = o;
          still['oscarsAt'] = now.millisecondsSinceEpoch;
          _store.save();
          if ('${still['oscars']}' != before) {
            changed++;
            onChange?.call();
          }
        } catch (e) {
          print('[óscar] Wikidata no disponible, se reintentará luego: $e');
          break;
        }
        await Future.delayed(const Duration(milliseconds: 400));
      }
    } finally {
      _oscarBusy = false;
    }
    if (changed > 0) print('[óscar] $changed perfiles con datos de Óscar nuevos.');
    return changed;
  }

  /// Pide la clasificación de edades de los perfiles ya emparejados que aún no la tienen.
  /// Los que TMDB no clasificaba se vuelven a revisar cada 60 días.
  Future<int> backfillCertifications({void Function()? onChange}) async {
    if (!enabled || _certBusy) return 0;
    _certBusy = true;
    var changed = 0;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      const retry = 60 * 24 * 3600 * 1000;
      for (final key in _store.data.keys.toList()) {
        final cur = _store.data[key];
        if (key.startsWith('_') || cur is! Map) continue;
        final tmdbId = cur['tmdbId'], type = cur['mediaType'];
        if (tmdbId is! int || (type != 'movie' && type != 'tv')) continue;
        final at = cur['certAt'] as int?;
        if (at != null && (cur['certification'] != null || now - at < retry)) {
          continue;
        }
        try {
          final j = await _getJson(_uri(
              '/$type/$tmdbId/${type == 'tv' ? 'content_ratings' : 'release_dates'}'));
          final c = _certification(j);
          final still = _store.data[key];
          if (still is! Map || still['tmdbId'] != tmdbId) continue;
          still['certification'] = c?.cert;
          still['certCountry'] = c?.country;
          still['certAt'] = now;
          _store.save();
          if (c != null) {
            changed++;
            onChange?.call();
          }
        } catch (e) {
          print('[clasificación] TMDB no disponible, se reintentará luego: $e');
          break;
        }
        await Future.delayed(const Duration(milliseconds: 250));
      }
    } finally {
      _certBusy = false;
    }
    if (changed > 0) print('[clasificación] $changed perfiles con clasificación nueva.');
    return changed;
  }

  void dispose() => _http.close(force: true);
}