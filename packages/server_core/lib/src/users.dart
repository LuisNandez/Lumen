import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shared/shared.dart';

import 'media.dart' show JsonFile;

/// Error de una operación de perfiles con el código HTTP que le corresponde.
class ProfileException implements Exception {
  const ProfileException(this.status, this.message, {this.retryAfterSeconds});
  final int status;
  final String message;

  /// Solo en los bloqueos por demasiados PIN incorrectos (429).
  final int? retryAfterSeconds;
  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
//  Avatares: los .jpg que el dueño del servidor deja en la carpeta `avatars/`
// ---------------------------------------------------------------------------

/// Carpeta de avatares. El id de cada avatar es el nombre del archivo sin `.jpg`
/// (solo letras, números, `-` y `_`). Las subcarpetas son paquetes: el nombre de la
/// carpeta es el del paquete y el id pasa a ser `Paquete|archivo`. Se vuelve a leer en cada consulta: basta con
/// copiar un archivo nuevo a la carpeta para que aparezca.
class AvatarStore {
  AvatarStore(String path) : dir = Directory(path) {
    dir.createSync(recursive: true);
  }

  final Directory dir;

  /// Archivos de la carpeta que no se pudieron usar (con el motivo), para avisar al dueño.
  final skipped = <String, String>{};

  static const _exts = {'.jpg', '.jpeg'};

  /// Subcarpetas que no son paquetes (copias de seguridad de "Arreglar carpeta").
  static const _notPacks = {'originales'};

  /// Paquetes: las subcarpetas de la carpeta de avatares (el nombre de la carpeta es el
  /// nombre del paquete), por orden alfabético.
  List<Directory> packDirs() {
    try {
      final d = dir
          .listSync(followLinks: false)
          .whereType<Directory>()
          .where((e) {
        final n = p.basename(e.path);
        return !n.startsWith('.') && !_notPacks.contains(n.toLowerCase());
      }).toList()
        ..sort((a, b) => p
            .basename(a.path)
            .toLowerCase()
            .compareTo(p.basename(b.path).toLowerCase()));
      return d;
    } catch (_) {
      return const [];
    }
  }

  /// Avatares válidos: primero los sueltos y luego los de cada paquete, por nombre.
  /// El id de uno de paquete es `Paquete|archivo` (ver [avatarPackSep]).
  List<({String id, String? pack, File file, int v})> scan() {
    final out = <({String id, String? pack, File file, int v})>[];
    final bad = <String, String>{};
    try {
      for (final e in dir.listSync(followLinks: false)) {
        if (e is File) _scanFile(e, null, out, bad);
      }
      for (final d in packDirs()) {
        final pack = p.basename(d.path);
        if (!isValidAvatarPack(pack)) {
          bad[pack] = 'nombre de paquete no válido';
          continue;
        }
        for (final e in d.listSync(followLinks: false)) {
          if (e is File) _scanFile(e, pack, out, bad);
        }
      }
    } catch (_) {}
    out.sort((a, b) {
      final g = (a.pack == null ? 0 : 1) - (b.pack == null ? 0 : 1);
      if (g != 0) return g;
      final c = (a.pack ?? '').toLowerCase().compareTo((b.pack ?? '').toLowerCase());
      if (c != 0) return c;
      return a.id.toLowerCase().compareTo(b.id.toLowerCase());
    });
    skipped
      ..clear()
      ..addAll(bad);
    return out;
  }

