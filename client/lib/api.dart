import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:shared/shared.dart';
import 'package:shared/audiobook.dart';

class UnauthorizedException implements Exception {}

class PairingException implements Exception {
  const PairingException(this.message);
  final String message;
}

/// Texto legible para mostrar un error de red o del servidor.
String errText(Object e) {
  if (e is DioException) {
    final d = e.response?.data;
    if (d is String && d.isNotEmpty) return d;
    if (e.response?.statusCode == 404) return 'Sin coincidencias en TMDB.';
    return 'No se pudo conectar con el servidor.';
  }
  return '$e';
}

String _normalize(String host) =>
    host.startsWith('http') ? host : 'http://$host';

Dio _dio(String host, [Map<String, String>? headers]) => Dio(BaseOptions(
      baseUrl: _normalize(host),
      connectTimeout: const Duration(seconds: 4),
      headers: headers,
    ));

/// Resultado de subir una posición al servidor.
enum ProgressSave {
  saved,
  retry,
  rejected,

  /// El servidor ya tenía una posición con una marca de orden mayor de este dispositivo.
  stale
}

class Api {
  Api(this.host, this.token);
  final String host, token;

  Map<String, String> get authHeaders => {'Authorization': 'Bearer $token'};
  late final Dio _client = _dio(host, authHeaders);

  static Future<ServerInfo> info(String host) async => ServerInfo.fromJson(
      (await _dio(host).get('/api/info')).data as Map<String, dynamic>);

  /// Intercambia el PIN por un token. Lanza [PairingException] si el PIN es incorrecto.
  static Future<String> pair(String host, String pin, String device) async {
    try {
      final r = await _dio(host)
          .post('/api/pair', data: {'pin': pin, 'device': device});
      return r.data['token'] as String;
    } on DioException catch (e) {
      if (e.response?.statusCode == 403)
        throw const PairingException('PIN incorrecto');
      rethrow;
    }
  }

  /// APK de actualización que ofrece el servidor (`available: false` si no hay).
  Future<AppUpdateInfo> updateInfo() async => AppUpdateInfo.fromJson(
      (await _client.get('/api/update/android')).data as Map<String, dynamic>);

  /// Descarga el APK a [part] (reanuda si ya había una parte). Devuelve cuando termina.
  Future<void> downloadApk(String part, int total,
      {required void Function(int received) onProgress,
      required bool Function() cancelled}) async {
    final f = File(part);
    var have = f.existsSync() ? f.lengthSync() : 0;
    if (have > total) {
      f.deleteSync();
      have = 0;
    }
    if (have == total) {
      onProgress(have);
      return;
    }
    final r = await _client.get<ResponseBody>('/api/update/android/apk',
        options: Options(
            responseType: ResponseType.stream,
            receiveTimeout: const Duration(seconds: 30),
            headers: have > 0 ? {'Range': 'bytes=$have-'} : null));
    // Si el servidor ignoró el Range (200), se empieza de cero.
    if (r.statusCode != 206) have = 0;
    final sink = f.openSync(mode: have > 0 ? FileMode.append : FileMode.write);
    try {
      var got = have;
      await for (final chunk in r.data!.stream) {
        if (cancelled()) throw StateError('cancelado');
        sink.writeFromSync(chunk);
        got += chunk.length;
        onProgress(got);
      }
    } finally {
      sink.closeSync();
    }
  }

  Future<List<VideoItem>> library() async {
    try {
      final r = await _client.get('/api/library');
      return (r.data['items'] as List)
          .map((e) => VideoItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) throw UnauthorizedException();
      rethrow;
    }
  }

  Future<VideoDetail> detail(String id) async =>
      VideoDetail.fromJson(await detailRaw(id));

  /// Ficha tal como la entrega el servidor (se guarda tal cual para verla sin conexión).
  Future<Map<String, dynamic>> detailRaw(String id,
          {CancelToken? cancel}) async =>
      ((await _client.get('/api/videos/$id', cancelToken: cancel)).data as Map)
          .cast<String, dynamic>();

