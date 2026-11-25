import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ===========================================================================
//  Sonidos de la interfaz (assets/sounds/*.mp3).
//
//  Todo pasa por aquí: el resto de la app solo llama a `Sfx.play(Snd.xxx)`.
//
//  · Cada sonido tiene su archivo, su volumen y un "enfriamiento" mínimo entre dos
//    reproducciones (para que mantener pulsada una flecha no sea una ametralladora).
//  · SOLO SUENAN EN TV (Android TV / TV box). En móvil, tablet y escritorio Sfx no hace nada:
//    ni carga audio ni escucha el foco. Se fija en main() con Sfx.init(tv: ...).
//  · En TV se pueden desactivar en Ajustes → "Sonidos de la interfaz" (Sfx.enabled).
//  · Mientras se reproduce un video (Sfx.pushPlayer / popPlayer) los sonidos de navegación
//    se callan para no pisar el audio de la película. Las salas y los avisos usan
//    `force: true` y suenan igualmente.
//  · No pide el "foco de audio" de Android: así NO pausa ni baja el volumen de lo que suene.
//
//  Para cambiar qué archivo suena en cada sitio o su volumen, edita solo el enum Snd.
// ===========================================================================

enum Snd {
  /// Error, aviso o diálogo de confirmación (borrar, etc.) y servidor sin conexión.
  alerta('s_alerta.mp3', 0.8),

  /// Mover el foco entre elementos con el mando / teclado (carátulas, botones, filas).
  desplazamiento('s_desplazamiento_interfaz.mp3', 0.35, 70),

  /// Cambiar de zona o de sección (menú lateral ↔ pantalla, pestañas de la barra).
  desplazamiento2('s_desplazamiento_interfaz_2.mp3', 0.45, 120),

  /// Una descarga (o varias) empieza o se reanuda.
  empezarDescarga('s_empezar_descarga.mp3', 0.7),

  /// Abrir / aceptar: tocar o pulsar OK en una carátula, y empezar a reproducir.
  entrar('s_entrar.mp3', 0.6),

  /// Entras en una sala de "ver juntos".
  entrarASala('s_entrar_a_sala.mp3', 0.8),

  /// Al abrir la app.
  // OJO: el archivo lleva un espacio en el nombre ("al inicia_app"). Funciona, pero si algún
  // día da guerra, renómbralo (p. ej. s_intro_al_inicia_app.mp3) y cambia SOLO esta línea.
  intro('s_intro_al inicia_app.mp3', 0.8),

  /// Marcar novedades / avisos como vistos.
  marcarVisto('s_marcar_visto_notificaciones.mp3', 0.6),

  /// Llega un aviso: capítulo nuevo, petición disponible, descarga completada.
  notificacion('s_notificacion.mp3', 0.9),

  /// Volver atrás o salir de una pantalla.
  salirOAtras('s_salir_o_atras.mp3', 0.5, 150),

  /// Sales de una sala de "ver juntos".
  salirDeSala('s_salirde_sala.mp3', 0.7);

  const Snd(this.file, this.volume, [this.cooldownMs = 200]);
  final String file;
  final double volume;
  final int cooldownMs;

  /// Ruta como la espera audioplayers (relativa a la carpeta assets/).
  String get path => 'sounds/$file';
}

class Sfx {
  Sfx._();

  /// Interruptor general (Ajustes). Se carga de las preferencias al arrancar.
  static bool enabled = true;

  /// ¿Es una TV? Fuera de TV no suena nada, ni siquiera con `force: true`.
  static bool isTv = false;

  static const kPrefKey = 'set_sounds';

  static final Map<Snd, AudioPlayer> _players = {};
  static final Map<Snd, int> _last = {};
  static int _playerDepth = 0;
  static int _lastArrowMs = 0;
  static int _quietUntilMs = 0;
  static bool _ready = false;

  static int get _now => DateTime.now().millisecondsSinceEpoch;