  void _scanFile(File e, String? pack,
      List<({String id, String? pack, File file, int v})> out, Map<String, String> bad) {
    final name = p.basename(e.path);
    final shown = pack == null ? name : '$pack/$name';
    final ext = p.extension(name).toLowerCase();
    if (name.startsWith('.')) return; // .gitkeep, etc.
    if (!_exts.contains(ext)) {
      if (name.toLowerCase() != 'leeme.txt' && name.toLowerCase() != 'readme.md') {
        bad[shown] = 'no es .jpg';
      }
      return;
    }
    final stem = p.basenameWithoutExtension(name);
    if (!isValidAvatarId(stem)) {
      bad[shown] = 'nombre no válido (solo letras, números, - y _)';
      return;
    }
    final st = e.statSync();
    if (st.size <= 0 || st.size > avatarMaxBytes) {
      bad[shown] =
          'pesa ${(st.size / 1024).round()} KB (máximo ${avatarMaxBytes ~/ 1024} KB)';
      return;
    }
    if (!_looksLikeJpeg(e)) {
      bad[shown] = 'no es un JPEG válido';
      return;
    }
    out.add((
      id: pack == null ? stem : '$pack$avatarPackSep$stem',
      pack: pack,
      file: e,
      v: st.modified.millisecondsSinceEpoch ~/ 1000
    ));
  }

  bool _looksLikeJpeg(File f) {
    RandomAccessFile? r;
    try {
      r = f.openSync();
      final h = r.readSync(3);
      return h.length == 3 && h[0] == 0xFF && h[1] == 0xD8 && h[2] == 0xFF;
    } catch (_) {
      return false;
    } finally {
      r?.closeSync();
    }
  }

  List<AvatarInfo> list() =>
      [for (final a in scan()) AvatarInfo(a.id, a.v, pack: a.pack)];

  /// El archivo de ese avatar, o null. Solo se sirve lo que aparece en la lista,
  /// así que un id manipulado nunca sale de la carpeta.
  File? file(String id) {
    for (final a in scan()) {
      if (a.id == id) return a.file;
    }
    return null;
  }

  int version(String id) {
    for (final a in scan()) {
      if (a.id == id) return a.v;
    }
    return 0;
  }
}

// ---------------------------------------------------------------------------
//  Perfiles de usuario
// ---------------------------------------------------------------------------

/// Perfiles de usuario (`users.json`) y qué perfil está usando cada dispositivo
/// (`device_profiles.json`).
///
/// El nombre de usuario es el identificador: único sin distinguir mayúsculas y no se
/// puede cambiar (el progreso y las peticiones cuelgan de él). El PIN es opcional,
/// de 4 dígitos, y se guarda con sal y hash: nunca en claro.
class UserStore {
  UserStore(String dataDir, this.avatars)
      : _users = JsonFile(p.join(dataDir, 'users.json')),
        _active = JsonFile(p.join(dataDir, 'device_profiles.json'));

  final AvatarStore avatars;
  final JsonFile _users;
  final JsonFile _active; // deviceKey -> clave (minúsculas) del perfil
  final _rng = Random.secure();
  final _changes = StreamController<void>.broadcast();

  // Frenos a la fuerza bruta: 5 fallos seguidos bloquean ese perfil un minuto.
  static const _maxFails = 5;
  static const _lockSeconds = 60;
  final _fails = <String, int>{};
  final _lockedUntil = <String, int>{};

  /// Emite cuando cambia algo visible en la lista de perfiles.
  Stream<void> get changes => _changes.stream;

  Map<String, dynamic> get _map =>
      (_users.data['users'] ??= <String, dynamic>{}) as Map<String, dynamic>;

  Map<String, dynamic>? _raw(String username) {
    final e = _map[normalizeUsername(username)];
    return e is Map ? e.cast<String, dynamic>() : null;
  }

  UserProfile _view(Map<String, dynamic> m) {
    final av = m['avatar'] as String?;
    return UserProfile('${m['username']}',
        avatar: av,
        avatarV: av == null ? 0 : avatars.version(av),
        hasPin: m['hash'] is String,
        createdMs: (m['createdMs'] as int?) ?? 0,
        lastSeenMs: (m['lastSeenMs'] as int?) ?? 0);
  }

