import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

const _red = Color(0xFFE50914);

/// Volumen máximo del reproductor. En mpv 100 = volumen original, así que 150 es un 50 % más
/// fuerte que el original (como el "extra" de VLC).
const kMaxVolume = 150.0;

/// Volumen al que arranca el reproductor si no hay uno guardado.
const kDefaultVolume = 100.0;

String _fmtTime(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  if (d.isNegative) d = Duration.zero;
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

bool get _isMobile => Platform.isAndroid || Platform.isIOS;

/// Secciones del menú de pistas (mismo orden que en main.dart).
const int kMenuAudio = 0, kMenuSubs = 1, kMenuQuality = 2;

/// Abre el menú de pistas en la sección indicada ([kMenuAudio], [kMenuSubs] o [kMenuQuality]).
/// Si devuelve un Future, los controles esperan a que se cierre el menú.
typedef PlayerMenuOpener = FutureOr<void> Function(int section);

/// Controles del reproductor: barra superior, botones centrales (móvil), barra de progreso con
/// búfer y vista previa del tiempo, volumen con extra hasta [kMaxVolume] %, velocidad, menú de
/// pistas, gestos (doble toque para saltar 10 s, deslizar a la derecha para el volumen) y
/// atajos de teclado en escritorio.
class PlayerControls extends StatefulWidget {
  const PlayerControls({
    super.key,
    required this.player,
    required this.title,
    required this.onBack,
    required this.onMenu,
    this.qualityAvailable = true,
    this.subtitle,
    this.onPip,
    this.onVolumeChanged,
    this.videoState,
    this.onParty,
    this.partyActive = false,
    this.tv = false,
    this.skip,
  });

  final Player player;
  final String title;
  final String? subtitle;
  final VoidCallback onBack;
  final PlayerMenuOpener onMenu;

  /// Hay sección de calidad (no la hay en una descarga). Solo afecta al botón de TV.
  final bool qualityAvailable;
  final VoidCallback? onPip;

  /// Se llama cuando el usuario cambia el volumen (para recordarlo entre videos).
  final ValueChanged<double>? onVolumeChanged;

  /// Para el botón de pantalla completa en escritorio.
  final VideoState? videoState;

  /// Abre "Ver juntos" (null = no disponible). [partyActive]: ya se está en una sala.
  final VoidCallback? onParty;
  final bool partyActive;

  /// Modo TV: se maneja con el mando (ver [_PlayerControlsState._onTvKey]).
  final bool tv;

  /// Botón "Saltar intro / Siguiente episodio" (solo TV: va dentro del foco del reproductor
  /// para poder llegar a él con el mando). null = no hay.
  final Widget? skip;

  @override
  State<PlayerControls> createState() => _PlayerControlsState();
}

class _Hud {
  const _Hud(this.icon, this.text, {this.color = Colors.white, this.bar});
  final IconData icon;
  final String text;
  final Color color;

  /// 0..1 si se quiere dibujar una barrita bajo el texto (volumen).
  final double? bar;
}

class _PlayerControlsState extends State<PlayerControls> {
  Player get _p => widget.player;

  bool _visible = true;
  Timer? _hideTimer;
  StreamSubscription<bool>? _playingSub;
  _Hud? _hud;
  Timer? _hudTimer;
  bool _showRemaining = false;
  double _beforeMute = kDefaultVolume;
  final _focus = FocusNode();
  final _playNode = FocusNode(); // botón de pausa (TV)
  final _ccNode = FocusNode(); // botón de subtítulos (TV): a donde va el foco con ▼
  final _audioNode = FocusNode();
  final _qualNode = FocusNode();
  final _speedNode = FocusNode();
  final _partyNode = FocusNode();

  /// Botones de la fila de TV, de izquierda a derecha (solo los que existen).
  List<FocusNode> get _tvButtons => [
        _playNode,
        _ccNode,
        _audioNode,
        if (widget.qualityAvailable) _qualNode,
        _speedNode,
        if (widget.onParty != null) _partyNode,
      ];
  final _skipNode = FocusNode(); // envuelve el botón de saltar (TV)
  DateTime _tvRepeat = DateTime(0);
  bool _menuOpen = false; // el panel de pistas está abierto: los controles no se ocultan

  // Barra de progreso con el mando (TV): ◀ ▶ mueven un destino con pasos que se agrandan al
  // insistir (10 s, 30 s, 1 min...); se salta a él al dejar de pulsar o con OK.
  Duration? _scrubTarget; // destino mostrado en la barra (null = no se está moviendo)
  Duration _scrubOrigin = Duration.zero;
  bool _scrubPending = false; // hay un destino sin aplicar todavía
  int _scrubSteps = 0;
  DateTime _scrubLast = DateTime(0);
  Timer? _scrubTimer;
  Timer? _scrubSettle;

  // Doble toque con acumulación (móvil): tras el primer doble toque, cada toque extra en el
  // mismo lado suma otros 10 s mientras no pasen más de [_chainWindow] entre toques.
  static const _doubleTapWindow = Duration(milliseconds: 300);
  static const _chainWindow = Duration(milliseconds: 700);
  static const _chainStepSeconds = 10;
  bool? _chainLeft; // lado de la cadena activa (null = no hay cadena)
  Duration? _chainTarget; // posición objetivo acumulada
  int _chainSeconds = 0; // segundos acumulados (para el mensaje)
  Timer? _chainTimer;
  bool? _pendingLeft; // primer toque esperando un posible segundo
  Timer? _pendingTimer;

  @override
  void initState() {
    super.initState();
    _showRemaining = widget.tv; // en TV se ve lo que falta, como en las apps de streaming
    _focus.addListener(_onFocusChanged);
    _playingSub = _p.stream.playing.listen((playing) {
      if (!mounted) return;
      if (playing) {
        _scheduleHide();
      } else {
        _hideTimer?.cancel();
        setState(() => _visible = true);
      }
    });
    _scheduleHide();
  }

  @override
  void didUpdateWidget(PlayerControls old) {
    super.didUpdateWidget(old);
    // Si el botón de saltar desaparece con el foco encima, el foco vuelve al reproductor.
    if (old.skip != null && widget.skip == null && _skipNode.hasFocus) {
      _focus.requestFocus();
    }
  }

  void _onFocusChanged() {
    // La barra de progreso se resalta cuando el foco está en el reproductor (TV).
    if (mounted && widget.tv) setState(() {});
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _scrubTimer?.cancel();
    _scrubSettle?.cancel();
    _ccNode.dispose();
    _audioNode.dispose();
    _qualNode.dispose();
    _speedNode.dispose();
    _partyNode.dispose();
    _hideTimer?.cancel();
    _hudTimer?.cancel();
    _chainTimer?.cancel();
    _pendingTimer?.cancel();
    _playingSub?.cancel();
    _focus.dispose();
    _playNode.dispose();
    _skipNode.dispose();
    super.dispose();
  }

  // ---------- visibilidad ----------
  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_p.state.playing) return;
    _hideTimer = Timer(Duration(seconds: widget.tv ? 8 : 3), () {
      if (!mounted || _menuOpen) return;
      // TV: el foco vuelve al reproductor (no se queda en un botón que ya no se ve).
      if (widget.tv && !_skipNode.hasFocus) _focus.requestFocus();
      setState(() => _visible = false);
    });
  }

  void _show() {
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  void _toggleVisible() {
    if (_visible && _p.state.playing) {
      _hideTimer?.cancel();
      setState(() => _visible = false);
    } else {
      _show();
    }
  }

  // ---------- acciones ----------
  void _flash(_Hud hud) {
    _hudTimer?.cancel();
    setState(() => _hud = hud);
    _hudTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _hud = null);
    });
  }

  void _seekBy(int seconds, {bool hud = true}) {
    final dur = _p.state.duration;
    var t = _p.state.position + Duration(seconds: seconds);
    if (t < Duration.zero) t = Duration.zero;
    if (dur > Duration.zero && t > dur) t = dur;
    _p.seek(t);
    if (hud) {
      _flash(_Hud(seconds < 0 ? Icons.fast_rewind : Icons.fast_forward,
          '${seconds < 0 ? '−' : '+'}${seconds.abs()} s'));
    }
    _scheduleHide();
  }

  void _setVolume(double v, {bool hud = false, bool persist = true}) {
    v = v.clamp(0.0, kMaxVolume).toDouble();
    _p.setVolume(v);
    if (persist) widget.onVolumeChanged?.call(v);
    if (hud) {
      _flash(_Hud(
          v == 0
              ? Icons.volume_off
              : v > 100
                  ? Icons.volume_up
                  : v > 40
                      ? Icons.volume_down
                      : Icons.volume_mute,
          'Volumen ${v.round()} %',
          color: v > 100 ? Colors.orangeAccent : Colors.white,
          bar: v / kMaxVolume));
    }
    _scheduleHide();
  }

  void _toggleMute() {
    final v = _p.state.volume;
    if (v > 0) {
      _beforeMute = v;
      _p.setVolume(0); // silenciar no cambia el volumen recordado
    } else {
      _p.setVolume(_beforeMute > 0 ? _beforeMute : kDefaultVolume);
    }
    _scheduleHide();
  }

  void _setRate(double r) {
    _p.setRate(r);
    _flash(_Hud(Icons.speed, 'Velocidad ${_rateLabel(r)}'));
  }

  static String _rateLabel(double r) =>
      '${r == r.roundToDouble() ? r.toInt() : r}×';

  Future<void> _toggleFullscreen() async {
    final s = widget.videoState;
    if (s == null || _isMobile) return;
    await s.toggleFullscreen();
  }

  // ---------- gestos ----------
  void _onTap() {
    if (_isMobile) {
      _toggleVisible();
    } else {
      _p.playOrPause(); // como VLC / YouTube en escritorio
      _show();
    }
  }

  void _onDoubleTap(bool left) {
    // Solo escritorio: en móvil el doble toque lo maneja _onZoneTap.
    _toggleFullscreen();
  }

  /// Móvil: toque en la zona izquierda/derecha. Detecta el doble toque y, una vez iniciado,
  /// cada toque adicional en el mismo lado acumula otros 10 s (+10, +20, +30...).
  void _onZoneTap(bool left) {
    // Cadena activa en este lado: cada toque suma.
    if (_chainLeft == left) {
      _chainStep(left);
      return;
    }
    // Toque en el otro lado: se cierra la cadena anterior y se trata como toque nuevo.
    _endChain();

    // Segundo toque rápido en el mismo lado: empieza la cadena.
    if (_pendingLeft == left) {
      _pendingTimer?.cancel();
      _pendingLeft = null;
      _chainStep(left);
      return;
    }

    // Primer toque: si no llega un segundo a tiempo, es un toque simple.
    _pendingTimer?.cancel();
    _pendingLeft = left;
    _pendingTimer = Timer(_doubleTapWindow, () {
      _pendingLeft = null;
      _onTap();
    });
  }

  void _chainStep(bool left) {
    final dur = _p.state.duration;
    // Se acumula sobre el objetivo anterior (no sobre la posición actual, que aún puede
    // estar buscando), así los toques rápidos no se pierden.
    var t = (_chainTarget ?? _p.state.position) +
        Duration(seconds: left ? -_chainStepSeconds : _chainStepSeconds);
    if (t < Duration.zero) t = Duration.zero;
    if (dur > Duration.zero && t > dur) t = dur;

    _chainLeft = left;
    _chainTarget = t;
    _chainSeconds += _chainStepSeconds;
    _p.seek(t);

    _flash(_Hud(left ? Icons.fast_rewind : Icons.fast_forward,
        '${left ? '−' : '+'}$_chainSeconds s'));
    _chainTimer?.cancel();
    _chainTimer = Timer(_chainWindow, _endChain);
    _scheduleHide();
  }

  void _endChain() {
    _chainTimer?.cancel();
    _chainLeft = null;
    _chainTarget = null;
    _chainSeconds = 0;
  }

  // ---------- mando de TV ----------
  /// Mapa del mando (todo con la menor cantidad de pulsaciones):
  ///
  /// Foco en el reproductor (por defecto; la barra de progreso se resalta si se ve):
  ///   OK        pausa / reanuda (si hay un salto sin aplicar, lo aplica al momento)
  ///   ◀ ▶       mueven la barra: 10 s, luego 30 s, 1 min... al insistir o mantener pulsado
  ///   ▼         baja a los botones (Subtítulos primero); con "Saltar" en pantalla, primero a él
  ///   ▲         enseña los controles
  /// Foco en un botón: ◀ ▶ entre botones, OK pulsa, ▲ vuelve a la barra.
  /// Atajos que valen desde cualquier sitio: Menú / Ajustes / CC / rojo → Subtítulos;
  /// Audio / verde → Audio; amarillo → Calidad.
  /// Devuelve null si la tecla no es cosa suya (el sistema mueve el foco o pulsa).
  KeyEventResult? _onTvKey(KeyEvent e) {
    final k = e.logicalKey;
    final first = e is KeyDownEvent;
    final onSkip = _skipNode.hasFocus;
    final onPlayer = _focus.hasPrimaryFocus;

    final section = _menuKey(k);
    if (section != null) {
      if (first) _openMenu(section);
      return KeyEventResult.handled;
    }

    // Foco en un botón de los controles.
    if (!onPlayer && !onSkip) {
      _show(); // cada tecla reinicia la cuenta atrás para ocultar los controles
      if (k == LogicalKeyboardKey.arrowUp) {
        if (first) _focus.requestFocus();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowDown) return KeyEventResult.handled;
      if (k == LogicalKeyboardKey.arrowLeft ||
          k == LogicalKeyboardKey.arrowRight) {
        // Orden explícito (no por geometría): el foco nunca se escapa de la fila.
        final nodes = _tvButtons;
        final i = nodes.indexWhere((n) => n.hasPrimaryFocus);
        if (i >= 0 && first) {
          final j = i + (k == LogicalKeyboardKey.arrowLeft ? -1 : 1);
          if (j >= 0 && j < nodes.length) nodes[j].requestFocus();
        }
        return KeyEventResult.handled;
      }
      return null;
    }

    final select = k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.gameButtonA;
    if (onSkip) {
      // En "Saltar": OK lo pulsa, ▼ sigue hacia los botones; el resto devuelve el foco al
      // reproductor y actúa como si no hubiera botón.
      if (select) return null;
      if (k == LogicalKeyboardKey.arrowDown) {
        if (first) _tvToButtons();
        return KeyEventResult.handled;
      }
      _focus.requestFocus();
    }

    if (select) {
      if (first) {
        if (_scrubPending) {
          _commitScrub();
          _show();
        } else {
          _tvPlayPause();
        }
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
      // Con la tecla mantenida llegan muchos eventos: se limita a uno cada 150 ms.
      if (!first) {
        final now = DateTime.now();
        if (now.difference(_tvRepeat) < const Duration(milliseconds: 150)) {
          return KeyEventResult.handled;
        }
        _tvRepeat = now;
      }
      _scrub(k == LogicalKeyboardKey.arrowLeft);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      if (first) {
        if (widget.skip != null && !onSkip) {
          _focusSkip();
        } else {
          _tvToButtons();
        }
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      if (first) _show();
      return KeyEventResult.handled;
    }
    return null;
  }

  /// Tecla de acceso directo a una sección del menú de pistas (null = no es ninguna).
  int? _menuKey(LogicalKeyboardKey k) {
    if (k == LogicalKeyboardKey.contextMenu ||
        k == LogicalKeyboardKey.settings ||
        k == LogicalKeyboardKey.closedCaptionToggle ||
        k == LogicalKeyboardKey.colorF0Red) {
      return kMenuSubs;
    }
    if (k == LogicalKeyboardKey.mediaAudioTrack ||
        k == LogicalKeyboardKey.colorF1Green) {
      return kMenuAudio;
    }
    if (k == LogicalKeyboardKey.colorF2Yellow && widget.qualityAvailable) {
      return kMenuQuality;
    }
    return null;
  }

  void _tvPlayPause() {
    final was = _p.state.playing;
    _p.playOrPause();
    _flash(_Hud(was ? Icons.pause_rounded : Icons.play_arrow_rounded,
        was ? 'Pausa' : 'Reproducir'));
    _show();
  }

  // ---------- barra de progreso con el mando ----------
  static const _scrubCommitAfter = Duration(milliseconds: 500);

  static String _fmtDelta(int s) =>
      s < 60 ? '$s s' : '${s ~/ 60} min${s % 60 == 0 ? '' : ' ${s % 60} s'}';

  /// Mueve el destino: los pasos crecen mientras se insiste (10 s los 3 primeros, luego 30 s,
  /// 1 min y 2 min), y se reinician si se deja de pulsar un momento. El salto real se hace al
  /// dejar de pulsar (o con OK), no en cada pulsación: así no se satura al reproductor.
  void _scrub(bool left) {
    final now = DateTime.now();
    if (now.difference(_scrubLast) > const Duration(milliseconds: 900)) {
      _scrubSteps = 0;
    }
    _scrubLast = now;
    final n = _scrubSteps++;
    final dur = _p.state.duration;
    final big = dur >= const Duration(minutes: 40) ? 120 : 60;
    final step = n < 3 ? 10 : (n < 8 ? 30 : (n < 16 ? 60 : big));

    _scrubSettle?.cancel();
    if (_scrubTarget == null) _scrubOrigin = _p.state.position;
    var t = (_scrubTarget ?? _p.state.position) +
        Duration(seconds: left ? -step : step);
    if (t < Duration.zero) t = Duration.zero;
    if (dur > Duration.zero && t > dur) t = dur;
    _scrubTarget = t;
    _scrubPending = true;
    _scrubTimer?.cancel();
    _scrubTimer = Timer(_scrubCommitAfter, _commitScrub);

    final delta = (t - _scrubOrigin).inSeconds;
    _flash(_Hud(left ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
        '${delta < 0 ? '−' : '+'}${_fmtDelta(delta.abs())}'));
    _show();
  }

  void _commitScrub() {
    _scrubTimer?.cancel();
    final t = _scrubTarget;
    if (t == null || !_scrubPending) return;
    _scrubPending = false;
    _p.seek(t);
    // El destino se queda un instante en la barra para que el asa no salte atrás mientras el
    // reproductor llega a la nueva posición.
    _scrubSettle?.cancel();
    _scrubSettle = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _scrubTarget = null);
    });
    _scheduleHide();
  }

  // ---------- menú de pistas ----------
  Future<void> _openMenu(int section) async {
    if (!widget.tv) {
      widget.onMenu(section);
      return;
    }
    if (_menuOpen) return;
    final origin = FocusManager.instance.primaryFocus;
    _hideTimer?.cancel();
    setState(() => _menuOpen = true);
    try {
      await widget.onMenu(section);
    } finally {
      if (mounted) {
        setState(() => _menuOpen = false);
        _show();
        // Al cerrar el panel el foco vuelve a donde estaba (el botón o el reproductor).
        if (origin != null && origin.canRequestFocus && origin.context != null) {
          origin.requestFocus();
        } else {
          _focus.requestFocus();
        }
      }
    }
  }

  /// Baja del reproductor a la fila de botones (con el foco en Subtítulos).
  void _tvToButtons() {
    final was = _visible;
    _show();
    if (was) {
      _ccNode.requestFocus();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ccNode.requestFocus();
      });
    }
  }

  void _focusSkip() {
    for (final n in _skipNode.traversalDescendants) {
      n.requestFocus();
      return;
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent)
      return KeyEventResult.ignored;
    final k = e.logicalKey;
    final first = e is KeyDownEvent;
    // Teclas multimedia (mando de TV, auriculares, teclados con teclas multimedia).
    if (k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.mediaPlay ||
        k == LogicalKeyboardKey.mediaPause) {
      if (first) {
        if (k == LogicalKeyboardKey.mediaPlay) {
          _p.play();
        } else if (k == LogicalKeyboardKey.mediaPause) {
          _p.pause();
        } else {
          _p.playOrPause();
        }
        _show();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaFastForward ||
        k == LogicalKeyboardKey.mediaRewind) {
      if (first) {
        if (widget.tv) {
          _scrub(k == LogicalKeyboardKey.mediaRewind);
        } else {
          _chainStep(k == LogicalKeyboardKey.mediaRewind);
        }
      }
      return KeyEventResult.handled;
    }
    if (widget.tv) return _onTvKey(e) ?? KeyEventResult.ignored;
    if ((k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.keyK) &&
        first) {
      _p.playOrPause();
      _show();
    } else if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.keyJ) {
      _seekBy(HardwareKeyboard.instance.isShiftPressed ? -30 : -10);
    } else if (k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.keyL) {
      _seekBy(HardwareKeyboard.instance.isShiftPressed ? 30 : 10);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _setVolume(_p.state.volume + 5, hud: true);
    } else if (k == LogicalKeyboardKey.arrowDown) {
      _setVolume(_p.state.volume - 5, hud: true);
    } else if (k == LogicalKeyboardKey.keyM && first) {
      final wasMuted = _p.state.volume == 0;
      _toggleMute();
      _flash(wasMuted
          ? _Hud(Icons.volume_up,
              'Volumen ${_p.state.volume > 0 ? _p.state.volume.round() : _beforeMute.round()} %')
          : const _Hud(Icons.volume_off, 'Silenciado'));
    } else if (k == LogicalKeyboardKey.keyF && first) {
      _toggleFullscreen();
    } else if (k == LogicalKeyboardKey.escape && first) {
      final s = widget.videoState;
      if (s != null && s.isFullscreen()) {
        s.exitFullscreen();
      } else {
        widget.onBack();
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ---------- construcción ----------
  @override
  Widget build(BuildContext context) {
    final mobile = _isMobile || widget.tv;
    final hideCursor = !mobile && !_visible && _p.state.playing;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      skipTraversal: true, // si no, las flechas lo elegían como destino (ocupa toda la pantalla)
      onKeyEvent: _onKey,
      child: MouseRegion(
        cursor: hideCursor ? SystemMouseCursors.none : MouseCursor.defer,
        onHover: mobile ? null : (_) => _show(),
        child: Stack(children: [
          // Zonas de gesto (izquierda / derecha), por debajo de los controles.
          Positioned.fill(
            child: Row(children: [
              for (final left in const [true, false])
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: mobile ? () => _onZoneTap(left) : _onTap,
                    // En móvil el doble toque se detecta a mano (ver _onZoneTap).
                    onDoubleTap: mobile ? null : () => _onDoubleTap(left),
                  ),
                ),
            ]),
          ),

          // Controles (se ocultan solos a los 3 s mientras se reproduce).
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_visible,
              // TV: con los controles ocultos no se puede enfocar nada de ellos.
              child: ExcludeFocus(
                excluding: widget.tv && !_visible,
                child: AnimatedOpacity(
                opacity: _visible ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: Stack(children: [
                  Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: IgnorePointer(
                          child: _Scrim(
                              height: widget.tv ? 150 : 120, fromTop: true))),
                  Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: IgnorePointer(
                          child: _Scrim(
                              height: widget.tv ? 280 : 190, fromTop: false))),
                  Positioned(top: 0, left: 0, right: 0, child: _topBar()),
                  // En TV no hay botones centrales: OK pausa y ◀ ▶ saltan sin buscar botones.
                  if (mobile && !widget.tv) Center(child: _centerControls()),
                  Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: widget.tv ? _tvBottomBar() : _bottomBar()),
                ]),
              ),
              ),
            ),
          ),

          // Botón "Saltar intro / Siguiente episodio" (TV): dentro del foco del reproductor.
          if (widget.skip != null)
            Positioned(
                right: widget.tv ? 48 : 24,
                bottom: widget.tv ? 190 : 112,
                child: Focus(
                    focusNode: _skipNode,
                    canRequestFocus: false,
                    skipTraversal: true,
                    child: widget.skip!)),

          // Indicador de carga (aunque los controles estén ocultos).
          Center(
            child: IgnorePointer(
              child: StreamBuilder<bool>(
                stream: _p.stream.buffering,
                initialData: _p.state.buffering,
                builder: (_, s) => AnimatedOpacity(
                  opacity: (s.data ?? false) ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: const SizedBox(
                      width: 46,
                      height: 46,
                      child: CircularProgressIndicator(
                          strokeWidth: 3.5, color: Color(0xFFE50914))),
                ),
              ),
            ),
          ),

          // Mensaje flotante (saltos, volumen, velocidad).
          Align(
            alignment: const Alignment(0, -0.55),
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _hud == null ? 0 : 1,
                duration: const Duration(milliseconds: 150),
                child: _hud == null ? const SizedBox.shrink() : _hudPill(_hud!),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _hudPill(_Hud h) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.72),
            borderRadius: BorderRadius.circular(28)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(h.icon, color: h.color, size: 22),
            const SizedBox(width: 10),
            Text(h.text,
                style: TextStyle(
                    color: h.color, fontSize: 15, fontWeight: FontWeight.w600)),
          ]),
          if (h.bar != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: 150,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                    value: h.bar,
                    minHeight: 4,
                    color: h.color,
                    backgroundColor: Colors.white24),
              ),
            ),
          ],
        ]),
      );

  // ---------- barra superior ----------
  Widget _topBar() {
    if (widget.tv) return _tvTopBar();
    final mobile = _isMobile || widget.tv;
    return Padding(
      padding: EdgeInsets.fromLTRB(8, mobile ? 10 : 12, 8, 0),
      child: Row(children: [
        IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                color: Colors.white, size: 22),
            tooltip: 'Volver',
            onPressed: widget.onBack),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700)),
                if (widget.subtitle != null)
                  Text(widget.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 13)),
              ]),
        ),
        if (widget.onPip != null)
          IconButton(
              icon: const Icon(Icons.picture_in_picture_alt_rounded,
                  color: Colors.white),
              tooltip: 'Imagen en imagen',
              onPressed: widget.onPip),
      ]),
    );
  }

  /// TV: solo el título (Atrás del mando sale; no hace falta un botón de volver que enfocar).
  Widget _tvTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 28, 48, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: Colors.white, fontSize: 26, fontWeight: FontWeight.w700)),
        if (widget.subtitle != null)
          Text(widget.subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 17)),
      ]),
    );
  }

  // ---------- botones centrales (móvil) ----------
  Widget _centerControls() {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _CircleButton(
          icon: Icons.replay_10_rounded,
          size: 30,
          diameter: 56,
          tooltip: 'Retroceder 10 s',
          onPressed: () => _seekBy(-10)),
      const SizedBox(width: 36),
      StreamBuilder<bool>(
        stream: _p.stream.playing,
        initialData: _p.state.playing,
        builder: (_, s) {
          final playing = s.data ?? false;
          return _CircleButton(
              icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 46,
              diameter: 76,
              filled: true,
              focusNode: _playNode,
              tooltip: playing ? 'Pausar' : 'Reproducir',
              onPressed: () {
                _p.playOrPause();
                _scheduleHide();
              });
        },
      ),
      const SizedBox(width: 36),
      _CircleButton(
          icon: Icons.forward_10_rounded,
          size: 30,
          diameter: 56,
          tooltip: 'Adelantar 10 s',
          onPressed: () => _seekBy(10)),
    ]);
  }

  // ---------- barra inferior ----------
  /// Tiempo transcurrido · barra de progreso · duración (o lo que falta).
  Widget _progressRow({required bool tv}) {
    final fs = tv ? 17.0 : 13.0;
    return Row(children: [
      StreamBuilder<Duration>(
        stream: _p.stream.position,
        initialData: _p.state.position,
        builder: (_, s) => SizedBox(
            width: tv ? 84 : 58,
            child: Text(_fmtTime(_scrubTarget ?? s.data ?? Duration.zero),
                style: TextStyle(
                    color: Colors.white,
                    fontSize: fs,
                    fontFeatures: const [FontFeature.tabularFigures()]))),
      ),
      Expanded(
          child: _SeekBar(
              player: _p,
              onInteract: _show,
              preview: _scrubTarget,
              tv: tv,
              active: tv && _focus.hasPrimaryFocus && _visible)),
      GestureDetector(
        onTap: () => setState(() => _showRemaining = !_showRemaining),
        child: StreamBuilder<Duration>(
          stream: _p.stream.position,
          initialData: _p.state.position,
          builder: (_, pos) => StreamBuilder<Duration>(
            stream: _p.stream.duration,
            initialData: _p.state.duration,
            builder: (_, dur) {
              final d = dur.data ?? Duration.zero;
              final left = d - (_scrubTarget ?? pos.data ?? Duration.zero);
              return SizedBox(
                  width: tv ? 100 : 64,
                  child: Text(
                      _showRemaining ? '−${_fmtTime(left)}' : _fmtTime(d),
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: fs,
                          fontFeatures: const [FontFeature.tabularFigures()])));
            },
          ),
        ),
      ),
    ]);
  }

  /// TV: barra de progreso y, debajo, una sola fila de botones con su nombre
  /// (Pausa · Subtítulos · Audio · Calidad · Velocidad · Ver juntos). Cada botón de pistas abre
  /// el panel directamente en su sección.
  Widget _tvBottomBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 0, 48, 22),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _progressRow(tv: true),
        const SizedBox(height: 6),
        Row(children: [
          StreamBuilder<bool>(
            stream: _p.stream.playing,
            initialData: _p.state.playing,
            builder: (_, s) {
              final playing = s.data ?? false;
              return _TvBtn(
                  icon: playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  label: playing ? 'Pausa' : 'Reproducir',
                  focusNode: _playNode,
                  onPressed: _tvPlayPause);
            },
          ),
          _TvBtn(
              icon: Icons.subtitles_rounded,
              label: 'Subtítulos',
              focusNode: _ccNode,
              onPressed: () => _openMenu(kMenuSubs)),
          _TvBtn(
              icon: Icons.audiotrack_rounded,
              label: 'Audio',
              focusNode: _audioNode,
              onPressed: () => _openMenu(kMenuAudio)),
          if (widget.qualityAvailable)
            _TvBtn(
                icon: Icons.high_quality_rounded,
                label: 'Calidad',
                focusNode: _qualNode,
                onPressed: () => _openMenu(kMenuQuality)),
          StreamBuilder<double>(
            stream: _p.stream.rate,
            initialData: _p.state.rate,
            builder: (_, s) {
              final rate = s.data ?? 1.0;
              final normal = (rate - 1).abs() < 0.01;
              return _TvBtn(
                  icon: Icons.speed_rounded,
                  label: normal ? 'Velocidad' : _rateLabel(rate),
                  accent: !normal,
                  focusNode: _speedNode,
                  onPressed: () => _cycleRate(rate));
            },
          ),
          if (widget.onParty != null)
            _TvBtn(
                icon: Icons.groups_rounded,
                label: 'Ver juntos',
                accent: widget.partyActive,
                focusNode: _partyNode,
                onPressed: widget.onParty!),
        ]),
      ]),
    );
  }

  /// TV: cada OK en el botón pasa a la siguiente velocidad (1× → 1,25× → ... → 0,75× → 1×).
  void _cycleRate(double current) {
    const order = [1.0, 1.25, 1.5, 1.75, 2.0, 0.5, 0.75];
    final i = order.indexWhere((r) => (r - current).abs() < 0.01);
    _setRate(order[(i + 1) % order.length]);
    _scheduleHide();
  }

  Widget _bottomBar() {
    final mobile = _isMobile || widget.tv;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, mobile ? 8 : 14),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _progressRow(tv: false),
        Row(children: [
          if (!mobile) ...[
            StreamBuilder<bool>(
              stream: _p.stream.playing,
              initialData: _p.state.playing,
              builder: (_, s) => IconButton(
                  icon: Icon(
                      (s.data ?? false)
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 30),
                  tooltip: (s.data ?? false)
                      ? 'Pausar (espacio)'
                      : 'Reproducir (espacio)',
                  onPressed: () {
                    _p.playOrPause();
                    _scheduleHide();
                  }),
            ),
            IconButton(
                icon: const Icon(Icons.replay_10_rounded, color: Colors.white),
                tooltip: 'Retroceder 10 s (←)',
                onPressed: () => _seekBy(-10, hud: false)),
            IconButton(
                icon: const Icon(Icons.forward_10_rounded, color: Colors.white),
                tooltip: 'Adelantar 10 s (→)',
                onPressed: () => _seekBy(10, hud: false)),
            const SizedBox(width: 4),
          ],
          _volume(),
          const Spacer(),
          _speedButton(),
          if (widget.onParty != null)
            IconButton(
                icon: Icon(Icons.groups_rounded,
                    color: widget.partyActive ? _red : Colors.white),
                tooltip: 'Ver juntos',
                onPressed: widget.onParty),
          IconButton(
              icon: const Icon(Icons.subtitles_outlined, color: Colors.white),
              tooltip: 'Calidad, audio y subtítulos',
              onPressed: () => _openMenu(kMenuSubs)),
          if (!mobile && widget.videoState != null)
            IconButton(
                icon: Icon(
                    widget.videoState!.isFullscreen()
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                    color: Colors.white,
                    size: 28),
                tooltip: 'Pantalla completa (F)',
                onPressed: _toggleFullscreen),
        ]),
      ]),
    );
  }

  Widget _volume() {
    return StreamBuilder<double>(
      stream: _p.stream.volume,
      initialData: _p.state.volume,
      builder: (_, s) {
        final v = (s.data ?? kDefaultVolume).clamp(0.0, kMaxVolume).toDouble();
        final boosted = v > 100;
        final accent = boosted ? Colors.orangeAccent : Colors.white;
        return Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
              icon: Icon(
                  v == 0
                      ? Icons.volume_off_rounded
                      : v > 100
                          ? Icons.volume_up_rounded
                          : v > 40
                              ? Icons.volume_down_rounded
                              : Icons.volume_mute_rounded,
                  color: accent),
              tooltip: 'Silenciar (M)',
              onPressed: _toggleMute),
          SizedBox(
            width: _isMobile ? 120 : 150,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3.5,
                activeTrackColor: accent,
                inactiveTrackColor: Colors.white24,
                thumbColor: accent,
                overlayColor: accent.withOpacity(0.18),
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6.5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 15),
              ),
              child: Slider(
                min: 0,
                max: kMaxVolume,
                divisions: (kMaxVolume ~/ 5),
                value: v,
                onChanged: (x) => _setVolume(x),
              ),
            ),
          ),
          SizedBox(
            width: 46,
            child: Text('${v.round()} %',
                style: TextStyle(
                    color: accent,
                    fontSize: 12.5,
                    fontWeight: boosted ? FontWeight.w700 : FontWeight.w500)),
          ),
        ]);
      },
    );
  }

  Widget _speedButton() {
    return StreamBuilder<double>(
      stream: _p.stream.rate,
      initialData: _p.state.rate,
      builder: (_, s) {
        final rate = s.data ?? 1.0;
        return PopupMenuButton<double>(
          tooltip: 'Velocidad',
          color: const Color(0xF2161616),
          onOpened: () => _hideTimer?.cancel(),
          onCanceled: _scheduleHide,
          onSelected: (r) {
            _setRate(r);
            _scheduleHide();
          },
          itemBuilder: (_) => [
            for (final r in const [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
              PopupMenuItem<double>(
                value: r,
                height: 40,
                child: Row(children: [
                  SizedBox(
                      width: 24,
                      child: (rate - r).abs() < 0.01
                          ? const Icon(Icons.check, size: 18, color: _red)
                          : null),
                  Text(r == 1.0 ? 'Normal' : _rateLabel(r),
                      style: const TextStyle(color: Colors.white)),
                ]),
              ),
          ],
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
                border: Border.all(
                    color:
                        (rate - 1).abs() < 0.01 ? Colors.white38 : Colors.white,
                    width: 1.2),
                borderRadius: BorderRadius.circular(14)),
            child: Text(_rateLabel(rate),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ),
        );
      },
    );
  }
}

