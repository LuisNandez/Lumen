import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'native.dart';
import 'sounds.dart';

// ===========================================================================
//  Modo TV (Android TV / Google TV / TV box con mando a distancia).
//
//  - Se detecta al arrancar (NativeBridge.isTv) y es el mismo cliente: no hay una app aparte.
//    Para probarlo en un móvil o en el escritorio: flutter run --dart-define=TV=true
//  - En modo TV: foco bien visible, texto algo mayor y navegación lateral (shell.dart).
//  - El mando mueve el foco con las flechas y OK activa (Flutter ya lo traduce); aquí se
//    hace que ese foco se VEA desde el sofá y que lo que no es un botón también se pueda enfocar.
// ===========================================================================

const _forceTv = bool.fromEnvironment('TV');

/// Se llama una vez en main() antes de arrancar la app.
Future<bool> detectTv() async => _forceTv || await NativeBridge.isTv();

/// ¿Estamos en una TV? Se fija en main() con el resultado de [detectTv].
final tvModeProvider = Provider<bool>((ref) => false);

const kFocusRing = Colors.white;

/// Grosor del aro de foco. Antes eran 3 px (pesado, "de recuadro"); con 2 px más el halo y la
/// elevación de abajo se sigue viendo desde el sofá, pero se siente más fino y cuidado.
const double kFocusWidth = 2;

/// Color de acento de la app (el rojo de LUMEN).
const kFocusAccent = Color(0xFFE50914);

/// Curva y duración comunes de todas las animaciones de foco (rápidas al entrar, suaves al frenar).
const Curve kFocusCurve = Curves.easeOutCubic;
const Duration kFocusDuration = Duration(milliseconds: 200);

// ===========================================================================
//  Navegación con el mando (paso 6): zonas, bordes y "volver por donde entré".
//
//  - TvTraversalPolicy: al moverse a izquierda/derecha solo se salta a elementos que están en la
//    MISMA fila. Antes, si no había nada en esa fila, Flutter saltaba a lo más cercano de otra
//    fila (p. ej. de "Más información" a una carátula de abajo). Ahora no pasa nada, y el borde
//    de la pantalla se puede usar para ir al menú lateral (shell.dart).
//  - TvEdgeNotification: un campo de texto (TvTextEntry) avisa hacia arriba cuando no puede
//    seguir en una dirección, para que el menú lateral lo recoja.
//  - tvInEditableText: para no robarle las flechas a un campo mientras se escribe.
// ===========================================================================
class TvTraversalPolicy extends ReadingOrderTraversalPolicy {
  TvTraversalPolicy();

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    // Foco "huérfano": está sobre una ZONA (FocusScopeNode) y no sobre un elemento. No se dibuja
    // ningún aro y el rectángulo de la zona es enorme, así que las flechas saltaban a medias o
    // no iban a ninguna parte (el bug de "navego a ciegas y hay zonas a las que no llego").
    // La primera flecha lo recoge: se enfoca el primer elemento de esa zona.
    if (currentNode is FocusScopeNode) {
      final FocusNode? first =
          findFirstFocus(currentNode, ignoreCurrentFocus: true);
      if (first != null && first != currentNode && tvUsable(first)) {
        first.requestFocus();
        return true;
      }
    }
    if (direction == TraversalDirection.left ||
        direction == TraversalDirection.right) {
      final scope = currentNode.nearestScope;
      if (scope == null) return false;
      final r = currentNode.rect;
      final hasSameRow = scope.traversalDescendants.any((n) {
        if (identical(n, currentNode)) return false;
        final nr = n.rect;
        final sameRow = nr.top < r.bottom && nr.bottom > r.top;
        final side = direction == TraversalDirection.left
            ? nr.center.dx <= r.left
            : nr.center.dx >= r.right;
        return sameRow && side;
      });
      if (!hasSameRow) return false;
    }
    return super.inDirection(currentNode, direction);
  }
}

