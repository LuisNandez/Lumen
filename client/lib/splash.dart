import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core.dart';
import 'profiles.dart' show profilesProvider;
import 'remote.dart' show serverOfflineProvider;
import 'sounds.dart';

// ===========================================================================
//  Animación de entrada (estilo Netflix).
//
//  1. Aparece LUMEN en rojo sobre negro.
//  2. Las letras se van quitando de derecha a izquierda (N, E, M, U) hasta quedar la "L".
//  3. La "L" late suavemente MIENTRAS la app carga por debajo (perfiles y biblioteca).
//  4. Cuando todo está listo (y la animación ha terminado): suena el sonido de bienvenida,
//     la "L" se agranda y se funde con el menú de inicio.
//
//  La app real (Home) se construye debajo desde el primer momento: así carga mientras se ve
//  la animación. Si algo tarda demasiado (servidor lento), a los 8 s entra igualmente.
// ===========================================================================

const _red = Color(0xFFE50914);
const _word = 'LUMEN';

/// Cuánto dura como mucho la espera de carga antes de entrar igualmente.
const _maxWait = Duration(seconds: 8);

class SplashGate extends ConsumerStatefulWidget {
  const SplashGate({super.key, required this.child});

  /// La app (Home), que se carga debajo de la animación.
  final Widget child;

  @override
  ConsumerState<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends ConsumerState<SplashGate>
    with TickerProviderStateMixin {
  // Letras: aparece, pausa y se quitan de derecha a izquierda.
  late final AnimationController _intro = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2400));
  // Latido de la "L" mientras espera a que cargue la app.
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900));
  // Salida: la "L" se agranda y todo se funde con la app.
  late final AnimationController _exit = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 800));

  bool _introDone = false, _timedOut = false, _leaving = false, _gone = false;
  Timer? _timeout;

  @override
  void initState() {
    super.initState();
    _intro.forward().whenComplete(() {
      if (!mounted) return;
      setState(() => _introDone = true);
      _pulse.repeat(reverse: true);
    });
    _timeout = Timer(_maxWait, () {
      if (!mounted) return;
      setState(() => _timedOut = true);
    });
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _intro.dispose();
    _pulse.dispose();
    _exit.dispose();
    super.dispose();
  }

  /// ¿Ya está lista la app que hay debajo?
  bool _appReady() {
    if (_timedOut) return true;
    if (ref.watch(sessionProvider) == null) return true; // pantalla de emparejar
    if (ref.watch(serverOfflineProvider)) return true; // modo sin conexión
    final profiles = ref.watch(profilesProvider);
    final library = ref.watch(libraryProvider);
    return !profiles.isLoading && !library.isLoading;
  }

  void _leave() {
    if (_leaving || !mounted) return;
    _leaving = true;
    _pulse.stop();
    Sfx.play(Snd.intro, force: true); // el sonido de bienvenida suena AHORA
    _exit.forward().whenComplete(() {
      if (mounted) setState(() => _gone = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_gone && _appReady() && _introDone && !_leaving) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _leave());
    }
    return Stack(children: [
      Positioned.fill(child: widget.child),
      if (!_gone) Positioned.fill(child: _overlay(context)),
    ]);
  }

  Widget _overlay(BuildContext context) {
    final size =
        (MediaQuery.sizeOf(context).shortestSide * 0.16).clamp(56.0, 120.0);
    final style = TextStyle(
      color: _red,
      fontSize: size,
      fontWeight: FontWeight.w900,
      height: 1,
      shadows: const [Shadow(color: Color(0x66E50914), blurRadius: 28)],
    );
    return AbsorbPointer(
      child: AnimatedBuilder(
        animation: Listenable.merge([_intro, _pulse, _exit]),
        builder: (_, __) {
          final t = _intro.value;
          // Aparición suave del logo.
          final fade = const Interval(0, 0.25, curve: Curves.easeOut)
              .transform(t)
              .clamp(0.0, 1.0);
          final appear = 0.92 + 0.08 * fade;
          // Latido de la L ya sola.
          final beat = _introDone && !_leaving ? _pulse.value : 0.0;
          // Salida.
          final e = _exit.value;
          final zoom = 1 + 11 * Curves.easeInCubic.transform(e);
          final overlay =
              1 - const Interval(0.4, 1, curve: Curves.easeIn).transform(e);

          final letters = <Widget>[];
          for (var i = 0; i < _word.length; i++) {
            var f = 1.0; // 1 = visible, 0 = quitada
            if (i > 0) {
              // N se quita primero, luego E, M y U.
              final k = _word.length - 1 - i;
              final start = 0.45 + k * 0.09;
              f = 1 -
                  Interval(start, start + 0.14, curve: Curves.easeInCubic)
                      .transform(t);
            }
            letters.add(ClipRect(
              child: Align(
                alignment: Alignment.center,
                widthFactor: f,
                child: Opacity(
                  opacity: f.clamp(0.0, 1.0),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: size * 0.05),
                    child: Text(_word[i], style: style),
                  ),
                ),
              ),
            ));
          }

          return Opacity(
            opacity: overlay.clamp(0.0, 1.0),
            child: Material(
              color: Colors.black,
              child: Center(
                child: Opacity(
                  opacity: (fade * (0.82 + 0.18 * beat)).clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: appear * (1 + 0.04 * beat) * zoom,
                    child: Row(
                        mainAxisSize: MainAxisSize.min, children: letters),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