class _Scrim extends StatelessWidget {
  const _Scrim({required this.height, required this.fromTop});
  final double height;
  final bool fromTop;
  @override
  Widget build(BuildContext context) => Container(
        height: height,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: fromTop ? Alignment.topCenter : Alignment.bottomCenter,
            end: fromTop ? Alignment.bottomCenter : Alignment.topCenter,
            colors: [Colors.black.withOpacity(0.78), Colors.transparent],
          ),
        ),
      );
}

/// Botón de la fila inferior en TV: icono grande con su nombre debajo y un marco blanco al
/// enfocarlo (solo con mando o teclado, no con el dedo).
class _TvBtn extends StatefulWidget {
  const _TvBtn(
      {required this.icon,
      required this.label,
      required this.onPressed,
      this.focusNode,
      this.accent = false});
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  /// Estado "activo" (velocidad distinta de normal, sala de Ver juntos abierta): icono en rojo.
  final bool accent;

  @override
  State<_TvBtn> createState() => _TvBtnState();
}

class _TvBtnState extends State<_TvBtn> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          focusNode: widget.focusNode,
          borderRadius: BorderRadius.circular(14),
          focusColor: Colors.transparent,
          onFocusChange: (f) => setState(() => _focused = f &&
              FocusManager.instance.highlightMode ==
                  FocusHighlightMode.traditional),
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: _focused ? Colors.white24 : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: _focused ? Colors.white : Colors.transparent,
                  width: 2.5),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(widget.icon,
                  size: 32, color: widget.accent ? _red : Colors.white),
              const SizedBox(height: 4),
              Text(widget.label,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: _focused ? FontWeight.w700 : FontWeight.w500,
                      color: _focused ? Colors.white : Colors.white70)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _CircleButton extends StatefulWidget {
  const _CircleButton(
      {required this.icon,
      required this.size,
      required this.diameter,
      required this.onPressed,
      this.tooltip,
      this.filled = false,
      this.focusNode});
  final IconData icon;
  final double size, diameter;
  final VoidCallback onPressed;
  final String? tooltip;
  final bool filled;
  final FocusNode? focusNode;

  @override
  State<_CircleButton> createState() => _CircleButtonState();
}

