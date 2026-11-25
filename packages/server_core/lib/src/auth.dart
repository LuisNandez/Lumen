import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:shared/shared.dart' show kAutoPin;
import 'package:shelf/shelf.dart';

/// Un dispositivo emparejado tal como lo ve la app del servidor.
class PairedDevice {
  const PairedDevice(this.token, this.deviceName,
      {this.alias,
      this.connected = false,
      this.version,
      this.versionCode,
      this.lastSeen});
  final String token;

  /// Versión del cliente instalada en el dispositivo (p. ej. "0.2.0"), o null si el
  /// cliente es antiguo y aún no la informa.
  final String? version;

  /// versionCode (número de build) del cliente instalado, o null si se desconoce.
  final int? versionCode;

  /// Última vez que el dispositivo habló con el servidor (null = nunca desde que se
  /// lleva este registro).
  final DateTime? lastSeen;

  /// Nombre con el que se emparejó el dispositivo.
  final String deviceName;

  /// Nombre puesto por el dueño del servidor, si lo hay.
  final String? alias;

  /// Tiene ahora mismo la conexión WebSocket abierta.
  final bool connected;

  /// Lo que se muestra: el alias o, si no, el nombre del dispositivo.
  String get label => alias ?? deviceName;
}

/// Emparejamiento por PIN de 6 dígitos y tokens persistentes (tokens.json).
class Auth {
  Auth([String path = 'tokens.json'])
      : _file = File(path),
        _aliasFile = File(p.join(p.dirname(path), 'device_names.json')),
        _infoFile = File(p.join(p.dirname(path), 'device_info.json')) {
    if (_file.existsSync()) {
      try {
        final m = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
        _tokens.addAll(m.cast<String, String>());
      } catch (_) {}
    }
    if (_aliasFile.existsSync()) {
      try {
        final m =
            jsonDecode(_aliasFile.readAsStringSync()) as Map<String, dynamic>;
        for (final e in m.entries) {
          if (_tokens.containsKey(e.key)) _aliases[e.key] = '${e.value}';
        }
      } catch (_) {}
    }
    if (_infoFile.existsSync()) {
      try {
        final m = jsonDecode(_infoFile.readAsStringSync()) as Map<String, dynamic>;
        for (final e in m.entries) {
          if (_tokens.containsKey(e.key) && e.value is Map) {
            _info[e.key] = (e.value as Map).cast<String, dynamic>();
          }
        }
      } catch (_) {}
    }
    _newPin();
  }

  final File _file;
  final File _aliasFile;
  final File _infoFile;
  // token -> {version, code, seen (ms desde epoch)}. Se guarda en device_info.json.
  final _info = <String, Map<String, dynamic>>{};
  Timer? _saveTimer;
  final _rng = Random.secure();
  final _tokens = <String, String>{}; // token -> nombre del dispositivo
  // token -> nombre puesto por el dueño del servidor. Va aparte de [_tokens] a propósito:
  // el nombre original es la identidad con la que el cliente reconoce sus peticiones.
  final _aliases = <String, String>{};
  late String pin;
  int _fails = 0;

  /// Conexión automática: además del PIN del momento se acepta el PIN fijo de la app ([kAutoPin]),
  /// que la app manda sola. Pensado para una red de confianza (la de casa).
  bool open = false;

  /// Activa o desactiva la conexión sin PIN.
  void setOpen(bool v) {
    if (open == v) return;
    open = v;
    _changes.add(null);
  }

  /// Tope de dispositivos emparejados con el PIN fijo: frena que algo en la red llene tokens.json.
  static const _maxOpenDevices = 300;
  final _changes = StreamController<void>.broadcast();

  /// Emite cuando cambia el PIN o la lista de dispositivos emparejados.
  Stream<void> get changes => _changes.stream;
  Map<String, String> get devices => Map.unmodifiable(_tokens);
  Map<String, String> get aliases => Map.unmodifiable(_aliases);

  /// Versión del cliente que informó el dispositivo (null = no la ha informado).
  String? versionOf(String token) => _info[token]?['version'] as String?;
  int? versionCodeOf(String token) => (_info[token]?['code'] as num?)?.toInt();

