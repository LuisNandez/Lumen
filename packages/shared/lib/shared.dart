/// Puerto UDP de descubrimiento y mensaje que envía el cliente por broadcast.
const discoveryPort = 41234;
const discoveryRequest = 'MISTREAMING_DISCOVER_V1';

/// PIN fijo que la app ya trae. Con la "conexión automática" encendida el servidor lo acepta,
/// y la app lo manda sola: la persona no escribe nada. No es un secreto de verdad (va dentro de
/// la app y puede sacarse de ella); sirve para que solo se empareje quien habla como Lumen.
/// Si lo cambias, hazlo igual en el servidor y en la app (ambos usan este mismo archivo).
const kAutoPin = '731904';

class ServerInfo {
  const ServerInfo(this.name, this.port, this.version,
      {this.tmdb = false, this.open = false});
  final String name, version;
  final int port;

  /// true si el servidor tiene una clave de TMDB configurada (carátulas y sinopsis automáticas).
  final bool tmdb;

  /// true si el servidor deja entrar sin PIN (conexión automática en la red local).
  final bool open;
  factory ServerInfo.fromJson(Map<String, dynamic> j) => ServerInfo(
      j['name'] as String, j['port'] as int, j['version'] as String,
      tmdb: (j['tmdb'] as bool?) ?? false,
      open: (j['open'] as bool?) ?? false);
  Map<String, dynamic> toJson() => {
        'name': name,
        'port': port,
        'version': version,
        'tmdb': tmdb,
        'open': open
      };
}

List<String> _strings(Object? o) =>
    ((o as List?) ?? const []).map((e) => '$e').toList();

class VideoItem {
  const VideoItem(this.id, this.title, this.size,
      {this.durationMs,
      this.width,
      this.height,
      this.vcodec,
      this.acodec,
      this.positionMs = 0,
      this.year,
      this.rating,
      this.overview,
      this.genres = const [],
      this.posterV = 0,
      this.backdropV = 0,
      this.addedMs = 0,
      this.matched = false,
      this.showId,
      this.show,
      this.season,
      this.episode,
      this.epTitle,
      this.stillV = 0,
      this.isShow = false,
      this.watchedMs = 0});
  final String id, title;
  final int size, positionMs;
  final int? durationMs, width, height;
  final String? vcodec, acodec;

  // Perfil (tipo Plex): título editable, año, valoración, sinopsis, géneros.
  final int? year;
  final double? rating;
  final String? overview;
  final List<String> genres;

  /// Versión de la carátula / fondo (0 = no hay). Sirve para refrescar la caché de imágenes.
  final int posterV, backdropV;

  /// Cuándo se añadió a la biblioteca (ms), para "Agregados recientemente".
  final int addedMs;

  /// true si el perfil se enlazó con TMDB.
  final bool matched;

  // Series: si el video es un capítulo, [showId] es la serie a la que pertenece.
  final String? showId, show, epTitle;
  final int? season, episode;

  /// Versión de la imagen del capítulo (0 = no hay).
  final int stillV;

  /// true si esta "carátula" representa una serie completa (no un video reproducible).
  final bool isShow;

  /// Última vez (ms desde epoch) que se guardó progreso de este video; 0 = sin dato.
  final int watchedMs;

  bool get isEpisode => showId != null;

  /// Ej.: "T1 · E2" (o "Especial 3" para la temporada 0).
  String get episodeLabel => season == 0 ? 'Especial $episode' : 'T$season · E$episode';

  factory VideoItem.fromJson(Map<String, dynamic> j) => VideoItem(
        j['id'] as String,
        j['title'] as String,
        j['size'] as int,
        durationMs: j['durationMs'] as int?,
        width: j['width'] as int?,
        height: j['height'] as int?,
        vcodec: j['vcodec'] as String?,
        acodec: j['acodec'] as String?,
        positionMs: (j['positionMs'] as int?) ?? 0,
        year: j['year'] as int?,
        rating: (j['rating'] as num?)?.toDouble(),
        overview: j['overview'] as String?,
        genres: _strings(j['genres']),
        posterV: (j['posterV'] as int?) ?? 0,
        backdropV: (j['backdropV'] as int?) ?? 0,
        addedMs: (j['addedMs'] as int?) ?? 0,
        matched: (j['matched'] as bool?) ?? false,
        showId: j['showId'] as String?,
        show: j['show'] as String?,
        season: j['season'] as int?,
        episode: j['episode'] as int?,
        epTitle: j['epTitle'] as String?,
        stillV: (j['stillV'] as int?) ?? 0,
        isShow: (j['isShow'] as bool?) ?? false,
        watchedMs: (j['watchedMs'] as int?) ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'size': size,
        'durationMs': durationMs,
        'width': width,
        'height': height,
        'vcodec': vcodec,
        'acodec': acodec,
        'positionMs': positionMs,
        'year': year,
        'rating': rating,
        'overview': overview,
        'genres': genres,
        'posterV': posterV,
        'backdropV': backdropV,
        'addedMs': addedMs,
        'matched': matched,
        'showId': showId,
        'show': show,
        'season': season,
        'episode': episode,
        'epTitle': epTitle,
        'stillV': stillV,
        'isShow': isShow,
        'watchedMs': watchedMs,
      };

  String get sizeLabel => size >= 1073741824
      ? '${(size / 1073741824).toStringAsFixed(1)} GB'
      : '${(size / 1048576).toStringAsFixed(0)} MB';

  String get durationLabel {
    final s = (durationMs ?? 0) ~/ 1000;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }

  /// Ej.: "1h 32m · 1080p · hevc · 2.1 GB"
  String get infoLabel => [
        if (durationMs != null) durationLabel,
        if (height != null) '${height}p',
        if (vcodec != null) vcodec!,
        sizeLabel,
      ].join(' · ');