  /// Se llama una vez en main(), antes de runApp.
  static Future<void> init({required bool enabled, required bool tv}) async {
    isTv = tv;
    Sfx.enabled = enabled && tv;
    if (!tv) return; // fuera de TV: sin contexto de audio ni oyentes
    if (_ready) return;
    _ready = true;
    try {
      // Que los efectos convivan con el video y con otras apps: sin foco de audio.
      await AudioPlayer.global.setAudioContext(AudioContext(
        android: AudioContextAndroid(
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.assistanceSonification,
          audioFocus: AndroidAudioFocus.none,
          stayAwake: false,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.ambient,
          options: const {AVAudioSessionOptions.mixWithOthers},
        ),
      ));
    } catch (e) {
      debugPrint('Sfx: no se pudo fijar el contexto de audio: $e');
    }
    // Para saber si un cambio de foco lo provocó una flecha del mando/teclado.
    HardwareKeyboard.instance.addHandler(_onKey);
    FocusManager.instance.addListener(_onFocusChanged);
  }

  // ---------------------------------------------------------------------------
  //  Reproducción
  // ---------------------------------------------------------------------------

  /// Reproduce [s]. Con `force` suena aunque haya un video en pantalla.
  static void play(Snd s, {bool force = false}) {
    if (!isTv || !enabled) return;
    if (_playerDepth > 0 && !force) return;
    final t = _now;
    if (t < _quietUntilMs && s == Snd.desplazamiento) return;
    final prev = _last[s];
    if (prev != null && t - prev < s.cooldownMs) return;
    _last[s] = t;
    unawaited(_fire(s));
  }

  static Future<void> _fire(Snd s) async {
    try {
      var p = _players[s];
      if (p == null) {
        p = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
        _players[s] = p;
        await p.setVolume(s.volume);
        await p.play(AssetSource(s.path));
        return;
      }
      await p.stop();
      await p.resume();
    } catch (_) {
      // Si "reanudar" falla (reproductor ya liberado), se vuelve a cargar desde cero.
      try {
        final p = _players[s] ?? AudioPlayer();
        _players[s] = p;
        await p.setVolume(s.volume);
        await p.play(AssetSource(s.path));
      } catch (e) {
        debugPrint('Sfx: no se pudo reproducir ${s.file}: $e');
      }
    }
  }

  /// Cambio de zona/sección: suena y, durante un instante, calla el "tic" de foco para que
  /// no suenen los dos a la vez.
  static void zone() {
    _quietUntilMs = _now + 150;
    play(Snd.desplazamiento2);
  }

  // ---------------------------------------------------------------------------
  //  Video en pantalla
  // ---------------------------------------------------------------------------

  static void pushPlayer() => _playerDepth++;
  static void popPlayer() {
    if (_playerDepth > 0) _playerDepth--;
  }

  // ---------------------------------------------------------------------------
  //  "Tic" al mover el foco con flechas (mando, teclado)
  //
  //  Un solo oyente global: no hace falta tocar cada tarjeta ni cada botón. Solo suena si el
  //  cambio de foco llegó justo tras pulsar una flecha (no al abrir una pantalla ni al tocar).
  // ---------------------------------------------------------------------------

  static bool _onKey(KeyEvent e) {
    if (e is KeyUpEvent) return false;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight) {
      _lastArrowMs = _now;
    }
    return false; // nunca "consume" la tecla
  }

  static void _onFocusChanged() {
    if (!isTv || !enabled) return;
    if (FocusManager.instance.highlightMode != FocusHighlightMode.traditional) {
      return;
    }
    final f = FocusManager.instance.primaryFocus;
    if (f == null || f is FocusScopeNode) return;
    if (_now - _lastArrowMs > 250) return;
    play(Snd.desplazamiento);
  }
}

// ===========================================================================
//  Ayudas
// ===========================================================================

/// Snack de error: suena el aviso y muestra el texto. Úsalo en lugar de
/// `SnackBar(content: Text(errText(e)))`.
SnackBar errorSnack(String text) {
  Sfx.play(Snd.alerta, force: true);
  return SnackBar(content: Text(text));
}

/// "Atrás": suena al cerrar una pantalla completa (no hojas ni diálogos).
class SfxNavigatorObserver extends NavigatorObserver {
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute && previousRoute != null) Sfx.play(Snd.salirOAtras);
  }
}