  // ---------- Descargas (ver sin servidor) ----------

  /// Abre el archivo original en streaming. Con [from] > 0 pide solo desde ese byte
  /// (HTTP Range) para reanudar. El servidor responde 206, 200 (ignora Range) o 416.
  Future<Response<ResponseBody>> streamVideo(String id,
          {int from = 0, CancelToken? cancel}) =>
      _client.get<ResponseBody>('/api/videos/$id/stream',
          cancelToken: cancel,
          options: Options(
            responseType: ResponseType.stream,
            headers: {if (from > 0) 'range': 'bytes=$from-'},
            validateStatus: (s) => s == 200 || s == 206 || s == 416,
          ));

  /// Carátula, fondo o miniatura ('poster', 'backdrop', 'thumbnail'). null si no existe.
  /// Con [show] = true pide la imagen de una serie ('poster' o 'backdrop').
  /// Para el capítulo también existe 'still' (imagen del episodio).
  Future<Uint8List?> imageBytes(String id, String kind,
      {CancelToken? cancel, bool show = false}) async {
    final r = await _client.get<List<int>>(
        '/api/${show ? 'shows' : 'videos'}/$id/$kind',
        cancelToken: cancel,
        options: Options(
            responseType: ResponseType.bytes,
            validateStatus: (s) => s == 200 || s == 404));
    if (r.statusCode != 200 || r.data == null) return null;
    return Uint8List.fromList(r.data!);
  }

  /// Texto de un subtítulo externo (el servidor ya lo entrega en UTF-8). null si no existe.
  Future<String?> subtitleText(String id, String sid,
      {CancelToken? cancel}) async {
    final r = await _client.get<String>('/api/videos/$id/subtitles/$sid',
        cancelToken: cancel,
        options: Options(
            responseType: ResponseType.plain,
            validateStatus: (s) => s == 200 || s == 404));
    return r.statusCode == 200 ? r.data : null;
  }

  String get _tk => Uri.encodeQueryComponent(token);

  /// HLS transcodificado a [q] píxeles de alto con la pista de audio [audio].
  String hlsUrl(String id, int q, int audio) =>
      '${_normalize(host)}/api/videos/$id/hls/index.m3u8?q=$q&a=$audio&token=$_tk';

  String subtitleUrl(String id, String sid) =>
      '${_normalize(host)}/api/videos/$id/subtitles/$sid?token=$_tk';

  String thumbUrl(String id) => '${_normalize(host)}/api/videos/$id/thumbnail';

  Future<List<AudioBook>> audioBooks() async {
    try {
      final data = (await _client.get('/api/audiobooks')).data;
      return [
        for (final b in data['items'] as List)
          AudioBook.fromJson(b as Map<String, dynamic>)
      ];
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return []; // Servidor anterior.
      rethrow;
    }
  }

  String bookTrackUrl(AudioBook book, BookTrack track) =>
      '${_normalize(host)}/api/audiobooks/${book.id}/tracks/${track.id}';
  String bookArtUrl(AudioBook book, String kind) =>
      '${_normalize(host)}/api/audiobooks/${book.id}/art/$kind?v=${book.revision}';

  Future<Response<ResponseBody>> bookBytes(
          String url, int offset, CancelToken cancel) =>
      _client.get<ResponseBody>(url,
          cancelToken: cancel,
          options: Options(
            responseType: ResponseType.stream,
            receiveTimeout: const Duration(seconds: 35),
            headers: {if (offset > 0) 'Range': 'bytes=$offset-'},
            validateStatus: (s) => s == 200 || s == 206 || s == 416,
          ));

  /// Todas las series de la biblioteca.
  Future<List<ShowItem>> shows() async {
    final r = await _client.get('/api/shows');
    return [
      for (final e in r.data['items'] as List)
        ShowItem.fromJson((e as Map).cast<String, dynamic>())
    ];
  }