/// "Aquí no puedo seguir en esta dirección" (lo envía TvTextEntry; lo recoge el shell).
class TvEdgeNotification extends Notification {
  TvEdgeNotification(this.direction);
  final TraversalDirection direction;
}

/// ¿El foco está dentro de un campo de texto? (ahí las flechas mueven el cursor).
bool tvInEditableText(FocusNode? n) =>
    n?.context?.findAncestorWidgetOfExactType<EditableText>() != null;

/// ¿Sigue [n] pudiendo recibir el foco (montado, visible y no excluido)?
///
/// Un nodo cuyo widget ya se desmontó (p. ej. una carátula que una fila perezosa descartó por
/// estar lejos) conserva su `context`, pero ya no está en el árbol y `requestFocus` no hace
/// nada: por eso se comprueba también que el contexto siga montado y que el nodo tenga padre.
bool tvUsable(FocusNode? n) =>
    n != null &&
    n.canRequestFocus &&
    n.parent != null &&
    (n.context?.mounted ?? false);

/// ¿El foco está "perdido"? (ninguno, o sobre una zona en vez de sobre un elemento). En ese estado
/// no se pinta ningún aro y la navegación con el mando se vuelve errática.
bool tvFocusLost(FocusNode? n) => n == null || n is FocusScopeNode;

/// Lo registra el Inicio (TheaterScreen) en TV: devuelve el foco y la selección al botón
/// Reanudar/Reproducir del cartel (y vuelve al principio de la pantalla). Devuelve false si el
/// botón aún no existe. Lo llaman la intro al terminar y la red de seguridad del shell.
bool Function()? tvHomeResetFocus;

/// Borde que solo se pinta con foco (aro de 2 px). Para botones rellenos o con borde propio,
/// donde el aro blanco del tema no se ve o lo taparía su `side` fijo.
WidgetStateProperty<BorderSide?> focusSide(Color ring, [BorderSide? idle]) =>
    WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused)
        ? BorderSide(color: ring, width: kFocusWidth)
        : idle);

/// Tema para TV: el foco se ve de lejos (aro blanco fino en botones, velo claro en listas e
/// interruptores).
ThemeData tvTheme(ThemeData base) {
  final ring = WidgetStateProperty.resolveWith<BorderSide?>((s) =>
      s.contains(WidgetState.focused)
          ? const BorderSide(color: kFocusRing, width: kFocusWidth)
          : null);
  // Velo suave al enfocar; sin valor (null) se usan los de siempre (pulsado, etc.).
  final overlay = WidgetStateProperty.resolveWith<Color?>(
      (s) => s.contains(WidgetState.focused) ? const Color(0x1FFFFFFF) : null);
  final style = ButtonStyle(side: ring, overlayColor: overlay);
  return base.copyWith(
    focusColor: const Color(0x33FFFFFF),
    hoverColor: const Color(0x22FFFFFF),
    visualDensity: VisualDensity.standard,
    filledButtonTheme: FilledButtonThemeData(style: style),
    outlinedButtonTheme: OutlinedButtonThemeData(style: style),
    textButtonTheme: TextButtonThemeData(style: style),
    elevatedButtonTheme: ElevatedButtonThemeData(style: style),
    iconButtonTheme: IconButtonThemeData(style: style),
  );
}

/// Texto un poco mayor en TV (se lee desde lejos).
Widget tvTextScale(Widget child) => Builder(
    builder: (context) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.15)),
        child: child));

/// Tecla Menú del mando (≡): hace lo que en el móvil hace "mantener pulsado".
class _OptionsIntent extends Intent {
  const _OptionsIntent();
}

