// ===========================================================================
//  Progreso de reproducción: primero en el dispositivo, después en el servidor.
//
//  Antes cada guardado era una petición suelta que, si fallaba (Wi-Fi flojo, servidor
//  ocupado, app cerrada justo al salir), se perdía sin avisar y la siguiente vez el video
//  arrancaba desde un punto viejo o desde cero. Ahora:
//
//   · Cada posición se anota al instante en el dispositivo (sobrevive a cierres de la app).
//   · Se sube en segundo plano, de una en una y en orden; si falla, se reintenta sola con
//     espera creciente y en cuanto vuelve la conexión con el servidor.
//   · Al abrir un video se prefiere lo anotado aquí que todavía no llegó al servidor (es lo
//     más reciente); si no hay nada pendiente, manda el servidor (puede venir de otro aparato).
//   · Cada envío lleva una marca de orden: el servidor ignora una posición más vieja que otra
//     ya recibida del mismo dispositivo (peticiones que llegan desordenadas).
// ===========================================================================
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api.dart';
import 'core.dart';
import 'remote.dart' show serverOfflineProvider;

class _Pending {
  _Pending(this.profile, this.videoId, this.pos, this.ts, {this.old = false});
  final String profile, videoId;
  int pos, ts;

  /// true = posición de hace rato (p. ej. la de una descarga vista sin conexión): conserva su
  /// marca original y, si el servidor ya tiene algo más reciente, se descarta en vez de
  /// subirla con una marca nueva.
  final bool old;

  Map<String, dynamic> toJson() => {
        'u': profile,
        'v': videoId,
        'p': pos,
        't': ts,
        if (old) 'o': true,
      };

  /// Lectura tolerante: acepta también lo guardado por versiones anteriores (sin perfil o sin
  /// marca de orden) en vez de descartarlo en silencio.
  static _Pending? fromJson(Object? o, {required int fallbackTs}) {
    if (o is! Map) return null;
    final u = o['u'] ?? o['profile'] ?? '';
    final v = o['v'] ?? o['videoId'] ?? o['id'];
    final p = o['p'] ?? o['pos'] ?? o['positionMs'];
    final t = o['t'] ?? o['ts'];
    if (v is! String || p is! num) return null;
    return _Pending(
        u is String ? u : '', v, p.toInt(), t is num ? t.toInt() : fallbackTs,
        old: o['o'] == true || t is! num);
  }
}

class ProgressSync {
  ProgressSync(this._ref) {
    _load();
  }

  final Ref _ref;
  static const _kKey = 'progress_pending_v1';
  // Última marca de orden usada: se guarda para que siga creciendo aunque se reinicie la app o
  // el reloj del dispositivo retroceda (si no, el servidor tomaría lo nuevo por antiguo).
  static const _kTsKey = 'progress_last_ts_v1';
  // Lo pendiente que lleva más de esto sin poder subirse se descarta (ya no es "lo último").
  static const _maxAge = Duration(days: 7);

  final _pending =
      <String, _Pending>{}; // "perfil|video" -> última posición sin subir
  final _sentAt = <String,
      int>{}; // "perfil|video" -> cuándo (reloj local) subió bien por última vez
  Timer? _retry;
  int _fails = 0;
  int _lastTs = 0;
  bool _flushing = false, _again = false, _disposed = false;
  Future<void>? _flushFuture;

  String get _profile =>
      _ref.read(prefsProvider).getString('profile_username') ?? '';
  String _k(String profile, String id) => '$profile|$id';