  /// Una serie con todos sus capítulos (ordenados por temporada y número).
  Future<ShowDetail> show(String id) async => ShowDetail.fromJson(
      (await _client.get('/api/shows/$id')).data as Map<String, dynamic>);

  /// Ficha de serie tal como la entrega el servidor (sin capítulos se guarda para verla
  /// sin conexión: {show, profile, episodes}).
  Future<Map<String, dynamic>> showRaw(String id,
          {CancelToken? cancel}) async =>
      ((await _client.get('/api/shows/$id', cancelToken: cancel)).data as Map)
          .cast<String, dynamic>();

  // ---------- Novedades (capítulos nuevos de series que ya tenías) ----------

  /// Novedades del perfil activo (una entrada por serie, la más reciente primero).
  Future<NewsData> news() async => NewsData.fromJson(
      (await _client.get('/api/news')).data as Map<String, dynamic>);

  /// Marca como abierta la novedad de [showId] o, sin él, todas. Los fallos se ignoran
  /// (a lo peor la campanita sigue encendida hasta la próxima vez).
  Future<void> markNewsRead({String? showId}) async {
    try {
      await _client
          .post('/api/news/read', data: {if (showId != null) 'showId': showId});
    } catch (_) {}
  }

  /// Imagen del capítulo (si no tiene, usa [thumbUrl]).
  String stillUrl(VideoItem v) =>
      '${_normalize(host)}/api/videos/${v.id}/still?v=${v.stillV}';

  /// Guarda la posición de reproducción; los fallos de red se ignoran.
  /// Devuelve true si el servidor la recibió (lo usan las descargas para sincronizar).
  Future<bool> saveProgress(String id, int positionMs, {int? ts}) async =>
      (await putProgress(id, positionMs, ts: ts)) == ProgressSave.saved;

  /// Como [saveProgress], pero distingue un fallo pasajero (conviene reintentar) de un
  /// rechazo definitivo (el video ya no existe: reintentar no sirve). [ts] es la marca de
  /// orden del envío: el servidor descarta una posición más vieja que otra ya recibida.
  Future<ProgressSave> putProgress(String id, int positionMs,
          {int? ts}) async =>
      (await putProgressDetailed(id, positionMs, ts: ts)).save;