  /// Fracción vista (0-1), o null si no hay progreso.
  double? get progress => (durationMs != null && durationMs! > 0 && positionMs > 0)
      ? (positionMs / durationMs!).clamp(0.0, 1.0).toDouble()
      : null;
}

/// Quita el prefijo del nombre de una categoría de los Óscar:
/// "Premio Óscar al mejor director" → "Mejor director"; "Academy Award for Best Director" → "Best Director".
String cleanOscarCategory(String raw) {
  var s = raw.trim().replaceFirst(
      RegExp(
          r'^(premio\s+(?:óscar|oscar|de la academia)|academy award)\s+(?:a la|a los|a las|al|a|para el|para la|for)\s+(?:the\s+)?',
          caseSensitive: false),
      '');
  if (s.isEmpty) s = raw.trim();
  return s[0].toUpperCase() + s.substring(1);
}

/// ¿Es la categoría de mejor película? (en español o inglés, sin "internacional" ni otras).
bool isBestPictureLabel(String c) {
  final s = c.trim().toLowerCase();
  return s == 'mejor película' ||
      s == 'best picture' ||
      s == 'outstanding picture' ||
      s == 'outstanding production' ||
      s == 'outstanding motion picture' ||
      s == 'best motion picture';
}

/// Óscares ganados por una película o serie (datos de Wikidata, guardados en el perfil).
class OscarInfo {
  const OscarInfo({this.categories = const [], this.bestPicture = false});

  /// Categorías ganadas, ya sin el prefijo ("Mejor director").
  final List<String> categories;
  final bool bestPicture;

  int get wins => categories.length;
  bool get any => categories.isNotEmpty;

  factory OscarInfo.fromJson(Object? j) {
    if (j is! Map) return const OscarInfo();
    final cats = _strings(j['categories']);
    return OscarInfo(
        categories: cats,
        bestPicture: (j['bestPicture'] as bool?) ?? cats.any(isBestPictureLabel));
  }

  Map<String, dynamic> toJson() =>
      {'categories': categories, 'bestPicture': bestPicture};
}

/// Perfil completo de una película o serie (lo que se edita en el cliente).
class Profile {
  const Profile({
    this.title,
    this.originalTitle,
    this.year,
    this.overview,
    this.tagline,
    this.rating,
    this.runtime,
    this.genres = const [],
    this.cast = const [],
    this.directors = const [],
    this.tmdbId,
    this.imdbId,
    this.mediaType,
    this.trailerKey,
    this.posterV = 0,
    this.backdropV = 0,
    this.oscars = const OscarInfo(),
    this.certification,
    this.certCountry,
  });
  final String? title, originalTitle, overview, tagline, imdbId, mediaType, trailerKey;

  /// Clasificación de edades ("B15", "PG-13", "TV-MA"...) y país de donde viene.
  final String? certification, certCountry;
  final int? year, runtime, tmdbId;
  final double? rating;
  final List<String> genres, cast, directors;
  final int posterV, backdropV;

  /// Óscares ganados (vacío si no ganó ninguno o aún no se ha consultado).
  final OscarInfo oscars;

  bool get matched => tmdbId != null;

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        title: j['title'] as String?,
        originalTitle: j['originalTitle'] as String?,
        year: j['year'] as int?,
        overview: j['overview'] as String?,
        tagline: j['tagline'] as String?,
        rating: (j['rating'] as num?)?.toDouble(),
        runtime: j['runtime'] as int?,
        genres: _strings(j['genres']),
        cast: _strings(j['cast']),
        directors: _strings(j['directors']),
        tmdbId: j['tmdbId'] as int?,
        imdbId: j['imdbId'] as String?,
        mediaType: j['mediaType'] as String?,
        trailerKey: j['trailerKey'] as String?,
        posterV: (j['posterV'] as int?) ?? 0,
        backdropV: (j['backdropV'] as int?) ?? 0,
        oscars: OscarInfo.fromJson(j['oscars']),
        certification: j['certification'] as String?,
        certCountry: j['certCountry'] as String?,
      );
}

/// Resultado de una búsqueda en TMDB.
class TmdbCandidate {
  const TmdbCandidate(this.id, this.type, this.title,
      {this.year, this.overview, this.rating, this.posterUrl});
  final int id;
  final String type, title; // type: 'movie' | 'tv'
  final int? year;
  final String? overview, posterUrl;
  final double? rating;
  factory TmdbCandidate.fromJson(Map<String, dynamic> j) => TmdbCandidate(
        j['id'] as int,
        j['type'] as String,
        (j['title'] as String?) ?? '',
        year: j['year'] as int?,
        overview: j['overview'] as String?,
        rating: (j['rating'] as num?)?.toDouble(),
        posterUrl: j['posterUrl'] as String?,
      );
}

/// Pista de audio o subtítulos. En subtítulos, [external] indica un archivo junto
/// al video y [text] si se puede extraer como texto (false en PGS/VobSub).
class TrackInfo {
  const TrackInfo(this.id, this.label, {this.external = false, this.text = true});
  final String id, label;
  final bool external, text;
  factory TrackInfo.fromJson(Map<String, dynamic> j) => TrackInfo(
      j['id'] as String, j['label'] as String,
      external: (j['external'] as bool?) ?? false, text: (j['text'] as bool?) ?? true);
  Map<String, dynamic> toJson() =>
      {'id': id, 'label': label, 'external': external, 'text': text};
}