class _CircleButtonState extends State<_CircleButton> {
  bool _focused = false; // con mando o teclado (con el dedo no se pinta aro)

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip ?? '',
      child: Material(
        color: widget.filled ? Colors.black.withOpacity(0.55) : Colors.transparent,
        shape: CircleBorder(
            side: _focused
                ? const BorderSide(color: Colors.white, width: 3)
                : BorderSide.none),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          focusNode: widget.focusNode,
          onFocusChange: (f) => setState(() => _focused = f &&
              FocusManager.instance.highlightMode ==
                  FocusHighlightMode.traditional),
          onTap: widget.onPressed,
          child: SizedBox(
              width: widget.diameter,
              height: widget.diameter,
              child: Icon(widget.icon, color: Colors.white, size: widget.size)),
        ),
      ),
    );
  }
}

/// Barra de progreso con tramo almacenado (búfer), asa que crece al tocarla y burbuja con el
/// tiempo al arrastrar o pasar el ratón por encima.
class _SeekBar extends StatefulWidget {
  const _SeekBar(
      {required this.player,
      required this.onInteract,
      this.preview,
      this.tv = false,
      this.active = false});
  final Player player;
  final VoidCallback onInteract;

  /// TV: destino al que se está moviendo la barra con el mando (null = ninguno).
  final Duration? preview;

