import 'dart:io';

import 'package:path/path.dart' as p;

import 'media.dart';

/// Clave de una petición: las películas siguen con "123"; las series usan "tv123".
String requestKey(int id, String type) => type == 'tv' ? 'tv$id' : '$id';

/// Peticiones de películas. De TMDB solo se guarda el id, un pequeño resumen para poder
/// listarlas (título, año, carátula) y los dispositivos que la pidieron: nunca el catálogo.
///
/// Se guardan en `requests.json`, dentro de la carpeta de datos del servidor.
class RequestStore {
  RequestStore(String dataDir)
      : _store = JsonFile(p.join(dataDir, 'requests.json'));
  final JsonFile _store;

  Map<String, dynamic> get _items =>
      (_store.data['items'] ??= <String, dynamic>{}) as Map<String, dynamic>;

  /// La petición con ese id de TMDB, o null.
  Map<String, dynamic>? get(int tmdbId, [String type = 'movie']) {
    final e = _items[requestKey(tmdbId, type)];
    return e is Map ? e.cast<String, dynamic>() : null;
  }

  /// Todas las peticiones, las más recientes primero.
  List<Map<String, dynamic>> list() {
    final out = [
      for (final e in _items.values)
        if (e is Map) e.cast<String, dynamic>()
    ];
    out.sort((a, b) => ((b['createdMs'] as int?) ?? 0)
        .compareTo((a['createdMs'] as int?) ?? 0));
    return out;
  }

  /// Añade [device] a la petición de [tmdbId] (la crea con [summary] si es nueva).
  /// Pedir dos veces lo mismo desde el mismo dispositivo no duplica nada.
  Map<String, dynamic> add(
      int tmdbId, String device, Map<String, dynamic> summary,
      [String type = 'movie']) {
    final cur = get(tmdbId, type);
    final by = [
      for (final e in (cur?['by'] as List? ?? const [])) '$e',
    ];
    if (!by.contains(device)) by.add(device);
    final item = <String, dynamic>{
      ...(cur ?? summary),
      'id': tmdbId,
      'type': type,
      'by': by,
      'createdMs': cur?['createdMs'] ?? DateTime.now().millisecondsSinceEpoch,
    };
    _items[requestKey(tmdbId, type)] = item;
    _store.save();
    return item;
  }

  /// Borra la petición entera (lo hace el dueño del servidor al darla por atendida).
  void removeAll(int tmdbId, [String type = 'movie']) {
    if (_items.remove(requestKey(tmdbId, type)) != null) _store.save();
  }

  /// Cambia el nombre de un dispositivo en todas las peticiones (cuando el móvil estrena nombre).
  void renameDevice(String from, String to) {
    var changed = false;
    for (final k in _items.keys.toList()) {
      final e = _items[k];
      if (e is! Map) continue;
      final by = [for (final d in (e['by'] as List? ?? const [])) '$d'];
      if (!by.contains(from)) continue;
      final out = <String>[];
      for (final d in by) {
        final n = d == from ? to : d;
        if (!out.contains(n)) out.add(n);
      }
      _items[k] = {...e.cast<String, dynamic>(), 'by': out};
      changed = true;
    }
    if (changed) _store.save();
  }

  /// Quita a [name] de todas las peticiones (al borrar su perfil). Las que se quedan sin
  /// nadie que las pida se borran.
  void removeUser(String name) {
    var changed = false;
    for (final k in _items.keys.toList()) {
      final e = _items[k];
      if (e is! Map) continue;
      final by = [for (final d in (e['by'] as List? ?? const [])) '$d'];
      if (!by.contains(name)) continue;
      by.remove(name);
      changed = true;
      if (by.isEmpty) {
        _items.remove(k);
      } else {
        _items[k] = {...e.cast<String, dynamic>(), 'by': by};
      }
    }
    if (changed) _store.save();
  }

  /// Quita la petición de [device]. Si nadie más la quiere, se borra del todo.
  void remove(int tmdbId, String device, [String type = 'movie']) {
    final cur = get(tmdbId, type);
    if (cur == null) return;
    final by = [
      for (final e in (cur['by'] as List? ?? const [])) '$e',
    ]..remove(device);
    final k = requestKey(tmdbId, type);
    if (by.isEmpty) {
      _items.remove(k);
    } else {
      _items[k] = {...cur, 'by': by};
    }
    _store.save();
  }
}

/// Petición tal como la ve la app del servidor.
class MovieRequestInfo {
  const MovieRequestInfo(this.tmdbId, this.title,
      {this.type = 'movie',
      this.year,
      this.posterUrl,
      this.by = const [],
      this.createdMs = 0,
      this.inLibrary = false});
  final int tmdbId;
  final String title;
  final int? year;
  final String? posterUrl;

  /// 'movie' o 'tv'.
  final String type;

  /// Dispositivos que la pidieron.
  final List<String> by;
  final int createdMs;

  /// Ya hay un archivo suyo en la biblioteca.
  final bool inLibrary;

  /// "Título (año)".
  String get label => year == null ? title : '$title ($year)';
}

/// Un capítulo elegido para añadir a una serie pedida: el archivo, su temporada y su número.
/// (La temporada 0 son los especiales.)
class EpisodeImport {
  const EpisodeImport(this.path, this.season, this.episode);
  final String path;
  final int season, episode;
}

/// Aviso de una petición recién llegada (lo usa la app del servidor para notificar).
class NewRequestEvent {
  const NewRequestEvent(this.tmdbId, this.title,
      {this.year, this.posterUrl, required this.device, this.alsoBy = const []});
  final int tmdbId;
  final String title;
  final int? year;
  final String? posterUrl;

  /// Dispositivo que la acaba de pedir (con el nombre que le puso el dueño).
  final String device;

  /// Otros dispositivos que ya la habían pedido antes.
  final List<String> alsoBy;

  /// "Título (año)".
  String get label => year == null ? title : '$title ($year)';
}