  /// Igual que [putProgress] pero, si el servidor descartó el envío por antiguo
  /// ([ProgressSave.stale]), devuelve también la última marca que tenía ([staleTs]).
  Future<({ProgressSave save, int? staleTs})> putProgressDetailed(
      String id, int positionMs,
      {int? ts}) async {
    try {
      final r = await _client.put('/api/videos/$id/progress',
          data: {'positionMs': positionMs, if (ts != null) 'ts': ts},
          options: Options(
              sendTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8)));
      final d = r.data;
      if (d is Map && d['stale'] == true) {
        return (
          save: ProgressSave.stale,
          staleTs: (d['lastTs'] as num?)?.toInt()
        );
      }
      return (save: ProgressSave.saved, staleTs: null);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      // 404: el video ya no está en la biblioteca. 400: datos que nunca serán válidos.
      if (code == 404 || code == 400)
        return (save: ProgressSave.rejected, staleTs: null);
      // sin red, tiempo agotado, 401, 409 (sin perfil), 5xx...
      return (save: ProgressSave.retry, staleTs: null);
    } catch (_) {
      return (save: ProgressSave.retry, staleTs: null);
    }
  }

  /// Posición guardada en el servidor para este video y perfil (ligera: no sondea el archivo
  /// como la ficha completa). null si el servidor no responde o es una versión sin este
  /// endpoint.
  Future<({int positionMs, int watchedMs})?> progressOf(String id,
      {Duration timeout = const Duration(seconds: 4)}) async {
    try {
      final r = await _client.get('/api/videos/$id/progress',
          options: Options(receiveTimeout: timeout));
      final d = r.data;
      // Sin el campo (respuesta que no es la esperada) se trata como "no disponible".
      if (d is! Map || d['positionMs'] is! num) return null;
      return (
        positionMs: (d['positionMs'] as num?)?.toInt() ?? 0,
        watchedMs: (d['watchedMs'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// Trae al perfil actual el progreso que este dispositivo tenía de antes de los perfiles
  /// (lo que ya tenga el perfil se respeta). Devuelve cuántos videos se importaron.
  Future<int> importDeviceProgress() async {
    final r = await _client.post('/api/profiles/current/import-progress');
    final d = r.data;
    return d is Map ? (d['imported'] as num?)?.toInt() ?? 0 : 0;
  }

  /// Borra en el servidor el progreso y el "Continuar viendo" de ESTE dispositivo.
  /// Lanza si no hay conexión (para no dejar la mitad borrada).
  Future<void> resetProgress() async {
    await _client.delete('/api/progress');
  }

  /// Carátula y fondo del perfil; `?v=` cambia al editarlos para refrescar la caché de imágenes.
  String posterUrl(VideoItem v) =>
      '${_normalize(host)}/api/${v.isShow ? 'shows' : 'videos'}/${v.id}/poster?v=${v.posterV}';
  String backdropUrl(VideoItem v) =>
      '${_normalize(host)}/api/${v.isShow ? 'shows' : 'videos'}/${v.id}/backdrop?v=${v.backdropV}';

  Profile _profile(Response r) =>
      Profile.fromJson((r.data['profile'] as Map).cast<String, dynamic>());

  /// Guarda cambios manuales (título, sinopsis, valoración, posterUrl...).
  Future<Profile> saveProfile(String id, Map<String, dynamic> edits) async =>
      _profile(await _client.put('/api/videos/$id/profile', data: edits));

  Future<Profile> resetProfile(String id) async =>
      _profile(await _client.delete('/api/videos/$id/profile'));

  /// Enlaza el video con una ficha de TMDB (el servidor descarga carátula y datos).
  Future<Profile> matchProfile(String id, int tmdbId, String type) async =>
      _profile(await _client.post('/api/videos/$id/profile/match',
          data: {'tmdbId': tmdbId, 'type': type}));

  /// Busca en TMDB por el nombre del archivo. Lanza DioException 404 si no hay coincidencia.
  Future<Profile> autoProfile(String id) async =>
      _profile(await _client.post('/api/videos/$id/profile/auto'));

  /// [type]: 'tv' o 'movie' para limitar los resultados (series y capítulos buscan solo 'tv').
  Future<List<TmdbCandidate>> tmdbSearch(String q,
      {int? year, String? type}) async {
    final r = await _client.get('/api/tmdb/search', queryParameters: {
      'q': q,
      if (year != null) 'year': year,
      if (type != null) 'type': type
    });
    return [
      for (final e in r.data['results'] as List)
        TmdbCandidate.fromJson((e as Map).cast<String, dynamic>())
    ];
  }

  // ---------- Peticiones ----------

  /// Una página (20 títulos) de [list] (ver [exploreLists]) con los [filters] indicados.
  /// TMDB no permite pasar de la página 500 por combinación de filtros.
  Future<DiscoverPage> discover(
      {String list = 'popular',
      int page = 1,
      ExploreFilters filters = const ExploreFilters(),
      String? q,
      String type = 'movie'}) async {
    final r = await _client.get('/api/tmdb/discover', queryParameters: {
      'list': list,
      'type': type,
      'page': page,
      ...filters.toQuery(),
      if (q != null && q.isNotEmpty) 'q': q,
    });
    return DiscoverPage.fromJson((r.data as Map).cast<String, dynamic>());
  }

  /// Títulos parecidos a uno de TMDB (sugerencias).
  Future<DiscoverPage> recommendations(int tmdbId,
      {String type = 'movie'}) async {
    final r = await _client.get('/api/tmdb/$type/$tmdbId/recommendations');
    return DiscoverPage.fromJson((r.data as Map).cast<String, dynamic>());
  }

  /// Estado (en emisión, finalizada...), temporadas y demás datos de un título de TMDB.
  Future<TmdbInfo> tmdbInfo(int tmdbId, {String type = 'movie'}) async {
    final r = await _client.get('/api/tmdb/$type/$tmdbId/info');
    return TmdbInfo.fromJson((r.data as Map).cast<String, dynamic>());
  }

  Future<List<TmdbGenre>> genres([String type = 'movie']) async {
    final r =
        await _client.get('/api/tmdb/genres', queryParameters: {'type': type});
    return [
      for (final e in r.data['genres'] as List)
        TmdbGenre.fromJson((e as Map).cast<String, dynamic>())
    ];
  }

  /// Tráiler de YouTube de una película de TMDB (español latino si existe). null si no hay.
  Future<Map<String, dynamic>?> movieTrailer(int tmdbId,
      {String type = 'movie'}) async {
    final r = await _client.get('/api/tmdb/$type/$tmdbId/trailer');
    final t = r.data['trailer'];
    return t is Map ? t.cast<String, dynamic>() : null;
  }

  /// Clave de TMDB del servidor (para explorar el catálogo aunque el servidor se apague).
  Future<({String key, String language})?> tmdbCreds() async {
    final r = await _client.get('/api/tmdb/key');
    final key = '${r.data['key'] ?? ''}'.trim();
    if (key.isEmpty) return null;
    return (key: key, language: '${r.data['language'] ?? 'es-MX'}');
  }

  /// Peticiones y claves de TMDB de lo que ya está en la biblioteca ('123' o 'tv123').
  Future<({List<TmdbMovie> items, Set<String> owned})> requestsData() async {
    final r = await _client.get('/api/requests');
    return (
      items: [
        for (final e in r.data['items'] as List)
          TmdbMovie.fromJson((e as Map).cast<String, dynamic>())
      ],
      owned: {for (final e in (r.data['owned'] as List? ?? const [])) '$e'},
    );
  }

  /// Todas las películas pedidas (por cualquier dispositivo), las más recientes primero.
  Future<List<TmdbMovie>> requests() async {
    final r = await _client.get('/api/requests');
    return [
      for (final e in r.data['items'] as List)
        TmdbMovie.fromJson((e as Map).cast<String, dynamic>())
    ];
  }

  /// Guarda la petición por id de TMDB. Lanza DioException 409 si ya está en la biblioteca.
  Future<TmdbMovie> addRequest(int tmdbId, {String type = 'movie'}) async {
    final r = await _client
        .post('/api/requests', data: {'tmdbId': tmdbId, 'type': type});
    return TmdbMovie.fromJson((r.data['item'] as Map).cast<String, dynamic>());
  }

  /// Quita la petición de este dispositivo. Devuelve la película con su estado actual
  /// (sigue pedida si otro dispositivo también la pidió).
  Future<TmdbMovie?> removeRequest(int tmdbId, {String type = 'movie'}) async {
    final r = await _client
        .delete('/api/requests/$tmdbId', queryParameters: {'type': type});
    final item = r.data['item'];
    return item is Map
        ? TmdbMovie.fromJson(item.cast<String, dynamic>())
        : null;
  }

  /// Pide al servidor identificar en segundo plano todos los videos sin perfil.
  Future<bool> autoscrape() async =>
      (await _client.post('/api/library/autoscrape')).data['started'] == true;

  /// Marcas de intro/resumen/créditos y capítulo siguiente. Si falla, devuelve vacío.
  Future<PlaybackSegments> segments(String id) async {
    try {
      final r = await _client.get('/api/videos/$id/segments',
          options: Options(receiveTimeout: const Duration(seconds: 15)));
      return PlaybackSegments.fromJson((r.data as Map).cast<String, dynamic>());
    } catch (_) {
      return PlaybackSegments.empty;
    }
  }

  String streamUrl(String id) => '${_normalize(host)}/api/videos/$id/stream';

  // ---------- Perfiles de usuario (¿quién está viendo?) ----------

  /// Perfiles del servidor y el que usa este dispositivo. Lanza DioException 404 si el
  /// servidor es anterior a los perfiles.
  Future<ProfilesData> profiles() async => ProfilesData.fromJson(
      (await _client.get('/api/profiles')).data as Map<String, dynamic>);

  /// Avatares (.jpg) que hay en la carpeta del servidor.
  Future<List<AvatarInfo>> avatars() async {
    final r = await _client.get('/api/avatars');
    return [
      for (final e in r.data['items'] as List)
        AvatarInfo.fromJson((e as Map).cast<String, dynamic>())
    ];
  }

  /// Imagen de un avatar; `?v=` cambia cuando se sustituye el archivo.
  String avatarUrl(String id, int v) =>
      '${_normalize(host)}/api/avatars/${Uri.encodeComponent(id)}?v=$v';

  /// Crea un perfil y este dispositivo pasa a usarlo. Con [importProgress] trae el progreso
  /// que el dispositivo tenía de antes de los perfiles.
  Future<UserProfile> createProfile(String username,
      {String? avatar, String? pin, bool importProgress = false}) async {
    final r = await _client.post('/api/profiles', data: {
      'username': username,
      'avatar': avatar,
      if (pin != null) 'pin': pin,
      if (importProgress) 'importProgress': true,
    });
    return UserProfile.fromJson(
        (r.data['item'] as Map).cast<String, dynamic>());
  }

  /// Cambia el avatar y/o el PIN. Si el perfil tiene PIN hay que darlo en [currentPin].
  /// [setAvatar] distingue "no tocar el avatar" de "quitarlo" ([avatar] = null).
  Future<UserProfile> updateProfile(String username,
      {bool setAvatar = false,
      String? avatar,
      String? pin,
      bool removePin = false,
      String? currentPin}) async {
    final r = await _client
        .put('/api/profiles/${Uri.encodeComponent(username)}', data: {
      if (setAvatar) 'avatar': avatar,
      if (pin != null) 'pin': pin,
      if (removePin) 'removePin': true,
      if (currentPin != null) 'currentPin': currentPin,
    });
    return UserProfile.fromJson(
        (r.data['item'] as Map).cast<String, dynamic>());
  }

  /// Borra el perfil con su progreso y peticiones. El PIN viaja en un encabezado.
  Future<void> deleteProfile(String username, {String? pin}) async {
    await _client.delete('/api/profiles/${Uri.encodeComponent(username)}',
        options: Options(headers: {if (pin != null) 'x-profile-pin': pin}));
  }

  /// Este dispositivo pasa a actuar como [username] (pide el PIN si lo tiene).
  Future<UserProfile> selectProfile(String username, {String? pin}) async {
    final r = await _client.post(
        '/api/profiles/${Uri.encodeComponent(username)}/select',
        data: {if (pin != null) 'pin': pin});
    return UserProfile.fromJson(
        (r.data['item'] as Map).cast<String, dynamic>());
  }
}

/// Tramo del video en milisegundos. [endMs] null = hasta el final.
class Seg {
  const Seg(this.startMs, this.endMs);
  final int startMs;
  final int? endMs;
}

class NextEpisode {
  const NextEpisode(this.id, this.title);
  final String id, title;
}

class PlaybackSegments {
  const PlaybackSegments(
      {this.intro = const [],
      this.recap = const [],
      this.credits = const [],
      this.preview = const [],
      this.next});
  final List<Seg> intro, recap, credits, preview;
  final NextEpisode? next;

  static const empty = PlaybackSegments();

  factory PlaybackSegments.fromJson(Map<String, dynamic> j) {
    List<Seg> segs(String k) => [
          for (final e in (j[k] as List? ?? const []))
            if (e is Map)
              Seg((e['startMs'] as num?)?.toInt() ?? 0,
                  (e['endMs'] as num?)?.toInt())
        ];
    final n = j['next'];
    return PlaybackSegments(
      intro: segs('intro'),
      recap: segs('recap'),
      credits: segs('credits'),
      preview: segs('preview'),
      next: n is Map ? NextEpisode('${n['id']}', '${n['title'] ?? ''}') : null,
    );
  }
}