  void _load() {
    try {
      _lastTs = _ref.read(prefsProvider).getInt(_kTsKey) ?? 0;
    } catch (_) {}
    try {
      final raw = _ref.read(prefsProvider).getString(_kKey);
      if (raw == null) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final o in (jsonDecode(raw) as List)) {
        final e = _Pending.fromJson(o, fallbackTs: now);
        if (e == null) continue;
        if (now - e.ts > _maxAge.inMilliseconds) continue;
        _pending[_k(e.profile, e.videoId)] = e;
        _lastTs = math.max(_lastTs, e.ts);
      }
    } catch (_) {
      // Datos ilegibles: se empieza limpio (solo se pierde lo que no había subido).
    }
  }

  void _persist() {
    final p = _ref.read(prefsProvider);
    if (_pending.isEmpty) {
      p.remove(_kKey);
    } else {
      p.setString(
          _kKey, jsonEncode([for (final e in _pending.values) e.toJson()]));
    }
  }

  /// Posición anotada en este dispositivo que aún no llegó al servidor (null = nada pendiente).
  int? pendingPosition(String videoId) => _find(videoId)?.pos;

  /// Marca (reloj de este dispositivo) de esa posición pendiente.
  int? pendingTs(String videoId) => _find(videoId)?.ts;

  /// Cuándo (reloj de este dispositivo) se subió bien por última vez este video. Sirve para no
  /// confundir con "otro dispositivo" lo que el servidor recibió de aquí con retraso.
  int lastSentAt(String videoId) => _sentAt[_k(_profile, videoId)] ?? 0;

  // Lo anotado antes de conocer el perfil (clave vacía) también cuenta como del actual.
  _Pending? _find(String videoId) =>
      _pending[_k(_profile, videoId)] ?? _pending[_k('', videoId)];

  void _saveTs() {
    try {
      _ref.read(prefsProvider).setInt(_kTsKey, _lastTs);
    } catch (_) {}
  }

  /// Anota la posición (síncrono: sirve también al cerrar el reproductor) y la sube en
  /// segundo plano.
  void record(String videoId, int positionMs) {
    if (_disposed || positionMs < 0) return;
    final profile = _profile;
    // Marca estrictamente creciente aunque el reloj dé el mismo milisegundo dos veces.
    _lastTs = math.max(DateTime.now().millisecondsSinceEpoch, _lastTs + 1);
    _saveTs();
    _pending[_k(profile, videoId)] =
        _Pending(profile, videoId, positionMs, _lastTs);
    _persist();
    unawaited(flush());
  }

  /// Anota una posición vista en otro momento (la de una descarga reproducida sin conexión)
  /// conservando [ts], su marca original: si de aquí ya salió algo más reciente, no lo pisa.
  void recordAt(String videoId, int positionMs, int ts) {
    if (_disposed || positionMs < 0) return;
    final profile = _profile;
    final key = _k(profile, videoId);
    final cur = _pending[key];
    if (cur != null && cur.ts >= ts) return;
    _pending[key] = _Pending(profile, videoId, positionMs, ts, old: true);
    _persist();
    unawaited(flush());
  }

  /// Sube lo pendiente. Varias llamadas seguidas se juntan en una sola ronda.
  Future<void> flush() {
    if (_flushing) {
      _again = true;
      return _flushFuture ?? Future.value();
    }
    return _flushFuture = _run();
  }

  Future<void> _run() async {
    _flushing = true;
    var failed = false;
    try {
      var staleRetries = 0;
      do {
        _again = false;
        final api = _ref.read(apiProvider);
        if (api == null || _pending.isEmpty) break;
        final profile = _profile;
        // Lo anotado sin perfil (antes de que el servidor lo asignara) se sube con el actual.
        final batch = _pending.values
            .where((e) => e.profile == profile || e.profile.isEmpty)
            .toList()
          ..sort((a, b) => a.ts.compareTo(b.ts));
        for (final sent in batch) {
          final res = await api.putProgressDetailed(sent.videoId, sent.pos,
              ts: sent.ts);
          final r = res.save;
          debugPrint('[reanudar] subir ${sent.videoId} ${sent.pos}ms -> $r');
          if (r == ProgressSave.retry) {
            failed =
                true; // sin red o servidor ocupado: no insistir con el resto ahora
            break;
          }
          final key = _k(sent.profile, sent.videoId);
          final cur = _pending[key];
          if (r == ProgressSave.stale) {
            // El servidor ya tenía una marca mayor de este dispositivo (reloj atrasado o
            // reiniciado). Lo que se acaba de ver SÍ vale: se vuelve a subir con una marca
            // por encima de la del servidor. Lo antiguo (descargas) se descarta.
            if (cur != null && cur.ts == sent.ts) {
              if (!cur.old && staleRetries < 3) {
                staleRetries++;
                _lastTs = math.max(
                    math.max(DateTime.now().millisecondsSinceEpoch, _lastTs),
                    (res.staleTs ?? 0) + 1);
                _saveTs();
                cur.ts = _lastTs;
                _again = true;
              } else {
                _pending.remove(key);
              }
            }
            continue;
          }
          // Guardado (o rechazado para siempre: el video ya no existe): se quita de la
          // cola, salvo que mientras tanto haya llegado una posición más nueva.
          _sentAt[key] = DateTime.now().millisecondsSinceEpoch;
          if (cur != null && cur.ts == sent.ts) _pending.remove(key);
        }
        _persist();
      } while (_again && !failed && !_disposed);
    } catch (_) {
      failed = true;
    } finally {
      _flushing = false;
      _flushFuture = null;
    }
    if (!failed && _refreshWhenDone) {
      _refreshWhenDone = false;
      _ref.invalidate(libraryProvider);
    }
    if (failed) {
      _scheduleRetry();
    } else {
      _fails = 0;
      _retry?.cancel();
      _retry = null;
    }
  }

  void _scheduleRetry() {
    if (_disposed || _pending.isEmpty) return;
    _retry?.cancel();
    // 5 s, 10 s, 20 s... hasta 5 min.
    final secs = math.min(300, 5 * (1 << math.min(_fails, 6)));
    _fails++;
    _retry = Timer(Duration(seconds: secs), () => unawaited(flush()));
  }

  /// Descarta lo pendiente de un video (cuando el servidor tiene algo más reciente de otro
  /// dispositivo: subirlo ahora pisaría esa posición).
  void discardPending(String videoId) {
    final cur = _find(videoId);
    if (cur == null) return;
    _pending.remove(_k(cur.profile, cur.videoId));
    _persist();
  }

  /// Sube lo pendiente y espera a que termine la ronda (p. ej. antes de cambiar de perfil).
  Future<void> flushNow([Duration timeout = const Duration(seconds: 6)]) async {
    try {
      await flush().timeout(timeout);
    } catch (_) {}
  }

  /// Espera (como mucho [timeout]) a que termine la subida en curso. Se usa al volver del
  /// reproductor para que la biblioteca ya vea la posición recién guardada.
  Future<void> settle([Duration timeout = const Duration(seconds: 2)]) async {
    final f = _flushFuture;
    if (f == null) return;
    try {
      await f.timeout(timeout);
    } catch (_) {
      // Red lenta: la biblioteca se refrescará sola cuando termine la subida.
      _refreshWhenDone = true;
    }
  }

  bool _refreshWhenDone = false;

  /// Olvida lo pendiente del perfil actual (al reiniciar el progreso en el servidor).
  void clearCurrentProfile() {
    final profile = _profile;
    _pending.removeWhere((_, e) => e.profile == profile);
    _persist();
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
  }
}

final progressSyncProvider = Provider<ProgressSync>((ref) {
  final s = ProgressSync(ref);
  // Servidor otra vez disponible: se sube lo que quedó pendiente.
  ref.listen<bool>(serverOfflineProvider, (_, offline) {
    if (!offline) unawaited(s.flush());
  });
  // Si cambia la sesión (otro servidor o token nuevo) también se intenta de nuevo.
  ref.listen(apiProvider, (_, api) {
    if (api != null) unawaited(s.flush());
  });
  ref.onDispose(s.dispose);
  // Lo que quedó sin subir en una sesión anterior.
  Future.microtask(s.flush);
  return s;
});