class VideoDetail {
  const VideoDetail(this.item, this.audio, this.subtitles,
      [this.profile = const Profile()]);
  final VideoItem item;
  final List<TrackInfo> audio, subtitles;
  final Profile profile;
  factory VideoDetail.fromJson(Map<String, dynamic> j) => VideoDetail(
        VideoItem.fromJson(j['item'] as Map<String, dynamic>),
        [for (final t in j['audio'] as List) TrackInfo.fromJson(t as Map<String, dynamic>)],
        [for (final t in j['subtitles'] as List) TrackInfo.fromJson(t as Map<String, dynamic>)],
        j['profile'] is Map
            ? Profile.fromJson((j['profile'] as Map).cast<String, dynamic>())
            : const Profile(),
      );
}

/// Una serie completa (agrupa todos sus capítulos).
class ShowItem {
  const ShowItem(this.id, this.name,
      {this.episodes = 0,
      this.seasons = 0,
      this.year,
      this.rating,
      this.overview,
      this.genres = const [],
      this.posterV = 0,
      this.backdropV = 0,
      this.addedMs = 0,
      this.matched = false,
      this.nextId,
      this.inProgress = false,
      this.watchedMs = 0,
      this.nextPositionMs = 0,
      this.nextDurationMs,
      this.nextSeason,
      this.nextEpisode});
  final String id, name;
  final int episodes, seasons, posterV, backdropV, addedMs;
  final int? year;
  final double? rating;
  final String? overview;
  final List<String> genres;
  final bool matched;

  /// Capítulo que toca ver ahora (el que dejaste a medias o el siguiente).
  final String? nextId;

  /// Ya empezaste la serie y no la has terminado (sale en "Continuar viendo").
  final bool inProgress;

  /// Última vez que viste algo de la serie (ms desde epoch; 0 = sin dato).
  final int watchedMs;

  /// Capítulo que toca ver: posición guardada (0 si no está empezado), duración,
  /// temporada y número.
  final int nextPositionMs;
  final int? nextDurationMs, nextSeason, nextEpisode;

  factory ShowItem.fromJson(Map<String, dynamic> j) => ShowItem(
        j['id'] as String,
        j['name'] as String,
        episodes: (j['episodes'] as int?) ?? 0,
        seasons: (j['seasons'] as int?) ?? 0,
        year: j['year'] as int?,
        rating: (j['rating'] as num?)?.toDouble(),
        overview: j['overview'] as String?,
        genres: _strings(j['genres']),
        posterV: (j['posterV'] as int?) ?? 0,
        backdropV: (j['backdropV'] as int?) ?? 0,
        addedMs: (j['addedMs'] as int?) ?? 0,
        matched: (j['matched'] as bool?) ?? false,
        nextId: j['nextId'] as String?,
        inProgress: (j['inProgress'] as bool?) ?? false,
        watchedMs: (j['watchedMs'] as int?) ?? 0,
        nextPositionMs: (j['nextPositionMs'] as int?) ?? 0,
        nextDurationMs: j['nextDurationMs'] as int?,
        nextSeason: j['nextSeason'] as int?,
        nextEpisode: j['nextEpisode'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'episodes': episodes,
        'seasons': seasons,
        'year': year,
        'rating': rating,
        'overview': overview,
        'genres': genres,
        'posterV': posterV,
        'backdropV': backdropV,
        'addedMs': addedMs,
        'matched': matched,
        'nextId': nextId,
        'inProgress': inProgress,
        'watchedMs': watchedMs,
        'nextPositionMs': nextPositionMs,
        'nextDurationMs': nextDurationMs,
        'nextSeason': nextSeason,
        'nextEpisode': nextEpisode,
      };

  /// La serie como "carátula" para las filas y rejillas de la biblioteca.
  VideoItem toCard() => VideoItem(id, name, 0,
      year: year,
      rating: rating,
      overview: overview,
      genres: genres,
      posterV: posterV,
      backdropV: backdropV,
      addedMs: addedMs,
      watchedMs: watchedMs,
      matched: matched,
      show: name,
      isShow: true);

  /// La serie para "Continuar viendo": igual que [toCard] pero con el capítulo que toca
  /// (temporada/episodio) y su progreso, para la etiqueta "T1 · E3" y la barra.
  VideoItem toContinueCard() => VideoItem(id, name, 0,
      durationMs: nextDurationMs,
      positionMs: nextPositionMs,
      year: year,
      rating: rating,
      overview: overview,
      genres: genres,
      posterV: posterV,
      backdropV: backdropV,
      addedMs: addedMs,
      watchedMs: watchedMs,
      matched: matched,
      show: name,
      season: nextSeason,
      episode: nextEpisode,
      isShow: true);
}

/// Ficha de una serie con todos sus capítulos ordenados (temporada, capítulo).
class ShowDetail {
  const ShowDetail(this.show, this.episodes, [this.profile = const Profile()]);
  final ShowItem show;
  final List<VideoItem> episodes;
  final Profile profile;
  factory ShowDetail.fromJson(Map<String, dynamic> j) => ShowDetail(
        ShowItem.fromJson(j['show'] as Map<String, dynamic>),
        [
          for (final e in j['episodes'] as List)
            VideoItem.fromJson((e as Map).cast<String, dynamic>())
        ],
        j['profile'] is Map
            ? Profile.fromJson((j['profile'] as Map).cast<String, dynamic>())
            : const Profile(),
      );
}

// ===========================================================================
//  Novedades: capítulos nuevos de series que ya estaban en la biblioteca.
// ===========================================================================

/// Un capítulo nuevo dentro de una novedad.
class NewsEpisode {
  const NewsEpisode(this.id, this.season, this.episode, this.addedMs,
      {this.title, this.stillV = 0, this.durationMs, this.watched = false});
  final String id;
  final int season, episode, addedMs, stillV;

  /// Nombre del capítulo (TMDB, el del archivo o "Episodio N").
  final String? title;
  final int? durationMs;

