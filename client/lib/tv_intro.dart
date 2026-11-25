import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import 'core.dart';
import 'profiles.dart' show profilesProvider;
import 'remote.dart' show serverOfflineProvider;
import 'sounds.dart';
import 'tv.dart' show tvHomeResetFocus;

// ===========================================================================
//  Intro en video SOLO PARA TV (el teléfono sigue con la animación LUMEN de splash.dart).
//
//  1. Al abrir la app se reproduce assets/video/Lumen_intro_4K_UHD.mp4 a pantalla completa
//     con video_player (ExoPlayer en Android: decodificación por hardware, muy fiable en
//     Fire TV / Android TV).
//  2. El video termina en negro: en ese momento (y cuando la app de debajo ya cargó) el negro
//     se funde con la interfaz, así el fundido del video continúa sin cortes.
//  3. Mientras dura el video (y el fundido) el mando queda bloqueado: no se mueve nada del
//     fondo, no suenan los "tics" de navegación y el toque tampoco llega a la app.
//  4. Si el video falla o no arranca, se entra igualmente (nunca deja la app bloqueada).
//
//  El sonido de la intro ya va dentro del video: aquí NO se reproduce Snd.intro.
//
//  Rendimiento: la app real (Home) NO se dibuja durante casi todo el video, para que el
//  decodificador tenga la TV para él solo. Los datos (perfiles y biblioteca) sí se piden desde
//  el primer segundo; Home se monta cuando faltan ~1.5 s para acabar el video (todavía oculto
//  tras el negro), así que al terminar la intro ya está lista.
// ===========================================================================

/// Video de la intro (ruta dentro del bundle; ver pubspec.yaml → assets/video/).
/// Nota: con video_player NO lleva el prefijo "asset:///".
const _kIntroAsset = 'assets/video/Lumen_intro_4K_UHD.mp4';

/// Duración del fundido final (negro → interfaz).
const _kFade = Duration(milliseconds: 1100);

/// Si el video no llega a arrancar en este tiempo, se salta la intro.
const _kStartTimeout = Duration(seconds: 6);

/// Cuánto se espera como máximo a que cargue la app DESPUÉS de acabar el video.
const _kMaxWait = Duration(seconds: 8);

/// Cuánto antes de acabar el video se monta la app (Home) por debajo.
const _kMountAhead = Duration(milliseconds: 1500);

class TvIntroGate extends ConsumerStatefulWidget {
  const TvIntroGate({super.key, required this.child});

  /// La app (Home), que se monta al final del video.
  final Widget child;

  @override
  ConsumerState<TvIntroGate> createState() => _TvIntroGateState();
}

