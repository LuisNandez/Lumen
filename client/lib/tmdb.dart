import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart';

import 'api.dart';
import 'core.dart';
import 'remote.dart';

/// Cliente directo de TMDB: devuelve lo mismo que el servidor (`/api/tmdb/...`), para
/// poder explorar el catálogo cuando el servidor está apagado.
class TmdbDirect {
  TmdbDirect(this.key, this.language)
      : _dio = Dio(BaseOptions(
            baseUrl: 'https://api.themoviedb.org/3',
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 20),
            headers: {
              'accept': 'application/json',
              // Clave v3 (32 caracteres) o "token de acceso de lectura" v4 (JWT largo).
              if (key.length > 40) 'authorization': 'Bearer $key',
            }));

  final String key, language;
  final Dio _dio;
  final _genres = <String, List<TmdbGenre>>{};

  static const _img = 'https://image.tmdb.org/t/p';
  static const maxDiscoverPage = 500;

  Future<Map<String, dynamic>> _get(String path, [Map<String, String> q = const {}]) async {
    final r = await _dio.get(path, queryParameters: {
      'language': language,
      if (key.length <= 40) 'api_key': key,
      ...q,
    });
    return (r.data as Map).cast<String, dynamic>();
  }

  static TmdbMovie _movie(Map<String, dynamic> m, String type) {
    final date = (m['release_date'] ?? m['first_air_date'] ?? '').toString();
    final poster = m['poster_path'] as String?;
    final votes = (m['vote_average'] as num?)?.toDouble() ?? 0;
    return TmdbMovie(
      m['id'] as int,
      (m['title'] ?? m['name'] ?? '').toString(),
      type: type,
      year: date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null,
      overview: (m['overview'] ?? '').toString(),
      rating: votes > 0 ? double.parse(votes.toStringAsFixed(1)) : null,
      posterUrl: poster == null ? null : '$_img/w342$poster',
    );
  }

  static DiscoverPage _page(Map<String, dynamic> j, String type, int pg) {
    final total = (j['total_pages'] as num?)?.toInt() ?? 0;
    return DiscoverPage(
      [
        for (final r in (j['results'] as List? ?? const []))
          _movie((r as Map).cast<String, dynamic>(), type)
      ],
      pg,
      total < maxDiscoverPage ? total : maxDiscoverPage,
      (j['total_results'] as num?)?.toInt() ?? 0,
    );
  }

  Future<DiscoverPage> discover(
      {String list = 'popular',
      int page = 1,
      ExploreFilters filters = const ExploreFilters(),
      String? q,
      String type = 'movie'}) async {
    final pg = page.clamp(1, maxDiscoverPage).toInt();
    final built = buildDiscoverQuery(
        list: list, type: type, page: pg, filters: filters, query: q);
    if (built == null) return const DiscoverPage([], 1, 0, 0);
    return _page(await _get(built.path, built.params), type, pg);
  }

  Future<DiscoverPage> recommendations(int tmdbId, String type) async {
    if (type != 'movie' && type != 'tv') throw ArgumentError('Tipo inválido: $type');
    return _page(await _get('/$type/$tmdbId/recommendations'), type, 1);
  }

  Future<TmdbInfo> info(int tmdbId, String type) async {
    if (type != 'movie' && type != 'tv') throw ArgumentError('Tipo inválido: $type');
    return parseTmdbInfo(await _get('/$type/$tmdbId'), type);
  }

  Future<List<TmdbGenre>> genres(String type) async {
    final cached = _genres[type];
    if (cached != null) return cached;
    final j = await _get('/genre/$type/list');
    return _genres[type] = [
      for (final g in (j['genres'] as List? ?? const []))
        TmdbGenre.fromJson((g as Map).cast<String, dynamic>())
    ];
  }

  static final _reLatino = RegExp(r'latino|latam|latinoam|hispanoam|m[eé]xico|\bmx\b',
      caseSensitive: false);
  static final _reCastellano =
      RegExp(r'castellano|espa[ñn]a|\bspain\b', caseSensitive: false);
  static const _latamRegions = {
    'MX', 'AR', 'CO', 'CL', 'PE', 'VE', 'EC', 'UY', 'PY', 'BO', 'CR', 'PA', 'GT',
    'HN', 'SV', 'NI', 'DO', 'CU', 'PR', 'US'
  };

  /// Mejor tráiler de YouTube: español latino > español > inglés (misma lógica del servidor).
  Future<Map<String, dynamic>?> movieTrailer(int tmdbId, String type) async {
    final j = await _get(
        '/$type/$tmdbId/videos', {'include_video_language': 'es,en,null'});
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
}

/// El catálogo de peticiones: usa el servidor y, si está apagado (o no responde), TMDB
/// directamente con la clave que el servidor entregó al emparejar.
class Catalog {
  const Catalog(this.api, this.direct, this.offline);
  final Api api;
  final TmdbDirect? direct;
  final bool offline;

  /// Hay forma de explorar el catálogo aunque el servidor esté apagado.
  bool get canExploreOffline => direct != null;

  Future<T> _run<T>(Future<T> Function() server, Future<T> Function(TmdbDirect d) fallback) async {
    final d = direct;
    if (d != null && offline) return fallback(d);
    try {
      return await server();
    } on DioException catch (e) {
      if (d != null && e.response == null) return fallback(d);
      rethrow;
    }
  }

  Future<DiscoverPage> discover(
          {String list = 'popular',
          int page = 1,
          ExploreFilters filters = const ExploreFilters(),
          String? q,
          String type = 'movie'}) =>
      _run(
          () => api.discover(
              list: list, page: page, filters: filters, q: q, type: type),
          (d) => d.discover(
              list: list, page: page, filters: filters, q: q, type: type));

  Future<DiscoverPage> recommendations(int tmdbId, {String type = 'movie'}) =>
      _run(() => api.recommendations(tmdbId, type: type),
          (d) => d.recommendations(tmdbId, type));

  Future<TmdbInfo> info(int tmdbId, {String type = 'movie'}) =>
      _run(() => api.tmdbInfo(tmdbId, type: type), (d) => d.info(tmdbId, type));

  Future<List<TmdbGenre>> genres([String type = 'movie']) =>
      _run(() => api.genres(type), (d) => d.genres(type));

  Future<Map<String, dynamic>?> movieTrailer(int tmdbId, {String type = 'movie'}) =>
      _run(() => api.movieTrailer(tmdbId, type: type), (d) => d.movieTrailer(tmdbId, type));
}

final catalogProvider = Provider<Catalog?>((ref) {
  final api = ref.watch(apiProvider);
  if (api == null) return null;
  final c = ref.watch(tmdbCredsProvider);
  final offline = ref.watch(serverOfflineProvider);
  return Catalog(api, c == null ? null : TmdbDirect(c.key, c.language), offline);
});