  /// TV: barra más gruesa y con el asa grande.
  final bool tv;

  /// TV: el foco está en la barra (asa con aro blanco).
  final bool active;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _drag; // 0..1 mientras se arrastra (o un instante tras soltar)
  double? _hover; // 0..1 con el ratón encima (escritorio)
  Timer? _settle;

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  double _frac(Offset local, double w) =>
      w <= 0 ? 0 : (local.dx / w).clamp(0.0, 1.0).toDouble();

  void _seek(double f) {
    final dur = widget.player.state.duration;
    if (dur <= Duration.zero) return;
    widget.player
        .seek(Duration(milliseconds: (dur.inMilliseconds * f).round()));
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    return StreamBuilder<Duration>(
      stream: p.stream.position,
      initialData: p.state.position,
      builder: (_, pos) => StreamBuilder<Duration>(
        stream: p.stream.duration,
        initialData: p.state.duration,
        builder: (_, dur) => StreamBuilder<Duration>(
          stream: p.stream.buffer,
          initialData: p.state.buffer,
          builder: (_, buf) {
            final d = dur.data ?? Duration.zero;
            double frac(Duration? x) => d.inMilliseconds <= 0 || x == null
                ? 0
                : (x.inMilliseconds / d.inMilliseconds)
                    .clamp(0.0, 1.0)
                    .toDouble();
            return LayoutBuilder(builder: (_, c) {
              final w = c.maxWidth;
              final pv = widget.preview;
              final played =
                  _drag ?? (pv != null ? frac(pv) : frac(pos.data));
              final buffered = frac(buf.data);
              final tvOn = widget.tv && widget.active;
              final active =
                  _drag != null || _hover != null || pv != null || tvOn;
              final shown = _drag ?? _hover ?? (pv != null ? played : null);
              final boxH = widget.tv ? 52.0 : 40.0;
              final trackH = widget.tv
                  ? (active ? 10.0 : 6.0)
                  : (active ? 6.0 : 4.0);
              final thumb = widget.tv
                  ? (active ? 26.0 : 16.0)
                  : (active ? 16.0 : 12.0);
              Widget bar(double f, Color color) => Positioned(
                  left: 0,
                  top: (boxH - trackH) / 2,
                  width: w * f,
                  height: trackH,
                  child: DecoratedBox(
                      decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(trackH))));
              return MouseRegion(
                cursor: SystemMouseCursors.click,
                onHover: (e) =>
                    setState(() => _hover = _frac(e.localPosition, w)),
                onExit: (_) => setState(() => _hover = null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) {
                    widget.onInteract();
                    _seek(_frac(d.localPosition, w));
                  },
                  onHorizontalDragStart: (d) {
                    _settle?.cancel();
                    widget.onInteract();
                    setState(() => _drag = _frac(d.localPosition, w));
                  },
                  onHorizontalDragUpdate: (d) {
                    widget.onInteract();
                    setState(() => _drag = _frac(d.localPosition, w));
                  },
                  onHorizontalDragEnd: (_) {
                    final f = _drag;
                    if (f != null) _seek(f);
                    // Se mantiene un instante para que el asa no salte atrás mientras el
                    // reproductor llega a la nueva posición.
                    _settle = Timer(const Duration(milliseconds: 450), () {
                      if (mounted) setState(() => _drag = null);
                    });
                  },
                  child: SizedBox(
                    height: boxH,
                    child: Stack(clipBehavior: Clip.none, children: [
                      bar(1, Colors.white24),
                      bar(buffered, Colors.white38),
                      bar(played, _red),
                      Positioned(
                        left: (w * played - thumb / 2)
                            .clamp(-thumb / 2, w - thumb / 2)
                            .toDouble(),
                        top: (boxH - thumb) / 2,
                        child: Container(
                          width: thumb,
                          height: thumb,
                          decoration: BoxDecoration(
                              color: _red,
                              shape: BoxShape.circle,
                              border: tvOn
                                  ? Border.all(color: Colors.white, width: 3)
                                  : null,
                              boxShadow: const [
                                BoxShadow(color: Colors.black45, blurRadius: 4)
                              ]),
                        ),
                      ),
                      if (shown != null && d > Duration.zero)
                        Positioned(
                          left: (w * shown - (widget.tv ? 38 : 30))
                              .clamp(0.0, w - (widget.tv ? 76 : 60))
                              .toDouble(),
                          top: widget.tv ? -34 : -22,
                          width: widget.tv ? 76 : 60,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.8),
                                  borderRadius: BorderRadius.circular(6)),
                              child: Text(
                                  _fmtTime(Duration(
                                      milliseconds:
                                          (d.inMilliseconds * shown).round())),
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: widget.tv ? 15 : 12)),
                            ),
                          ),
                        ),
                    ]),
                  ),
                ),
              );
            });
          },
        ),
      ),
    );
  }
}