class _TvIntroGateState extends ConsumerState<TvIntroGate>
    with SingleTickerProviderStateMixin {
  // mixWithOthers: la intro no pelea por el foco de audio con el resto de sonidos de la app.
  late final VideoPlayerController _video = VideoPlayerController.asset(
    _kIntroAsset,
    videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
  );
  late final AnimationController _exit =
      AnimationController(vsync: this, duration: _kFade);

  /// Recoge TODAS las teclas mientras la intro está en pantalla.
  final FocusNode _blocker = FocusNode(debugLabel: 'TvIntroBlocker');

  Timer? _startWatchdog, _endGuard, _maxWait;

  bool _started = false; // el video ya avanzó (hay imagen)
  bool _ended = false; // terminó (o falló / no arrancó)
  bool _timedOut = false;
  bool _showApp = false; // Home ya se monta debajo
  bool _leaving = false; // fundiendo hacia la interfaz
  bool _gone = false; // ya no hay nada encima
  bool _sfxHeld = false;
  bool _playerReleased = false;

  @override
  void initState() {
    super.initState();
    // Los "tics" de navegación callan mientras dure la intro.
    Sfx.pushPlayer();
    _sfxHeld = true;

    _blocker.addListener(_regrabFocus);
    // Por si algo de la app de debajo pidió el foco en el primer fotograma.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_gone) _blocker.requestFocus();
    });

    _video.addListener(_onVideo);

    _startWatchdog = Timer(_kStartTimeout, () {
      if (!_started) _videoEnded();
    });
    _play();
  }

  Future<void> _play() async {
    try {
      await _video.initialize();
      if (!mounted || _playerReleased) return;
      await _video.setLooping(false);
      await _video.play();
      if (!mounted || _playerReleased) return;
      setState(() {}); // ya hay textura: se dibuja el video
      // Red de seguridad: si por lo que sea nunca avisa del final, se sale igualmente.
      final d = _video.value.duration;
      if (d > Duration.zero) {
        _endGuard = Timer(d + const Duration(seconds: 3), _videoEnded);
      }
    } catch (e) {
      debugPrint('TvIntro: no se pudo abrir el video: $e');
      _videoEnded();
    }
  }

  void _onVideo() {
    if (!mounted || _playerReleased || _ended) return;
    final v = _video.value;
    if (v.hasError) {
      debugPrint('TvIntro: error del reproductor: ${v.errorDescription}');
      _videoEnded();
      return;
    }
    if (!v.isInitialized) return;

    if (!_started && v.position > Duration.zero) {
      _started = true;
      _startWatchdog?.cancel();
    }

    final hasDur = v.duration > Duration.zero;
    // Faltan ~1.5 s: se monta Home (aún oculto tras el video, que acaba en negro).
    if (!_showApp && hasDur && v.duration - v.position <= _kMountAhead) {
      setState(() => _showApp = true);
    }
    if (v.isCompleted || (hasDur && v.position >= v.duration)) {
      _videoEnded();
    }
  }

  void _videoEnded() {
    if (_ended || !mounted) return;
    _startWatchdog?.cancel();
    _endGuard?.cancel();
    setState(() {
      _ended = true;
      _showApp = true;
    });
    // Espera de carga: a partir de aquí, 8 s como mucho antes de entrar igualmente.
    _maxWait = Timer(_kMaxWait, () {
      if (mounted) setState(() => _timedOut = true);
    });
  }

  /// Si la app de debajo le quita el foco al bloqueo, se lo recupera enseguida.
  void _regrabFocus() {
    if (_gone || !mounted || _blocker.hasPrimaryFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_gone && !_blocker.hasPrimaryFocus) {
        _blocker.requestFocus();
      }
    });
  }

  /// ¿Ya está lista la app que hay debajo? (mismo criterio que splash.dart)
  bool _appReady() {
    if (_timedOut) return true;
    if (ref.watch(sessionProvider) == null)
      return true; // pantalla de emparejar
    if (ref.watch(serverOfflineProvider)) return true; // modo sin conexión
    final profiles = ref.watch(profilesProvider);
    final library = ref.watch(libraryProvider);
    return !profiles.isLoading && !library.isLoading;
  }

  void _leave() {
    if (_leaving || !mounted) return;
    _leaving = true;
    _maxWait?.cancel();
    // El video acaba en negro: se quita la textura y el fundido sigue sobre negro puro.
    setState(() {});
    _exit.forward().whenComplete(() {
      if (!mounted) return;
      setState(() => _gone = true); // quita el bloqueo y el overlay
      WidgetsBinding.instance.addPostFrameCallback((_) => _releaseAll());
    });
  }

  void _releaseAll() {
    // El bloqueo de la intro tenía el foco; al quitarse, el foco quedaba sobre una zona sin
    // ningún botón (sin aro y con la navegación a medias). Se devuelve al botón Reanudar.
    // Un fotograma más tarde: el nodo del bloqueo ya está desmontado del todo.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      tvHomeResetFocus?.call();
    });
    WidgetsBinding.instance.scheduleFrame();
    if (_sfxHeld) {
      _sfxHeld = false;
      Sfx.popPlayer();
    }
    _releasePlayer();
  }

  /// Libera el decodificador: ya no hace falta.
  void _releasePlayer() {
    if (_playerReleased) return;
    _playerReleased = true;
    _video.removeListener(_onVideo);
    unawaited(_video.dispose());
  }

  @override
  void dispose() {
    _startWatchdog?.cancel();
    _endGuard?.cancel();
    _maxWait?.cancel();
    _blocker.removeListener(_regrabFocus);
    _blocker.dispose();
    _exit.dispose();
    if (_sfxHeld) {
      _sfxHeld = false;
      Sfx.popPlayer();
    }
    _releasePlayer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Los datos empiezan a cargar desde el primer segundo, aunque Home aún no esté montado.
    ref.watch(profilesProvider);
    ref.watch(libraryProvider);

    if (!_gone && _ended && !_leaving && _appReady()) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _leave());
    }
    return Stack(children: [
      if (_showApp) Positioned.fill(child: widget.child),
      if (!_gone) Positioned.fill(child: _overlay()),
    ]);
  }

  Widget _overlay() {
    // Bloqueo de entrada: este nodo tiene el foco y se come cualquier tecla del mando;
    // AbsorbPointer hace lo mismo con el toque / ratón.
    return Focus(
      focusNode: _blocker,
      autofocus: true,
      onKeyEvent: (_, __) => KeyEventResult.handled,
      child: AbsorbPointer(
        child: _leaving
            // Fundido: un velo negro cuya opacidad baja (barato: sin capas ni textura).
            // El video acaba en negro, así que el cambio de textura a velo no se nota.
            ? AnimatedBuilder(
                animation: _exit,
                builder: (_, __) {
                  final v = Curves.easeInOut.transform(_exit.value);
                  return ColoredBox(
                      color: Colors.black.withOpacity((1 - v).clamp(0.0, 1.0)));
                },
              )
            : ColoredBox(
                color: Colors.black,
                child: _video.value.isInitialized
                    ? Center(
                        child: AspectRatio(
                          aspectRatio: _video.value.aspectRatio,
                          child: VideoPlayer(_video),
                        ),
                      )
                    : const SizedBox.expand(),
              ),
      ),
    );
  }
}