  /// Este perfil ya lo vio (95 % o más).
  final bool watched;

  /// Ej.: "T1 · E2" (o "Especial 3" para la temporada 0).
  String get label => season == 0 ? 'Especial $episode' : 'T$season · E$episode';

  factory NewsEpisode.fromJson(Map<String, dynamic> j) => NewsEpisode(
        j['id'] as String,
        (j['season'] as int?) ?? 1,
        (j['episode'] as int?) ?? 0,
        (j['addedMs'] as int?) ?? 0,
        title: j['title'] as String?,
        stillV: (j['stillV'] as int?) ?? 0,
        durationMs: j['durationMs'] as int?,
        watched: (j['watched'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'season': season,
        'episode': episode,
        'addedMs': addedMs,
        'title': title,
        'stillV': stillV,
        'durationMs': durationMs,
        'watched': watched,
      };
}

/// Una serie con capítulos nuevos (una sola entrada por serie, como en Netflix).
class NewsItem {
  const NewsItem(this.showId, this.show, this.episodes,
      {this.posterV = 0,
      this.backdropV = 0,
      this.latestMs = 0,
      this.unread = false});
  final String showId, show;

  /// Capítulos nuevos, ordenados por temporada y número.
  final List<NewsEpisode> episodes;
  final int posterV, backdropV;

  /// Cuándo llegó el capítulo más reciente (ms).
  final int latestMs;

  /// El perfil aún no ha abierto esta novedad.
  final bool unread;

  /// Capítulos nuevos que este perfil todavía no ha visto.
  List<NewsEpisode> get pending => [
        for (final e in episodes)
          if (!e.watched) e
      ];

  /// Primer capítulo nuevo sin ver (el que se reproduce desde la novedad).
  NewsEpisode? get firstPending => pending.isEmpty ? null : pending.first;

  /// La serie como "carátula" (para pedir su imagen con la misma URL que en la biblioteca).
  VideoItem toCard() => VideoItem(showId, show, 0,
      posterV: posterV, backdropV: backdropV, show: show, isShow: true);

  factory NewsItem.fromJson(Map<String, dynamic> j) => NewsItem(
        j['showId'] as String,
        (j['show'] as String?) ?? '',
        [
          for (final e in (j['episodes'] as List? ?? const []))
            NewsEpisode.fromJson((e as Map).cast<String, dynamic>())
        ],
        posterV: (j['posterV'] as int?) ?? 0,
        backdropV: (j['backdropV'] as int?) ?? 0,
        latestMs: (j['latestMs'] as int?) ?? 0,
        unread: (j['unread'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'showId': showId,
        'show': show,
        'episodes': [for (final e in episodes) e.toJson()],
        'posterV': posterV,
        'backdropV': backdropV,
        'latestMs': latestMs,
        'unread': unread,
      };
}

/// Respuesta de `GET /api/news`: novedades del perfil activo (las más recientes primero).
class NewsData {
  const NewsData({this.items = const [], this.unread = 0});
  final List<NewsItem> items;

  /// Cuántas novedades están sin abrir (lo que muestra la campanita).
  final int unread;

  /// Ids de los capítulos nuevos de una serie (para marcarlos como NUEVO en su ficha).
  Set<String> newEpisodeIds(String showId) => {
        for (final i in items)
          if (i.showId == showId)
            for (final e in i.episodes)
              if (!e.watched) e.id
      };

  factory NewsData.fromJson(Map<String, dynamic> j) => NewsData(
        items: [
          for (final e in (j['items'] as List? ?? const []))
            NewsItem.fromJson((e as Map).cast<String, dynamic>())
        ],
        unread: (j['unread'] as int?) ?? 0,
      );
}

// ===========================================================================
//  Peticiones: explorar películas y series de TMDB (discover) y pedir las que faltan.
// ===========================================================================

/// Película o serie de TMDB tal como se muestra en "Peticiones".
class TmdbMovie {
  const TmdbMovie(this.id, this.title,
      {this.type = 'movie',
      this.year,
      this.overview,
      this.rating,
      this.posterUrl,
      this.requested = false,
      this.inLibrary = false,
      this.requestedBy = const [],
      this.byNames = const [],
      this.createdMs});
  final int id;
  final String title;

  /// 'movie' o 'tv'. Un id de película y uno de serie pueden coincidir: la identidad es (type, id).
  final String type;
  final int? year, createdMs;
  final String? overview, posterUrl;
  final double? rating;

  bool get isTv => type == 'tv';

  /// Alguien (este u otro dispositivo) la tiene pedida.
  final bool requested;

  /// Ya está en la biblioteca del servidor.
  final bool inLibrary;

  /// Nombres de los dispositivos que la pidieron (los originales: con ellos cada
  /// dispositivo reconoce sus peticiones).
  final List<String> requestedBy;

  /// Los mismos dispositivos con el nombre que les puso el dueño del servidor.
  final List<String> byNames;

  /// Lo que se muestra al usuario: los nombres puestos en el servidor si el servidor los envía.
  List<String> get displayBy =>
      byNames.length == requestedBy.length ? byNames : requestedBy;

  factory TmdbMovie.fromJson(Map<String, dynamic> j) => TmdbMovie(
        j['id'] as int,
        (j['title'] as String?) ?? '',
        type: j['type'] == 'tv' ? 'tv' : 'movie',
        year: j['year'] as int?,
        overview: j['overview'] as String?,
        rating: (j['rating'] as num?)?.toDouble(),
        posterUrl: j['posterUrl'] as String?,
        requested: (j['requested'] as bool?) ?? false,
        inLibrary: (j['inLibrary'] as bool?) ?? false,
        requestedBy: _strings(j['by']),
        byNames: _strings(j['byNames']),
        createdMs: j['createdMs'] as int?,
      );

  TmdbMovie withInLibrary(bool v) => TmdbMovie(id, title,
      type: type,
      year: year,
      overview: overview,
      rating: rating,
      posterUrl: posterUrl,
      requested: requested,
      inLibrary: v,
      requestedBy: requestedBy,
      byNames: byNames,
      createdMs: createdMs);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'type': type,
        if (year != null) 'year': year,
        if (overview != null) 'overview': overview,
        if (rating != null) 'rating': rating,
        if (posterUrl != null) 'posterUrl': posterUrl,
        'requested': requested,
        'inLibrary': inLibrary,
        'by': requestedBy,
        'byNames': byNames,
        if (createdMs != null) 'createdMs': createdMs,
      };

  TmdbMovie withRequest(bool requested, List<String> by, [int? createdMs]) =>
      TmdbMovie(id, title,
          type: type,
          year: year,
          overview: overview,
          rating: rating,
          posterUrl: posterUrl,
          requested: requested,
          inLibrary: inLibrary,
          requestedBy: by,
          createdMs: createdMs ?? this.createdMs);
}

/// Una página de resultados de `discover` o de búsqueda (20 títulos por página).
class DiscoverPage {
  const DiscoverPage(this.items, this.page, this.totalPages, this.totalResults);
  final List<TmdbMovie> items;
  final int page, totalPages, totalResults;
  factory DiscoverPage.fromJson(Map<String, dynamic> j) => DiscoverPage(
        [
          for (final e in (j['items'] as List? ?? const []))
            TmdbMovie.fromJson((e as Map).cast<String, dynamic>())
        ],
        (j['page'] as int?) ?? 1,
        (j['totalPages'] as int?) ?? 0,
        (j['totalResults'] as int?) ?? 0,
      );
}

class TmdbGenre {
  const TmdbGenre(this.id, this.name);
  final int id;
  final String name;
  factory TmdbGenre.fromJson(Map<String, dynamic> j) =>
      TmdbGenre(j['id'] as int, (j['name'] as String?) ?? '');
}

// ===========================================================================
//  Explorar: listas, filtros y consulta a TMDB. Servidor y cliente (que consulta TMDB
//  directamente si el servidor está apagado) usan el mismo código, así devuelven lo mismo.
// ===========================================================================

/// Listas de la pestaña Explorar.
///  - `popular`: más populares · `trending`: tendencia de la semana
///  - `top`: mejor valoradas (con un mínimo de votos; admite año y demás filtros)
///  - `most_voted`: las que más votos tienen en TMDB (las más vistas)
///  - `recent`: las últimas estrenadas · `now`: en cines / series en emisión esta semana
///  - `upcoming`: próximos estrenos · `year`: estrenos de un año · `genre`: por género
///  - `search`: búsqueda por título (admite año)
const exploreLists = [
  'popular',
  'trending',
  'top',
  'most_voted',
  'recent',
  'now',
  'upcoming',
  'year',
  'genre',
  'search',
];

/// Órdenes que se pueden pedir con los filtros.
const exploreSorts = ['popularity', 'rating', 'votes', 'date', 'date_asc'];

/// Las listas que salen de un endpoint fijo de TMDB (tendencia, en cines...) o de una
/// búsqueda por título no admiten los filtros de [ExploreFilters].
bool listAcceptsFilters(String list, String type) => !(list == 'trending' ||
    list == 'now' ||
    list == 'search' ||
    (list == 'upcoming' && type == 'movie'));

/// Filtros de Explorar. Todos son opcionales y se combinan entre sí.
class ExploreFilters {
  const ExploreFilters(
      {this.genre,
      this.year,
      this.yearFrom,
      this.yearTo,
      this.minRating,
      this.sort,
      this.language,
      this.status});

  /// Id de género de TMDB.
  final int? genre;

  /// Un año exacto, o un rango [yearFrom]–[yearTo] (una década, por ejemplo).
  final int? year, yearFrom, yearTo;

  /// Valoración mínima (0–10).
  final double? minRating;

  /// Uno de [exploreSorts].
  final String? sort;

  /// Idioma original (código de 2 letras: es, en, ja, ko...).
  final String? language;

  /// Solo series: `airing` (en emisión), `ended` (finalizada) o `canceled`.
  final String? status;

  bool get isEmpty =>
      genre == null &&
      year == null &&
      yearFrom == null &&
      yearTo == null &&
      minRating == null &&
      sort == null &&
      language == null &&
      status == null;

  /// Cuántos filtros hay activos (el género y el año/rango cuentan una vez cada uno).
  int get count =>
      (genre != null ? 1 : 0) +
      (year != null || yearFrom != null || yearTo != null ? 1 : 0) +
      (minRating != null ? 1 : 0) +
      (sort != null ? 1 : 0) +
      (language != null ? 1 : 0) +
      (status != null ? 1 : 0);

  /// Los mismos filtros sin los indicados.
  ExploreFilters without(
          {bool genre = false,
          bool years = false,
          bool rating = false,
          bool sort = false,
          bool language = false,
          bool status = false}) =>
      ExploreFilters(
        genre: genre ? null : this.genre,
        year: years ? null : year,
        yearFrom: years ? null : yearFrom,
        yearTo: years ? null : yearTo,
        minRating: rating ? null : minRating,
        sort: sort ? null : this.sort,
        language: language ? null : this.language,
        status: status ? null : this.status,
      );

  /// Los mismos filtros con otro año o rango de años (sin argumentos: cualquier año).
  ExploreFilters withYears({int? year, int? from, int? to}) => ExploreFilters(
        genre: genre,
        year: year,
        yearFrom: from,
        yearTo: to,
        minRating: minRating,
        sort: sort,
        language: language,
        status: status,
      );

  Map<String, String> toQuery() => {
        if (genre != null) 'genre': '$genre',
        if (year != null) 'year': '$year',
        if (yearFrom != null) 'yearFrom': '$yearFrom',
        if (yearTo != null) 'yearTo': '$yearTo',
        if (minRating != null) 'minRating': '$minRating',
        if (sort != null) 'sort': sort!,
        if (language != null) 'lang': language!,
        if (status != null) 'status': status!,
      };

  factory ExploreFilters.fromQuery(Map<String, String> q) {
    String? t(String k) {
      final v = (q[k] ?? '').trim();
      return v.isEmpty ? null : v;
    }

    return ExploreFilters(
      genre: int.tryParse(q['genre'] ?? ''),
      year: int.tryParse(q['year'] ?? ''),
      yearFrom: int.tryParse(q['yearFrom'] ?? ''),
      yearTo: int.tryParse(q['yearTo'] ?? ''),
      minRating: double.tryParse(q['minRating'] ?? ''),
      sort: t('sort'),
      language: t('lang'),
      status: t('status'),
    );
  }
}

/// Ruta y parámetros de una consulta a TMDB (sin `language` ni clave: los pone quien la envía).
class TmdbQuery {
  const TmdbQuery(this.path, this.params);
  final String path;
  final Map<String, String> params;
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Traduce una lista de Explorar + filtros a la consulta de TMDB. null si no hay nada que
/// buscar (búsqueda vacía). Lanza [ArgumentError] si la lista, el tipo o el orden no valen.
TmdbQuery? buildDiscoverQuery({
  required String list,
  required String type,
  int page = 1,
  ExploreFilters filters = const ExploreFilters(),
  String? query,
  DateTime? today,
}) {
  if (type != 'movie' && type != 'tv') {
    throw ArgumentError('Tipo inválido: $type');
  }
  if (!exploreLists.contains(list)) throw ArgumentError('Lista inválida: $list');
  final tv = type == 'tv';
  final now = today ?? DateTime.now();
  final p = <String, String>{'page': '${page.clamp(1, 500)}'};

  // Endpoints fijos de TMDB.
  if (list == 'trending') return TmdbQuery('/trending/$type/week', p);
  if (list == 'now') {
    return TmdbQuery(tv ? '/tv/on_the_air' : '/movie/now_playing', p);
  }
  if (list == 'upcoming' && !tv) return TmdbQuery('/movie/upcoming', p);

  p['include_adult'] = 'false';
  final f = filters;

  if (list == 'search') {
    final t = (query ?? '').trim();
    if (t.isEmpty) return null;
    p['query'] = t;
    if (f.year != null) p[tv ? 'first_air_date_year' : 'year'] = '${f.year}';
    return TmdbQuery('/search/$type', p);
  }

  final genre = f.genre;
  if (list == 'genre' && genre == null) throw ArgumentError('Falta el género.');
  if (genre != null) p['with_genres'] = '$genre';

  // Orden: el de la lista, o el que pidan los filtros.
  var by = switch (list) {
    'top' => 'rating',
    'most_voted' => 'votes',
    'recent' => 'date',
    _ => 'popularity',
  };
  if (f.sort != null) by = f.sort!;
  p['sort_by'] = switch (by) {
    'popularity' => 'popularity.desc',
    'rating' => 'vote_average.desc',
    'votes' => 'vote_count.desc',
    'date' => tv ? 'first_air_date.desc' : 'primary_release_date.desc',
    'date_asc' => tv ? 'first_air_date.asc' : 'primary_release_date.asc',
    _ => throw ArgumentError('Orden inválido: $by'),
  };

  // Año exacto o rango de años.
  final dateKey = tv ? 'first_air_date' : 'primary_release_date';
  final year = f.year ?? (list == 'year' ? now.year : null);
  if (year != null) {
    p[tv ? 'first_air_date_year' : 'primary_release_year'] = '$year';
  } else {
    if (f.yearFrom != null) p['$dateKey.gte'] = '${f.yearFrom}-01-01';
    if (f.yearTo != null) p['$dateKey.lte'] = '${f.yearTo}-12-31';
  }
  if (list == 'recent' || by == 'date') {
    // Lo más reciente ya estrenado (no lo que sale dentro de meses).
    final lte = p['$dateKey.lte'];
    if (lte == null || lte.compareTo(_ymd(now)) > 0) {
      p['$dateKey.lte'] = _ymd(now);
    }
  }
  if (list == 'upcoming') {
    // Series que aún no han empezado.
    p.remove('first_air_date_year');
    p['first_air_date.gte'] = _ymd(now.add(const Duration(days: 1)));
    p.remove('first_air_date.lte');
  }

  // Mínimo de votos: sin él ganan los títulos con un solo voto de 10.
  final dated = year != null || f.yearFrom != null || f.yearTo != null;
  var votes = 0;
  void atLeast(int n) {
    if (votes < n) votes = n;
  }

  if (by == 'rating') atLeast(tv ? (dated ? 50 : 150) : (dated ? 100 : 300));
  if (by == 'date') atLeast(tv ? 5 : 10);
  if (f.minRating != null) {
    p['vote_average.gte'] = f.minRating!.toStringAsFixed(1);
    atLeast(tv ? 20 : 50);
  }
  if (votes > 0) p['vote_count.gte'] = '$votes';

  final lang = (f.language ?? '').trim().toLowerCase();
  if (RegExp(r'^[a-z]{2,3}$').hasMatch(lang)) p['with_original_language'] = lang;

  if (tv) {
    final st = switch (f.status) {
      'airing' => '0',
      'ended' => '3',
      'canceled' => '4',
      _ => null,
    };
    if (st != null) p['with_status'] = st;
  }
  return TmdbQuery('/discover/$type', p);
}

/// Ficha ampliada de TMDB: estado de la serie (en emisión / finalizada), temporadas...
class TmdbInfo {
  const TmdbInfo(
      {this.status,
      this.seasons,
      this.episodes,
      this.runtime,
      this.nextAir,
      this.lastAir,
      this.released,
      this.tagline,
      this.genres = const []});

  /// Estado tal como lo da TMDB ("Returning Series", "Ended", "Released"...).
  final String? status, nextAir, lastAir, released, tagline;
  final int? seasons, episodes, runtime;
  final List<String> genres;

  factory TmdbInfo.fromJson(Map<String, dynamic> j) => TmdbInfo(
        status: j['status'] as String?,
        seasons: j['seasons'] as int?,
        episodes: j['episodes'] as int?,
        runtime: j['runtime'] as int?,
        nextAir: j['nextAir'] as String?,
        lastAir: j['lastAir'] as String?,
        released: j['released'] as String?,
        tagline: j['tagline'] as String?,
        genres: _strings(j['genres']),
      );

  Map<String, dynamic> toJson() => {
        if (status != null) 'status': status,
        if (seasons != null) 'seasons': seasons,
        if (episodes != null) 'episodes': episodes,
        if (runtime != null) 'runtime': runtime,
        if (nextAir != null) 'nextAir': nextAir,
        if (lastAir != null) 'lastAir': lastAir,
        if (released != null) 'released': released,
        if (tagline != null) 'tagline': tagline,
        'genres': genres,
      };
}

/// Datos de `/movie/{id}` o `/tv/{id}` de TMDB en un [TmdbInfo].
TmdbInfo parseTmdbInfo(Map<String, dynamic> j, String type) {
  String? s(dynamic v) {
    final t = (v ?? '').toString().trim();
    return t.isEmpty ? null : t;
  }

  int? pos(dynamic v) {
    final n = v is num ? v.toInt() : null;
    return n != null && n > 0 ? n : null;
  }

  final tv = type == 'tv';
  final next = j['next_episode_to_air'];
  final runs = j['episode_run_time'];
  return TmdbInfo(
    status: s(j['status']),
    seasons: tv ? pos(j['number_of_seasons']) : null,
    episodes: tv ? pos(j['number_of_episodes']) : null,
    runtime: tv
        ? (runs is List && runs.isNotEmpty ? pos(runs.first) : null)
        : pos(j['runtime']),
    nextAir: next is Map ? s(next['air_date']) : null,
    lastAir: tv ? s(j['last_air_date']) : null,
    released: tv ? null : s(j['release_date']),
    tagline: s(j['tagline']),
    genres: [
      for (final g in (j['genres'] as List? ?? const []))
        if (g is Map && s(g['name']) != null) s(g['name'])!
    ],
  );
}

/// Estado en español: "En emisión", "Finalizada", "Cancelada"... null si no se conoce.
String? tmdbStatusLabel(String? status, String type) {
  if (type == 'tv') {
    return switch (status) {
      'Returning Series' => 'En emisión',
      'Ended' => 'Finalizada',
      'Canceled' || 'Cancelled' => 'Cancelada',
      'In Production' => 'En producción',
      'Planned' => 'Planeada',
      'Pilot' => 'Piloto',
      _ => null,
    };
  }
  return switch (status) {
    'Released' => 'Estrenada',
    'Post Production' => 'Posproducción',
    'In Production' => 'En producción',
    'Planned' => 'Planeada',
    'Rumored' => 'Rumoreada',
    'Canceled' || 'Cancelled' => 'Cancelada',
    _ => null,
  };
}

// ===========================================================================
//  Perfiles de usuario (¿quién está viendo?)
//  Ojo: no confundir con [Profile], que es la ficha de TMDB de una película.
// ===========================================================================

/// Máximo de perfiles por servidor.
const maxProfiles = 8;
const usernameMinLength = 2;
const usernameMaxLength = 20;

/// El PIN del perfil son siempre 4 dígitos (cómodo con el mando de una TV).
const pinLength = 4;

/// Imagen de los avatares que se dejan en la carpeta `avatars/` del servidor:
/// JPG cuadrado de [avatarPixels] x [avatarPixels] px (el servidor rechaza más de
/// [avatarMaxBytes]). La app los recorta en círculo, así que no hace falta redondearlos.
const avatarPixels = 512;
const avatarMaxBytes = 2 * 1024 * 1024;

final _usernameRe = RegExp(r'^[\p{L}\p{N}][\p{L}\p{N}_.\-]*$', unicode: true);
final _avatarIdRe = RegExp(r'^[A-Za-z0-9_\-]{1,64}$');
final _pinRe = RegExp(r'^\d{4}$');

/// Forma normalizada del nombre de usuario: es la clave única (no distingue mayúsculas).
String normalizeUsername(String s) => s.trim().toLowerCase();

/// null si el nombre de usuario es válido; si no, el motivo para mostrarlo.
String? validateUsername(String raw) {
  final s = raw.trim();
  if (s.length < usernameMinLength) {
    return 'El nombre de usuario necesita al menos $usernameMinLength caracteres.';
  }
  if (s.length > usernameMaxLength) {
    return 'El nombre de usuario admite como máximo $usernameMaxLength caracteres.';
  }
  if (!_usernameRe.hasMatch(s)) {
    return 'Usa solo letras, números, punto, guion y guion bajo (sin espacios).';
  }
  return null;
}

bool isValidPin(String s) => _pinRe.hasMatch(s);

/// Nombre de archivo (sin extensión) válido para un avatar.
bool isValidAvatarId(String s) => _avatarIdRe.hasMatch(s);

/// Separador entre el paquete y el avatar en el id de un avatar de paquete
/// (`MiPaquete|zoro`). Windows no permite `|` en nombres de archivo, así que un
/// archivo suelto nunca puede confundirse con uno de paquete.
const avatarPackSep = '|';

final _avatarPackRe = RegExp(r'^[^\x00-\x1f|/\\:*?"<>%]{1,64}$');

/// Nombre de carpeta válido para un paquete de avatares (es el nombre que ve el cliente).
bool isValidAvatarPack(String s) =>
    _avatarPackRe.hasMatch(s) && s.trim() == s && !s.startsWith('.');

/// ¿Es un id de avatar válido? Acepta el de un avatar suelto (`zoro`) o el de uno de
/// paquete (`MiPaquete|zoro`).
bool isValidAvatarRef(String s) {
  if (isValidAvatarId(s)) return true;
  final i = s.indexOf(avatarPackSep);
  return i > 0 &&
      isValidAvatarPack(s.substring(0, i)) &&
      isValidAvatarId(s.substring(i + 1));
}

/// Un avatar disponible en la carpeta del servidor. [id] es el nombre del archivo sin `.jpg`;
/// [v] cambia cuando se sustituye la imagen (sirve para refrescar la caché).
class AvatarInfo {
  const AvatarInfo(this.id, this.v, {this.pack});
  final String id;
  final int v;

  /// Paquete (nombre de la subcarpeta) al que pertenece; null = avatar suelto en la
  /// carpeta principal.
  final String? pack;
  factory AvatarInfo.fromJson(Map<String, dynamic> j) => AvatarInfo(
      '${j['id']}', (j['v'] as num?)?.toInt() ?? 0,
      pack: j['pack'] as String?);
  Map<String, dynamic> toJson() => {'id': id, 'v': v, if (pack != null) 'pack': pack};
}

/// Perfil de usuario tal como lo ven los clientes. El PIN nunca sale del servidor.
class UserProfile {
  const UserProfile(this.username,
      {this.avatar,
      this.avatarV = 0,
      this.hasPin = false,
      this.createdMs = 0,
      this.lastSeenMs = 0});

  /// Nombre de usuario tal como se escribió; en minúsculas es el identificador único.
  final String username;

  /// Id del avatar (nombre del .jpg), o null si no tiene.
  final String? avatar;
  final int avatarV;
  final bool hasPin;
  final int createdMs, lastSeenMs;

  String get key => normalizeUsername(username);

  /// Inicial para mostrar cuando no hay avatar.
  String get initial =>
      username.isEmpty ? '?' : username.substring(0, 1).toUpperCase();

  factory UserProfile.fromJson(Map<String, dynamic> j) => UserProfile(
        '${j['username']}',
        avatar: j['avatar'] as String?,
        avatarV: (j['avatarV'] as num?)?.toInt() ?? 0,
        hasPin: (j['hasPin'] as bool?) ?? false,
        createdMs: (j['createdMs'] as num?)?.toInt() ?? 0,
        lastSeenMs: (j['lastSeenMs'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'username': username,
        'avatar': avatar,
        'avatarV': avatarV,
        'hasPin': hasPin,
        'createdMs': createdMs,
        'lastSeenMs': lastSeenMs,
      };
}

/// Respuesta de `GET /api/profiles`.
class ProfilesData {
  const ProfilesData(this.items,
      {this.current,
      this.max = maxProfiles,
      this.avatarCount = 0,
      this.hasDeviceProgress = false});
  final List<UserProfile> items;

  /// Nombre de usuario con el que está actuando este dispositivo (null = aún ninguno).
  final String? current;
  final int max, avatarCount;

  /// Este dispositivo tiene progreso de antes de que existieran los perfiles y aún se puede
  /// traer al primer perfil que se cree.
  final bool hasDeviceProgress;

  UserProfile? get currentProfile {
    final c = current;
    if (c == null) return null;
    final k = normalizeUsername(c);
    for (final p in items) {
      if (p.key == k) return p;
    }
    return null;
  }

  factory ProfilesData.fromJson(Map<String, dynamic> j) => ProfilesData(
        [
          for (final e in (j['items'] as List? ?? const []))
            UserProfile.fromJson((e as Map).cast<String, dynamic>())
        ],
        current: j['current'] as String?,
        max: (j['max'] as num?)?.toInt() ?? maxProfiles,
        avatarCount: (j['avatarCount'] as num?)?.toInt() ?? 0,
        hasDeviceProgress: (j['hasDeviceProgress'] as bool?) ?? false,
      );
}

/// Actualización del cliente Android que hay en el servidor (carpeta `updates/`).
class AppUpdateInfo {
  const AppUpdateInfo(
      {required this.available,
      this.packageName = '',
      this.versionCode = 0,
      this.versionName = '',
      this.size = 0,
      this.sha256 = ''});
  final bool available;
  final String packageName, versionName, sha256;
  final int versionCode, size;

  factory AppUpdateInfo.fromJson(Map<String, dynamic> j) => AppUpdateInfo(
      available: (j['available'] as bool?) ?? false,
      packageName: (j['package'] as String?) ?? '',
      versionCode: (j['versionCode'] as num?)?.toInt() ?? 0,
      versionName: (j['versionName'] as String?) ?? '',
      size: (j['size'] as num?)?.toInt() ?? 0,
      sha256: (j['sha256'] as String?) ?? '');
  Map<String, dynamic> toJson() => {
        'available': available,
        if (available) ...{
          'package': packageName,
          'versionCode': versionCode,
          'versionName': versionName,
          'size': size,
          'sha256': sha256,
        }
      };
}