/// Para tarjetas, carátulas y demás elementos que no son un botón: se pueden enfocar con el
/// mando (flechas), se activan con OK y al enfocarse se elevan: ligero aumento, aro blanco fino
/// y sombra/halo que aparecen con una transición suave.
/// Con el dedo no cambia nada: el aro solo sale al navegar con teclas o mando.
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.borderRadius = 10,
    this.autofocus = false,
    this.scale = 1.05,
    this.nearestScrollOnly = false,
    this.focusNode,
  });

  final Widget child;
  final VoidCallback? onTap, onLongPress;
  final double borderRadius, scale;
  final bool autofocus;

  /// Nodo de foco propio (para que quien lo creó pueda llevar el foco a este elemento, p. ej.
  /// las filas del inicio recuerdan la última carátula enfocada).
  final FocusNode? focusNode;

  /// Al enfocarse solo se desplaza el desplazable MÁS CERCANO (la fila o la rejilla donde está),
  /// no todos los de arriba. Hace falta cuando hay un PageView/TabBarView por encima: si no, al
  /// centrar un elemento la página entera se desliza hacia la pestaña de al lado.
  final bool nearestScrollOnly;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      enabled: widget.onTap != null || widget.onLongPress != null,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      onFocusChange: (v) {
        // Al llegar el foco, la tarjeta se desplaza hasta quedar a la vista.
        if (v) {
          final ro = context.findRenderObject();
          var sc =
              widget.nearestScrollOnly ? Scrollable.maybeOf(context) : null;
          // Un PageView/TabBarView NO cuenta: los elementos que no están dentro de una fila o
          // una rejilla (buscador, botón de filtros...) no deben mover las páginas.
          if (sc != null && sc.position is PageMetrics) sc = null;
          if (sc != null && ro != null) {
            sc.position.ensureVisible(ro,
                alignment: 0.5,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut);
          } else if (!widget.nearestScrollOnly) {
            Scrollable.ensureVisible(context,
                alignment: 0.5,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut);
          }
        }
      },
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.contextMenu): _OptionsIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          if (widget.onTap != null) Sfx.play(Snd.entrar);
          widget.onTap?.call();
          return null;
        }),
        _OptionsIntent: CallbackAction<_OptionsIntent>(onInvoke: (_) {
          widget.onLongPress?.call();
          return null;
        }),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap == null
            ? null
            : () {
                Sfx.play(Snd.entrar);
                widget.onTap!();
              },
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: _focused ? widget.scale : 1,
          duration: kFocusDuration,
          curve: kFocusCurve,
          child: AnimatedContainer(
            duration: kFocusDuration,
            curve: kFocusCurve,
            // Solo un aro fino que se funde (no aparece de golpe): sin sombra ni resplandor.
            // `borderRadius` debe ser el del elemento de dentro para que el aro lo siga exacto.
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              border: Border.all(
                  color: _focused ? kFocusRing : Colors.transparent,
                  width: kFocusWidth),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Foco para botones BLANCOS (Reproducir, Reanudar, Saltar intro...), donde un aro pegado al
/// borde no se distingue del propio botón. Sin resplandor ni sombra: un aro fino y limpio,
/// separado del botón por un pequeño hueco (como el anillo de foco de tvOS), y un leve aumento.
/// El `builder` recibe si hay foco, por si el contenido quiere reaccionar (p. ej. el icono).
/// El botón de dentro debe llevar `side: BorderSide.none` para no dibujar su propio aro.
class TvButtonFocus extends StatefulWidget {
  const TvButtonFocus({
    super.key,
    required this.builder,
    this.radius = 999,
    this.gap = 4,
    this.scale = 1.03,
    this.color = kFocusRing,
  });

  final Widget Function(BuildContext context, bool focused) builder;

  /// Radio de esquina del botón (999 = píldora).
  final double radius, gap, scale;
  final Color color;

  @override
  State<TvButtonFocus> createState() => _TvButtonFocusState();
}

class _TvButtonFocusState extends State<TvButtonFocus> {
  bool _focused = false;

  void _onFocus(bool has) {
    // El aro solo sale al navegar con mando o teclado, no al tocar con el dedo.
    final show = has &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    if (show != _focused && mounted) setState(() => _focused = show);
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.gap + 1.5; // hueco + grosor del aro
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _onFocus,
      child: AnimatedScale(
        scale: _focused ? widget.scale : 1,
        duration: kFocusDuration,
        curve: kFocusCurve,
        child: Stack(clipBehavior: Clip.none, children: [
          widget.builder(context, _focused),
          Positioned(
            left: -o,
            top: -o,
            right: -o,
            bottom: -o,
            child: IgnorePointer(
              child: AnimatedContainer(
                duration: kFocusDuration,
                curve: kFocusCurve,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.radius + o),
                  border: Border.all(
                      color: _focused ? widget.color : Colors.transparent,
                      width: 1.5),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Elemento enfocable cuyo marcador de foco dibuja [builder] (para formas que no son un
/// rectángulo: avatares redondos, etc.). Hace lo mismo que [TvFocusable] (OK activa, se centra al
/// enfocar, el foco solo se ve con mando/teclado) pero sin pintar nada: el `builder` recibe si hay
/// foco y pone él el aro con SU forma, para que coincida exactamente con el contorno.
class TvFocusBuilder extends StatefulWidget {
  const TvFocusBuilder({
    super.key,
    required this.builder,
    this.onTap,
    this.autofocus = false,
  });

  final Widget Function(BuildContext context, bool focused) builder;
  final VoidCallback? onTap;
  final bool autofocus;

  @override
  State<TvFocusBuilder> createState() => _TvFocusBuilderState();
}

class _TvFocusBuilderState extends State<TvFocusBuilder> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      enabled: widget.onTap != null,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      onFocusChange: (v) {
        if (v) {
          Scrollable.ensureVisible(context,
              alignment: 0.5, duration: kFocusDuration, curve: kFocusCurve);
        }
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          if (widget.onTap != null) Sfx.play(Snd.entrar);
          widget.onTap?.call();
          return null;
        }),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap == null
            ? null
            : () {
                Sfx.play(Snd.entrar);
                widget.onTap!();
              },
        child: widget.builder(context, _focused),
      ),
    );
  }
}

/// Aro de foco para un widget que ya sabe enfocarse por dentro (una fila de lista, un
/// casillero...): lo dibuja en cuanto algo de dentro tiene el foco, con el radio [radius] (el de
/// la forma de dentro, para que coincida). Con `enabled: false` no hace nada (móvil/escritorio).
class TvFocusRing extends StatefulWidget {
  const TvFocusRing(
      {super.key, required this.child, this.radius = 12, this.enabled = true});
  final Widget child;
  final double radius;
  final bool enabled;

  @override
  State<TvFocusRing> createState() => _TvFocusRingState();
}

class _TvFocusRingState extends State<TvFocusRing> {
  bool _focused = false;

  void _onFocus(bool has) {
    final show = has &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    if (show != _focused && mounted) setState(() => _focused = show);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _onFocus,
      child: AnimatedContainer(
        duration: kFocusDuration,
        curve: kFocusCurve,
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          border: Border.all(
              color: _focused ? kFocusRing : Colors.transparent,
              width: kFocusWidth),
        ),
        child: widget.child,
      ),
    );
  }
}

// ===========================================================================
//  Entrada de texto con el mando (paso 5).
//
//  Problema: un TextField enfocado abre el teclado en cuanto el foco llega a él y se queda con
//  las flechas (arriba/abajo/izquierda/derecha mueven el cursor): con el mando uno se quedaba
//  "atrapado" en el campo. Solución: TvTextEntry envuelve cualquier TextField y lo trata como
//  un botón hasta que se pulsa OK:
//
//    - Sin editar: el campo es una parada de foco más (aro blanco). Las flechas se mueven entre
//      elementos y OK empieza a editar (se abre el teclado de la TV).
//    - Editando: el teclado de la TV recibe las flechas. Cuando se cierra (Atrás, o ✓ del
//      teclado) se vuelve al modo anterior, con el foco todavía en el campo. Sin teclado en
//      pantalla (mando sin él, o teclado físico) ▲/▼ salen del campo, ◀/▶ lo hacen al llegar
//      al principio/final del texto, Esc/Atrás dejan de editar y OK vuelve a abrir el teclado.
//
//  Fuera de TV devuelve el hijo tal cual: móvil y escritorio no cambian.
// ===========================================================================
class TvTextEntry extends ConsumerStatefulWidget {
  const TvTextEntry({
    super.key,
    required this.child,
    this.startEditing = false,
    this.multiline = false,
    this.borderRadius = 12,
  });

  /// El TextField (con su controlador, decoración, etc., sin cambios).
  final Widget child;

  /// Empieza escribiendo (para buscadores que se abren con el botón de la lupa y ya llevan
  /// `autofocus: true`).
  final bool startEditing;

  /// Campo de varias líneas: ▲/▼ solo salen del campo desde el principio/final del texto.
  final bool multiline;
  final double borderRadius;

  @override
  ConsumerState<TvTextEntry> createState() => _TvTextEntryState();
}

class _TvTextEntryState extends ConsumerState<TvTextEntry>
    with WidgetsBindingObserver {
  late final FocusNode _outer =
      FocusNode(debugLabel: 'TvTextEntry', onKeyEvent: _onKey);
  late bool _editing = widget.startEditing;
  bool _ring = false;
  bool _sawInset = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Buscadores que se abren ya escribiendo: se enfoca el campo y se abre el teclado
    // en cuanto está construido (el autofocus solo no basta si el foco se acaba de perder).
    if (widget.startEditing && ref.read(tvModeProvider)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_editing) return;
        _innerNode()?.requestFocus();
        _showKeyboard();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _outer.dispose();
    super.dispose();
  }

  /// Si el teclado de la TV se cierra (Atrás), se deja de editar y el foco queda en el campo.
  @override
  void didChangeMetrics() {
    if (!_editing || !mounted) return;
    final bottom = View.of(context).viewInsets.bottom;
    if (bottom > 0) {
      _sawInset = true;
    } else if (_sawInset) {
      _sawInset = false;
      _stopEditing();
    }
  }

  /// El foco del TextField de dentro (no el del aro de fuera ni el de sus iconos).
  FocusNode? _innerNode() {
    for (final n in _outer.descendants) {
      final c = n.context;
      if (n.canRequestFocus &&
          c != null &&
          c.findAncestorWidgetOfExactType<EditableText>() != null) {
        return n;
      }
    }
    return null;
  }

  EditableTextState? _editable() =>
      _innerNode()?.context?.findAncestorStateOfType<EditableTextState>();

  void _showKeyboard() {
    SystemChannels.textInput
        .invokeMethod<void>('TextInput.show')
        .catchError((_) {});
  }

  void _hideKeyboard() {
    SystemChannels.textInput
        .invokeMethod<void>('TextInput.hide')
        .catchError((_) {});
  }

  void _startEditing() {
    if (_editing) {
      _showKeyboard();
      return;
    }
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _innerNode()?.requestFocus();
      _showKeyboard();
    });
  }

  /// Deja de editar y el foco se queda en el campo (como un botón más).
  void _stopEditing() {
    if (!_editing) return;
    _outer.requestFocus();
    setState(() => _editing = false);
    _hideKeyboard();
  }

  void _leave(TraversalDirection d) {
    _stopEditing();
    // Si no hay nada en esa dirección, se avisa hacia arriba (p. ej. ◀ → menú lateral).
    if (!_outer.focusInDirection(d)) TvEdgeNotification(d).dispatch(context);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final down = e is KeyDownEvent;
    final k = e.logicalKey;
    final isOk =
        k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.gameButtonA;

    if (!_editing) {
      if (isOk ||
          k == LogicalKeyboardKey.enter ||
          k == LogicalKeyboardKey.numpadEnter) {
        if (down) _startEditing();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored; // las flechas mueven el foco como siempre
    }

    if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack) {
      if (down) _stopEditing();
      return KeyEventResult.handled;
    }
    if (isOk) {
      // Con el teclado oculto, OK lo vuelve a abrir.
      if (down) _showKeyboard();
      return KeyEventResult.handled;
    }

    final vertical =
        k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown;
    final horizontal =
        k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight;
    if (!vertical && !horizontal) return KeyEventResult.ignored;

    final v = _editable()?.textEditingValue;
    final sel = v?.selection;
    var atStart = false, atEnd = false;
    if (v != null && sel != null && sel.isCollapsed) {
      atStart = sel.baseOffset <= 0;
      atEnd = sel.baseOffset < 0 || sel.baseOffset >= v.text.length;
    }

    TraversalDirection? go;
    if (k == LogicalKeyboardKey.arrowUp && (!widget.multiline || atStart)) {
      go = TraversalDirection.up;
    } else if (k == LogicalKeyboardKey.arrowDown &&
        (!widget.multiline || atEnd)) {
      go = TraversalDirection.down;
    } else if (k == LogicalKeyboardKey.arrowLeft && atStart) {
      go = TraversalDirection.left;
    } else if (k == LogicalKeyboardKey.arrowRight && atEnd) {
      go = TraversalDirection.right;
    }
    if (go == null)
      return KeyEventResult.ignored; // mover el cursor dentro del texto
    if (down) _leave(go);
    return KeyEventResult.handled;
  }

  void _onFocusChange(bool has) {
    final ring = has &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    if (ring != _ring && mounted) setState(() => _ring = ring);
    if (!has && _editing && mounted) {
      // El campo perdió el foco (✓ del teclado, otro elemento...): se acaba la edición.
      setState(() => _editing = false);
      _hideKeyboard();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Si no ha ido a ningún sitio (✓ del teclado hace unfocus), vuelve al campo; si se
        // abrió otra pantalla o el foco está en otro elemento, no se le quita.
        final pf = FocusManager.instance.primaryFocus;
        final current = ModalRoute.of(context)?.isCurrent ?? true;
        if (current && (pf == null || pf is FocusScopeNode))
          _outer.requestFocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(tvModeProvider)) return widget.child;
    return Focus(
      focusNode: _outer,
      onKeyEvent: _onKey,
      onFocusChange: _onFocusChange,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _startEditing,
        child: AnimatedContainer(
          duration: kFocusDuration,
          curve: kFocusCurve,
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            border: Border.all(
                color: (_ring || _editing) ? kFocusRing : Colors.transparent,
                width: kFocusWidth),
          ),
          // Sin editar, lo de dentro no recibe foco ni toques: lo recibe este envoltorio.
          child: ExcludeFocus(
            excluding: !_editing,
            child: IgnorePointer(ignoring: !_editing, child: widget.child),
          ),
        ),
      ),
    );
  }
}

/// En TV, al enfocar algo de dentro la pantalla vuelve al principio. Es lo que hacen las apps de
/// streaming al subir al cartel: el botón Reproducir y su cabecera quedan a la vista en vez de
/// pegados al borde superior (y tapados por la barra). Solo actúa al navegar con el mando o el
/// teclado, no con el dedo.
class TvScrollTopOnFocus extends StatelessWidget {
  const TvScrollTopOnFocus({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (has) {
        if (!has ||
            FocusManager.instance.highlightMode !=
                FocusHighlightMode.traditional) {
          return;
        }
        // Después de que Flutter haya desplazado lo justo para ver el botón.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          final pos = Scrollable.maybeOf(context)?.position;
          if (pos == null || !pos.hasPixels || pos.pixels <= 0) return;
          pos.animateTo(0,
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic);
        });
      },
      child: child,
    );
  }
}
