import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Puente con el código nativo de Android (Kotlin): imagen en imagen (PiP).
class NativeBridge {
  static const _ch = MethodChannel('mistreaming/native');
  static final _pip = StreamController<bool>.broadcast();
  static bool _ready = false;

  /// true al entrar en PiP, false al salir.
  static Stream<bool> get pipChanges {
    _init();
    return _pip.stream;
  }

  static void _init() {
    if (_ready || !Platform.isAndroid) return;
    _ready = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'pipChanged') _pip.add(call.arguments as bool);
    });
  }

  /// Activa/desactiva la entrada automática en PiP al salir de la app.
  static Future<void> setPipEnabled(bool on) => _call('setPipEnabled', on);
  static Future<void> enterPip() => _call('enterPip');

  /// Brillo actual de la ventana (0 a 1). null si no se puede leer (solo Android).
  static Future<double?> getBrightness() async {
    if (!Platform.isAndroid) return null;
    _init();
    try {
      return await _ch.invokeMethod<double>('getBrightness');
    } catch (_) {
      return null;
    }
  }

  /// Fija el brillo de la app (0 a 1) sin tocar el del sistema; null vuelve al del sistema.
  static Future<void> setBrightness(double? v) => _call('setBrightness', v ?? -1.0);

  /// Nombre del teléfono tal como lo muestra Android (p. ej. "POCO X8 Pro"). null si no se pudo leer.
  static Future<String?> deviceName() async {
    if (!Platform.isAndroid) return null;
    _init();
    try {
      final n = await _ch.invokeMethod<String>('deviceName');
      final t = n?.trim();
      return (t == null || t.isEmpty) ? null : t;
    } catch (_) {
      return null;
    }
  }

  /// ¿Es una TV o TV box (Android TV / Google TV)? false en móviles y fuera de Android.
  static Future<bool> isTv() async {
    if (!Platform.isAndroid) return false;
    _init();
    try {
      return await _ch.invokeMethod<bool>('isTv') ?? false;
    } catch (_) {
      return false;
    }
  }

  // ---------- actualización automática ----------
  /// Versión instalada ({package, versionCode, versionName}); null fuera de Android.
  static Future<({String package, int code, String name})?> appVersion() async {
    if (!Platform.isAndroid) return null;
    _init();
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('appVersion');
      if (m == null) return null;
      return (
        package: m['package'] as String,
        code: (m['versionCode'] as num).toInt(),
        name: m['versionName'] as String
      );
    } catch (_) {
      return null;
    }
  }

  /// ¿Tiene la app permiso para instalar APK ("instalar apps desconocidas")?
  static Future<bool> canInstallPackages() async {
    if (!Platform.isAndroid) return false;
    _init();
    try {
      return await _ch.invokeMethod<bool>('canInstallPackages') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Abre el ajuste donde se concede ese permiso a esta app.
  static Future<void> openInstallSettings() => _call('openInstallSettings');

  /// Abre el instalador del sistema con el APK. "ok", "no_permission", "no_file" o "error: ...".
  static Future<String> installApk(String path) async {
    if (!Platform.isAndroid) return 'error: solo Android';
    _init();
    try {
      return await _ch.invokeMethod<String>('installApk', path) ?? 'error';
    } catch (e) {
      return 'error: $e';
    }
  }

  // ---------- segundo plano ----------
  /// Servicio en primer plano que mantiene viva la conexión con el servidor al minimizar.
  static Future<void> startKeepAlive() => _call('startKeepAlive');
  static Future<void> stopKeepAlive() => _call('stopKeepAlive');

  /// ¿Está la app exenta de la optimización de batería?
  static Future<bool> ignoringBatteryOpts() async {
    if (!Platform.isAndroid) return true;
    _init();
    try {
      return await _ch.invokeMethod<bool>('ignoringBatteryOpts') ?? false;
    } catch (_) {
      return false;
    }
  }

  // ---------- notificaciones ----------
  /// Progreso de las descargas en la notificación del servicio. [percent] < 0 = sin porcentaje.
  static Future<void> downloadProgress(String title, String text, int percent) =>
      _call('downloadProgress', {'title': title, 'text': text, 'percent': percent});

  /// Quita el progreso de descargas (vuelve la notificación discreta del servicio).
  static Future<void> clearDownloadProgress() => _call('clearDownloadProgress');

  /// Aviso puntual del sistema (con sonido). [id] distinto = aviso distinto.
  static Future<void> notify(int id, String title, String text) =>
      _call('notify', {'id': id, 'title': title, 'text': text});

  static Future<void> requestIgnoreBatteryOpts() => _call('requestIgnoreBatteryOpts');

  static Future<void> _call(String method, [Object? args]) async {
    if (!Platform.isAndroid) return;
    _init();
    try {
      await _ch.invokeMethod(method, args);
    } catch (_) {}
  }
}