  /// Todos los perfiles, en orden de creación.
  List<UserProfile> list() {
    final all = [
      for (final e in _map.values)
        if (e is Map) e.cast<String, dynamic>()
    ];
    all.sort((a, b) => ((a['createdMs'] as int?) ?? 0)
        .compareTo((b['createdMs'] as int?) ?? 0));
    final known = {for (final a in avatars.scan()) a.id: a.v};
    return [
      for (final m in all)
        UserProfile('${m['username']}',
            // Si el .jpg ya no está en la carpeta, el perfil se queda sin avatar.
            avatar:
                known.containsKey(m['avatar']) ? m['avatar'] as String : null,
            avatarV: known[m['avatar']] ?? 0,
            hasPin: m['hash'] is String,
            createdMs: (m['createdMs'] as int?) ?? 0,
            lastSeenMs: (m['lastSeenMs'] as int?) ?? 0)
    ];
  }

  UserProfile? get(String username) {
    final m = _raw(username);
    return m == null ? null : _view(m);
  }

  // ---------- PIN ----------

  String _newSalt() =>
      base64UrlEncode(List.generate(16, (_) => _rng.nextInt(256)));

  String _hash(String pin, String salt) {
    final s = utf8.encode(salt);
    List<int> d = utf8.encode('$salt:$pin');
    for (var i = 0; i < 4000; i++) {
      d = sha256.convert([...d, ...s]).bytes;
    }
    return base64UrlEncode(d);
  }

  bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var r = 0;
    for (var i = 0; i < a.length; i++) {
      r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return r == 0;
  }

  /// Comprueba el PIN de [m] (si lo tiene). Lanza [ProfileException] si falta o no coincide,
  /// y bloquea el perfil un rato tras varios fallos seguidos.
  void _requirePin(Map<String, dynamic> m, String? pin) {
    final hash = m['hash'];
    if (hash is! String) return; // sin PIN: nada que comprobar
    final key = normalizeUsername('${m['username']}');
    final now = DateTime.now().millisecondsSinceEpoch;
    final until = _lockedUntil[key] ?? 0;
    if (until > now) {
      final secs = ((until - now) / 1000).ceil();
      throw ProfileException(
          429, 'Demasiados intentos. Espera $secs s para volver a probar.',
          retryAfterSeconds: secs);
    }
    if (pin == null || pin.isEmpty) {
      throw const ProfileException(403, 'Este perfil tiene PIN.');
    }
    if (isValidPin(pin) && _same(_hash(pin, '${m['salt']}'), hash)) {
      _fails.remove(key);
      return;
    }
    final n = (_fails[key] ?? 0) + 1;
    if (n >= _maxFails) {
      _fails.remove(key);
      _lockedUntil[key] = now + _lockSeconds * 1000;
      throw const ProfileException(429,
          'Demasiados intentos. Espera $_lockSeconds s para volver a probar.',
          retryAfterSeconds: _lockSeconds);
    }
    _fails[key] = n;
    throw ProfileException(
        403, 'PIN incorrecto. Te quedan ${_maxFails - n} intentos.');
  }

  void _setPin(Map<String, dynamic> m, String pin) {
    if (!isValidPin(pin)) {
      throw const ProfileException(400, 'El PIN son $pinLength dígitos.');
    }
    final salt = _newSalt();
    m['salt'] = salt;
    m['hash'] = _hash(pin, salt);
  }

  // ---------- altas, cambios y bajas ----------

  void _checkAvatar(String? avatar) {
    if (avatar == null) return;
    if (!isValidAvatarRef(avatar) || avatars.file(avatar) == null) {
      throw const ProfileException(
          400, 'Ese avatar no existe en la carpeta del servidor.');
    }
  }

