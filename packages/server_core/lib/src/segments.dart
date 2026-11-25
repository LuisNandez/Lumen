import 'dart:convert';
import 'dart:io';

/// Marcas de intro / resumen / créditos de TheIntroDB (https://theintrodb.org).
/// TMDB no tiene estos datos: TheIntroDB es un servicio aparte, colaborativo y gratuito,
/// que identifica cada capítulo por su id de TMDB + temporada + número.
class IntroDb {
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  final _cache = <String, _Hit>{};

  static const _base = 'https://api.theintrodb.org/v3/media';
  static const _kinds = ['intro', 'recap', 'credits', 'preview'];

  /// Devuelve {intro|recap|credits|preview: [{startMs, endMs?}]}. Vacío si no hay datos.
  /// `endMs` null = hasta el final del video; `startMs` null en la API = 0.
  Future<Map<String, List<Map<String, int?>>>> lookup(
      int tmdbId, int season, int episode, int? durationMs) async {
    final key = '$tmdbId:$season:$episode';
    final c = _cache[key];
    if (c != null && c.until.isAfter(DateTime.now())) return c.data;

    var data = <String, List<Map<String, int?>>>{};
    var ttl = const Duration(hours: 12);
    final u = Uri.parse(_base).replace(queryParameters: {
      'tmdb_id': '$tmdbId',
      'season': '$season',
      'episode': '$episode',
      if (durationMs != null && durationMs > 0) 'duration_ms': '$durationMs',
    });
    try {
      final req = await _http.getUrl(u).timeout(const Duration(seconds: 8));
      req.headers.set('accept', 'application/json');
      final res = await req.close().timeout(const Duration(seconds: 10));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 200) {
        data = _parse(jsonDecode(body));
      } else if (res.statusCode != 404) {
        print('[saltos] TheIntroDB respondió ${res.statusCode} para $u');
        ttl = const Duration(minutes: 5);
      }
    } catch (e) {
      print('[saltos] no se pudo consultar TheIntroDB ($u): $e');
      ttl = const Duration(minutes: 5);
    }
    _cache[key] = _Hit(data, DateTime.now().add(ttl));
    return data;
  }

  static Map<String, List<Map<String, int?>>> _parse(Object? j) {
    final out = <String, List<Map<String, int?>>>{};
    if (j is! Map) return out;
    for (final k in _kinds) {
      final l = j[k];
      if (l is! List) continue;
      final segs = <Map<String, int?>>[];
      for (final e in l) {
        if (e is! Map) continue;
        segs.add({
          'startMs': (e['start_ms'] as num?)?.toInt() ?? 0,
          'endMs': (e['end_ms'] as num?)?.toInt(),
        });
      }
      if (segs.isNotEmpty) out[k] = segs;
    }
    return out;
  }
}

class _Hit {
  _Hit(this.data, this.until);
  final Map<String, List<Map<String, int?>>> data;
  final DateTime until;
}

final introDb = IntroDb();