  /// Última vez que el dispositivo habló con el servidor.
  DateTime? lastSeenOf(String token) {
    final ms = (_info[token]?['seen'] as num?)?.toInt();
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// Anota que el dispositivo acaba de dar señales de vida. Es barato (memoria): el
  /// disco se actualiza como mucho cada 20 s y al cerrar el servidor.
  void touch(String token) {
    if (!_tokens.containsKey(token)) return;
    _info.putIfAbsent(token, () => <String, dynamic>{})['seen'] =
        DateTime.now().millisecondsSinceEpoch;
    _saveTimer ??= Timer(const Duration(seconds: 20), flush);
  }

  /// Guarda la versión del cliente que informa el propio dispositivo.
  void setVersion(String token, String? version, int? code) {
    if (!_tokens.containsKey(token)) return;
    final v = version?.trim();
    if (v == null || v.isEmpty || v.length > 40) return;
    final m = _info.putIfAbsent(token, () => <String, dynamic>{});
    final changed = m['version'] != v || m['code'] != code;
    m['version'] = v;
    if (code != null) {
      m['code'] = code;
    } else {
      m.remove('code');
    }
    m['seen'] = DateTime.now().millisecondsSinceEpoch;
    if (changed) {
      flush();
      _changes.add(null);
    }
  }

  /// Escribe device_info.json ya (si hay algo pendiente).
  void flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      _infoFile.writeAsStringSync(jsonEncode(_info));
    } catch (_) {}
  }

  /// Nombre a mostrar: el que puso el dueño del servidor o, si no, el del dispositivo.
  String displayName(String token) =>
      _aliases[token] ?? _tokens[token] ?? 'dispositivo';

  /// Pone nombre a un dispositivo emparejado. Vacío (o igual al original) lo restablece.
  void rename(String token, String name) {
    if (!_tokens.containsKey(token)) return;
    final n = name.trim();
    if (n.isEmpty || n == _tokens[token]) {
      _aliases.remove(token);
    } else {
      _aliases[token] = n;
    }
    _saveAliases();
    _changes.add(null);
  }

  /// Actualiza el nombre con el que el dispositivo se emparejó (lo hace el propio dispositivo
  /// al conectarse). Devuelve el nombre anterior si cambió, o null si no hubo cambio.
  String? updateName(String token, String name) {
    final old = _tokens[token];
    final n = name.trim();
    if (old == null || n.isEmpty || n.length > 60 || n == old) return null;
    _tokens[token] = n;
    _file.writeAsStringSync(jsonEncode(_tokens));
    _changes.add(null);
    return old;
  }

  void _saveAliases() {
    try {
      _aliasFile.writeAsStringSync(jsonEncode(_aliases));
    } catch (_) {}
  }

  void revoke(String token) {
    if (_tokens.remove(token) != null) {
      _file.writeAsStringSync(jsonEncode(_tokens));
      if (_aliases.remove(token) != null) _saveAliases();
      if (_info.remove(token) != null) flush();
      _changes.add(null);
    }
  }

  void _newPin() {
    pin = (100000 + _rng.nextInt(900000)).toString();
    _fails = 0;
    print('>>> PIN de emparejamiento: $pin');
    _changes.add(null);
  }

  String _newToken() => base64UrlEncode(List.generate(32, (_) => _rng.nextInt(256)));

  Future<Response> pair(Request req) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return Response(400, body: 'JSON inválido');
    }
    final viaAuto = open && body['pin'] == kAutoPin;
    if (viaAuto) {
      if (_tokens.length >= _maxOpenDevices) {
        return Response(429, body: 'Demasiados dispositivos emparejados');
      }
    } else if (body['pin'] != pin) {
      // Tras 5 intentos fallidos se rota el PIN para frenar la fuerza bruta.
      if (++_fails >= 5) _newPin();
      return Response(403, body: 'PIN incorrecto');
    }
    final token = _newToken();
    var device = (body['device'] ?? 'dispositivo').toString().trim();
    if (device.isEmpty) device = 'dispositivo';
    if (device.length > 60) device = device.substring(0, 60);
    _tokens[token] = device;
    _file.writeAsStringSync(jsonEncode(_tokens));
    touch(token);
    if (viaAuto) {
      _changes.add(null); // aparece en la lista de dispositivos; el PIN del momento no se gasta
    } else {
      _newPin(); // cada PIN sirve una sola vez
    }
    return Response.ok(jsonEncode({'token': token}),
        headers: {'content-type': 'application/json'});
  }

  /// Exige "Authorization: Bearer <token>" salvo en /api/info y /api/pair.
  Middleware get middleware => (inner) => (req) {
        final path = req.url.path;
        if (path == 'api/info' || path == 'api/pair') return inner(req);
        final token = requestToken(req);
        if (token != null && _tokens.containsKey(token)) {
          touch(token); // cualquier petición autorizada cuenta como "última conexión"
          return inner(req);
        }
        return Response(401, body: 'No autorizado');
      };
}

/// Token del encabezado Authorization o, solo para HLS y subtítulos (donde el
/// reproductor no siempre reenvía encabezados), del parámetro ?token=.
String? requestToken(Request req) {
  final h = req.headers['authorization'];
  if (h != null && h.startsWith('Bearer ')) return h.substring(7);
  final path = req.url.path;
  if (path == 'ws' || path.contains('/hls/') || path.contains('/subtitles/')) {
    return req.url.queryParameters['token'];
  }
  return null;
}