  UserProfile create(String username,
      {String? avatar, String? pin, DateTime? now}) {
    final name = username.trim();
    final bad = validateUsername(name);
    if (bad != null) throw ProfileException(400, bad);
    if (_raw(name) != null) {
      throw const ProfileException(409, 'Ese nombre de usuario ya existe.');
    }
    if (_map.length >= maxProfiles) {
      throw const ProfileException(
          409, 'Se alcanzó el máximo de $maxProfiles perfiles.');
    }
    _checkAvatar(avatar);
    final m = <String, dynamic>{
      'username': name,
      'avatar': avatar,
      'createdMs': (now ?? DateTime.now()).millisecondsSinceEpoch,
      'lastSeenMs': 0,
    };
    if (pin != null && pin.isNotEmpty) _setPin(m, pin);
    _map[normalizeUsername(name)] = m;
    _users.save();
    _changes.add(null);
    return _view(m);
  }

  /// Cambia el avatar y/o el PIN. Si el perfil tiene PIN hay que darlo en [currentPin].
  /// Con [setAvatar] = true se aplica [avatar] aunque sea null (quitar el avatar).
  UserProfile update(String username,
      {bool setAvatar = false,
      String? avatar,
      String? newPin,
      bool removePin = false,
      String? currentPin}) {
    final m = _raw(username);
    if (m == null) throw const ProfileException(404, 'No existe ese perfil.');
    _requirePin(m, currentPin);
    if (setAvatar) {
      _checkAvatar(avatar);
      m['avatar'] = avatar;
    }
    if (removePin) {
      m.remove('hash');
      m.remove('salt');
    } else if (newPin != null && newPin.isNotEmpty) {
      _setPin(m, newPin);
    }
    _map[normalizeUsername(username)] = m;
    _users.save();
    _changes.add(null);
    return _view(m);
  }

  /// Quita el PIN sin pedirlo (lo hace el dueño del servidor desde su ventana).
  void resetPin(String username) {
    final m = _raw(username);
    if (m == null) return;
    m.remove('hash');
    m.remove('salt');
    _lockedUntil.remove(normalizeUsername(username));
    _fails.remove(normalizeUsername(username));
    _users.save();
    _changes.add(null);
  }

  /// Borra el perfil. Con [force] no pide el PIN (dueño del servidor). El que llama debe
  /// borrar también el progreso y las peticiones que colgaban de él.
  void delete(String username, {String? pin, bool force = false}) {
    final m = _raw(username);
    if (m == null) throw const ProfileException(404, 'No existe ese perfil.');
    if (!force) _requirePin(m, pin);
    final key = normalizeUsername(username);
    _map.remove(key);
    _users.save();
    for (final d in _active.data.keys.toList()) {
      if (_active.data[d] == key) _active.data.remove(d);
    }
    _active.save();
    _changes.add(null);
  }

  // ---------- qué perfil usa cada dispositivo ----------

  /// Nombre de usuario (tal como se escribió) con el que actúa el dispositivo, o null.
  String? activeFor(String deviceKey) {
    final k = _active.data[deviceKey];
    if (k is! String) return null;
    final m = _raw(k);
    return m == null ? null : '${m['username']}';
  }

  /// Elige el perfil con el que actúa el dispositivo (pide el PIN si lo tiene).
  UserProfile select(String deviceKey, String username, {String? pin}) {
    final m = _raw(username);
    if (m == null) throw const ProfileException(404, 'No existe ese perfil.');
    _requirePin(m, pin);
    m['lastSeenMs'] = DateTime.now().millisecondsSinceEpoch;
    _users.save();
    _active.data[deviceKey] = normalizeUsername(username);
    _active.save();
    _changes.add(null);
    return _view(m);
  }

  /// El dispositivo deja de tener perfil activo (al revocar su emparejamiento).
  void forgetDevice(String deviceKey) {
    if (_active.data.remove(deviceKey) != null) {
      _active.save();
      _changes.add(null);
    }
  }

  /// Cuántos dispositivos usan ahora mismo cada perfil (clave en minúsculas).
  Map<String, int> deviceCounts() {
    final out = <String, int>{};
    for (final v in _active.data.values) {
      if (v is String) out[v] = (out[v] ?? 0) + 1;
    }
    return out;
  }
}
