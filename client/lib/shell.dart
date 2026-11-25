import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core.dart';
import 'peticiones.dart' show PeticionesScreen;
import 'profiles.dart';
import 'remote.dart' show remoteProvider, serverOfflineProvider;
import 'sala.dart' show SalaScreen;
import 'theater.dart' show tvTheaterBack;
import 'settings.dart' show SettingsScreen;
import 'sounds.dart';
import 'tv.dart'
    show
        TvEdgeNotification,
        TvTraversalPolicy,
        kFocusCurve,
        kFocusDuration,
        tvFocusLost,
        tvHomeResetFocus,
        tvInEditableText,
        tvModeProvider,
        tvUsable;

// ===========================================================================
//  Barra de navegación inferior: Inicio · Sala · Peticiones · Cuenta.
//
//  - Inicio:      la biblioteca (modo teatro, lista, o teatro sin conexión).
//  - Sala:        la sala de cine de "ver juntos" (funciones en curso y quién las ve).
//  - Peticiones:  explorar y pedir (funciona también con el servidor apagado).
//  - Cuenta:      Ajustes. Arriba está el perfil (cambiar de cuenta) y más abajo
//                 "Gestionar descargas", así que ya no hacen falta botones aparte.
//
//  Las pestañas se crean la primera vez que se abren y después se conservan
//  (IndexedStack), así no se pierde el scroll ni lo explorado al cambiar de una a otra.
//  Los videos, fichas y demás pantallas se abren por encima y tapan la barra.
// ===========================================================================

const _bg = Color(0xFF141414);

/// Para pedir desde otra pantalla que la barra cambie de pestaña (0 Inicio, 1 Sala...).
class TabRequest extends Notifier<int?> {
  @override
  int? build() => null;
  void request(int i) => state = i;
  void clear() => state = null;
}

final tabRequestProvider = NotifierProvider<TabRequest, int?>(TabRequest.new);
const _red = Color(0xFFE50914);

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, required this.home});

  /// Contenido de la pestaña "Inicio".
  final Widget home;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;
  final Set<int> _opened = {0};

  // ---- Modo TV: zonas de foco -------------------------------------------------------------
  //  [menú lateral] | [pestaña actual]   (la barra superior y las filas viven dentro de la pestaña)
  //  - ◀ en el borde izquierdo de cualquier pantalla salta al menú lateral.
  //  - ▶ / OK en el menú entra en la pestaña y devuelve el foco al elemento donde estabas
  //    (la campanita, una carátula, un botón...), no al primero que pille.
  //  - Atrás: de la pantalla al menú lateral; en el menú, de otra pestaña a Inicio; en Inicio, salir.
  final _railScope = FocusScopeNode(debugLabel: 'TvRail');
  final _railNodes = List.generate(4, (i) => FocusNode(debugLabel: 'TvRail$i'));
  final _tabScopes =
      List.generate(4, (i) => FocusScopeNode(debugLabel: 'TvTab$i'));
  final _policy = TvTraversalPolicy();

  /// Dónde estaba el foco en cada pestaña al salir al menú lateral.
  final Map<int, FocusNode> _back = {};

  Timer? _guard;

  @override
  void initState() {
    super.initState();
    // El menú lateral solo se ve mientras tiene el foco: al cambiar, se redibuja.
    _railScope.addListener(_onRailFocus);
    if (ref.read(tvModeProvider)) {
      // Red de seguridad: si el foco se pierde (queda sobre una zona y no sobre un botón, no
      // se dibuja ningún aro y el mando se vuelve errático), se recupera solo.
      FocusManager.instance.addListener(_watchFocus);
      // Al abrir la app desde cero, foco y selección en el botón Reanudar del Inicio.
      WidgetsBinding.instance.addPostFrameCallback((_) => _resetHomeFocus());
    }
  }

  /// Foco y selección al botón Reanudar/Reproducir del Inicio (o, si aún no existe, al primer
  /// elemento de la pestaña actual).
  void _resetHomeFocus() {
    if (!mounted || !ref.read(tvModeProvider)) return;
    if (_index == 0 && (tvHomeResetFocus?.call() ?? false)) return;
    _focusFirstOfTab();
  }

  void _focusFirstOfTab() {
    final tab = _tabScopes[_index];
    final FocusNode? first =
        _policy.findFirstFocus(tab, ignoreCurrentFocus: true);
    if (first != null && first != tab && tvUsable(first)) {
      first.requestFocus();
    }
  }

  void _watchFocus() {
    if (!mounted) return;
    _guard?.cancel();
    if (!tvFocusLost(FocusManager.instance.primaryFocus)) return;
    // Margen para los cambios normales de pantalla (rutas, pestañas, intro): solo se actúa si
    // el foco sigue perdido pasado un instante.
    _guard = Timer(const Duration(milliseconds: 350), _rescueFocus);
  }

  void _rescueFocus() {
    if (!mounted || !ref.read(tvModeProvider)) return;
    final pf = FocusManager.instance.primaryFocus;
    if (!tvFocusLost(pf)) return;
    // Solo si esta pantalla es la visible (no un video, una ficha o un diálogo encima).
    if (ModalRoute.of(context)?.isCurrent != true) return;
    final tab = _tabScopes[_index];
    final mine = pf == null ||
        pf == FocusManager.instance.rootScope ||
        pf == tab ||
        pf == _railScope ||
        tab.ancestors.contains(pf);
    if (!mine) return;
    if (pf == _railScope) {
      _railNodes[_index].requestFocus();
      return;
    }
    _resetHomeFocus();
  }

  void _onRailFocus() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _guard?.cancel();
    FocusManager.instance.removeListener(_watchFocus);
    _railScope.removeListener(_onRailFocus);
    _railScope.dispose();
    for (final n in _railNodes) {
      n.dispose();
    }
    for (final n in _tabScopes) {
      n.dispose();
    }
    super.dispose();
  }

  void _select(int i) => setState(() {
        _index = i;
        _opened.add(i);
      });

  /// Cambio de pestaña pedido desde fuera (otro perfil, un aviso...). En TV el foco la sigue.
  void _open(int i) {
    _select(i);
    if (ref.read(tvModeProvider)) _enter(i);
  }

  /// Foco al menú lateral (en la pestaña actual), recordando de dónde venía.
  void _goRail({bool silent = false}) {
    if (!silent) Sfx.zone();
    final cur = FocusManager.instance.primaryFocus;
    if (!_railScope.hasFocus && tvUsable(cur) && cur is! FocusScopeNode) {
      _back[_index] = cur!;
    }
    _railNodes[_index].requestFocus();
  }

  /// Entra en la pestaña [i]: vuelve al elemento donde se salió; si no hay, al primero.
  void _enter(int i) {
    Sfx.zone(); // cambio de zona / sección
    void focusIt() {
      if (!mounted) return;
      final scope = _tabScopes[i];
      final back = _back[i];
      if (tvUsable(back) && back!.ancestors.contains(scope)) {
        back.requestFocus();
      } else {
        scope.requestFocus();
      }
    }

    if (i == _index) {
      // Misma pestaña: ya está construida, el foco se pide ya (un callback "tras el frame"
      // no se ejecutaría hasta la siguiente pulsación porque no hay ningún frame pendiente).
      focusIt();
    } else {
      _select(
          i); // setState programa el frame; el foco se pide cuando la pestaña ya existe
      WidgetsBinding.instance.addPostFrameCallback((_) => focusIt());
    }
  }

  /// ◀ en una pantalla: si hay algo a la izquierda en la misma fila se mueve; si no, al menú.
  KeyEventResult _contentKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent || e.logicalKey != LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.ignored;
    }
    final cur = FocusManager.instance.primaryFocus;
    if (cur == null || tvInEditableText(cur))
      return KeyEventResult.ignored; // cursor del texto
    if (cur.focusInDirection(TraversalDirection.left))
      return KeyEventResult.handled;
    // Solo con una pulsación nueva (no manteniendo): así no se "cae" al menú de golpe.
    if (e is KeyDownEvent) _goRail();
    return KeyEventResult.handled;
  }

  void _onBack() {
    Sfx.play(Snd.salirOAtras);
    if (!ref.read(tvModeProvider)) {
      _select(0);
      return;
    }
    // Con el buscador del Inicio abierto, Atrás lo cierra (antes que ir al menú o salir).
    if (_index == 0 && (tvTheaterBack?.call() ?? false)) return;
    if (_railScope.hasFocus) {
      if (_index != 0) {
        _select(0);
        _railNodes[0].requestFocus();
      } else {
        SystemNavigator.pop();
      }
    } else {
      _goRail(silent: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Al cambiar de perfil se vuelve a Inicio para ver la biblioteca del perfil nuevo.
    ref.listen<String?>(
        profilesProvider.select((p) => p.valueOrNull?.currentProfile?.key),
        (prev, next) {
      if (prev != null && next != prev && _index != 0) _open(0);
    });

    ref.listen<int?>(tabRequestProvider, (_, v) {
      if (v == null) return;
      _open(v);
      Future.microtask(() => ref.read(tabRequestProvider.notifier).clear());
    });

    final api = ref.watch(apiProvider);
    final offline = ref.watch(serverOfflineProvider);
    final profile = ref.watch(profilesProvider).valueOrNull?.currentProfile;
    // Punto rojo en "Sala" cuando hay una función en curso.
    final rooms = ref.watch(remoteProvider.select((r) => r.parties.length));
    final tv = ref.watch(tvModeProvider);

    final tabs = <Widget>[
      widget.home,
      _opened.contains(1) ? const SalaScreen() : const SizedBox(),
      _opened.contains(2) ? const PeticionesScreen() : const SizedBox(),
      _opened.contains(3) ? const SettingsScreen() : const SizedBox(),
    ];
    final pages = IndexedStack(index: _index, children: [
      for (var i = 0; i < tabs.length; i++)
        tv
            // Cada pestaña es su propia zona de foco (recuerda dónde estabas) y la que no se
            // ve no puede recibir el foco.
            ? ExcludeFocus(
                excluding: i != _index,
                child: FocusScope(
                    node: _tabScopes[i],
                    child: Focus(
                        canRequestFocus: false,
                        skipTraversal: true,
                        onKeyEvent: _contentKey,
                        child: tabs[i])))
            : tabs[i],
    ]);

    return PopScope(
      // "Atrás" desde Peticiones o Cuenta vuelve a Inicio en vez de cerrar la app.
      // En TV nunca sale directamente: primero al menú lateral (ver _onBack).
      canPop: !tv && _index == 0,
      onPopInvoked: (didPop) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        backgroundColor: _bg,
        // En TV el menú va a la izquierda (con el mando se llega con la flecha izquierda);
        // en móvil, abajo.
        body: tv
            ? NotificationListener<TvEdgeNotification>(
                // Un campo de texto que no puede seguir a la izquierda: al menú lateral.
                onNotification: (n) {
                  if (n.direction != TraversalDirection.left) return false;
                  _goRail();
                  return true;
                },
                child: FocusTraversalGroup(
                  policy: _policy,
                  // El menú va SUPERPUESTO y se desliza: el contenido no cambia de tamaño al
                  // mostrarlo/ocultarlo. Oculto sigue existiendo (puede recibir el foco).
                  child: Stack(children: [
                    Positioned.fill(child: pages),
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      child: AnimatedSlide(
                        offset: _railScope.hasFocus
                            ? Offset.zero
                            : const Offset(-1.2, 0),
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOutCubic,
                        child: _TvRail(
                            scope: _railScope,
                            nodes: _railNodes,
                            index: _index,
                            onEnter: _enter,
                            onReturn: () => _enter(_index),
                            rooms: rooms,
                            avatar: (profile != null && !offline)
                                ? AvatarCircle(
                                    api: api, profile: profile, radius: 13)
                                : null),
                      ),
                    ),
                  ]),
                ))
            : pages,
        bottomNavigationBar: tv
            ? null
            : DecoratedBox(
                // Filete fino arriba para separar la barra del contenido.
                decoration: const BoxDecoration(
                    color: _bg,
                    border: Border(
                        top: BorderSide(color: Color(0x1AFFFFFF), width: 0.5))),
                child: NavigationBarTheme(
                  data: NavigationBarThemeData(
                    height: 64,
                    elevation: 0,
                    backgroundColor: _bg,
                    surfaceTintColor: Colors.transparent,
                    indicatorColor: Colors.transparent,
                    labelTextStyle: WidgetStateProperty.resolveWith((states) {
                      final sel = states.contains(WidgetState.selected);
                      return TextStyle(
                          fontSize: 11,
                          letterSpacing: 0.4,
                          fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                          color: sel ? Colors.white : Colors.white54);
                    }),
                    iconTheme: WidgetStateProperty.resolveWith((states) {
                      final sel = states.contains(WidgetState.selected);
                      return IconThemeData(
                          size: 24, color: sel ? _red : Colors.white54);
                    }),
                  ),
                  child: NavigationBar(
                    backgroundColor: _bg,
                    surfaceTintColor: Colors.transparent,
                    indicatorColor: Colors.transparent,
                    selectedIndex: _index,
                    onDestinationSelected: (i) {
                      if (i != _index) Sfx.zone(); // cambio de pestaña
                      _select(i);
                    },
                    destinations: [
                      const NavigationDestination(
                          icon: Icon(Icons.home_outlined),
                          selectedIcon: Icon(Icons.home_rounded),
                          label: 'Inicio'),
                      NavigationDestination(
                          icon: Badge(
                              smallSize: 8,
                              isLabelVisible: rooms > 0,
                              child: const Icon(Icons.theaters_outlined)),
                          selectedIcon: const Icon(Icons.theaters),
                          label: 'Sala'),
                      const NavigationDestination(
                          icon: Icon(Icons.playlist_add),
                          selectedIcon: Icon(Icons.playlist_add_check),
                          label: 'Peticiones'),
                      NavigationDestination(
                          // El avatar del perfil activo; sin perfil o sin servidor, un icono.
                          // Activo: aro rojo alrededor del avatar.
                          icon: (profile != null && !offline)
                              ? _ring(
                                  AvatarCircle(
                                      api: api, profile: profile, radius: 12),
                                  false)
                              : const Icon(Icons.account_circle_outlined),
                          selectedIcon: (profile != null && !offline)
                              ? _ring(
                                  AvatarCircle(
                                      api: api, profile: profile, radius: 12),
                                  true)
                              : const Icon(Icons.account_circle),
                          label: 'Cuenta'),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

/// Aro alrededor del avatar de la pestaña "Cuenta" (rojo cuando está activa).
Widget _ring(Widget avatar, bool selected) => Container(
    padding: const EdgeInsets.all(1.5),
    decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
            color: selected ? _red : Colors.transparent, width: 1.5)),
    child: avatar);

/// Menú lateral para TV: Inicio · Sala · Peticiones · Cuenta.
///
/// ▲/▼ recorren las opciones; OK abre la sección elegida; ▶ vuelve a la pantalla actual, al sitio
/// donde estabas, sin cambiar de sección. ◀ no hace nada: es el borde izquierdo.
class _TvRail extends StatelessWidget {
  const _TvRail({
    required this.scope,
    required this.nodes,
    required this.index,
    required this.onEnter,
    required this.onReturn,
    required this.rooms,
    required this.avatar,
  });

  final FocusScopeNode scope;
  final List<FocusNode> nodes;
  final int index, rooms;
  final ValueChanged<int> onEnter;
  final VoidCallback onReturn;
  final Widget? avatar;

  @override
  Widget build(BuildContext context) {
    Widget item(int i, String label, Widget icon, Widget selectedIcon) =>
        _RailButton(
            node: nodes[i],
            prev: i > 0 ? nodes[i - 1] : null,
            next: i < nodes.length - 1 ? nodes[i + 1] : null,
            selected: index == i,
            label: label,
            icon: icon,
            selectedIcon: selectedIcon,
            onEnter: () => onEnter(i),
            onReturn: onReturn);

    return FocusScope(
      node: scope,
      child: Container(
        width: 96,
        decoration: const BoxDecoration(
            color: _bg,
            border:
                Border(right: BorderSide(color: Color(0x1AFFFFFF), width: 0.5)),
            boxShadow: [BoxShadow(color: Color(0xCC000000), blurRadius: 24)]),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          item(0, 'Inicio', const Icon(Icons.home_outlined),
              const Icon(Icons.home_rounded)),
          item(
              1,
              'Sala',
              Badge(
                  smallSize: 8,
                  isLabelVisible: rooms > 0,
                  child: const Icon(Icons.theaters_outlined)),
              const Icon(Icons.theaters)),
          item(2, 'Peticiones', const Icon(Icons.playlist_add),
              const Icon(Icons.playlist_add_check)),
          item(
              3,
              'Cuenta',
              avatar != null
                  ? _ring(avatar!, false)
                  : const Icon(Icons.account_circle_outlined),
              avatar != null
                  ? _ring(avatar!, true)
                  : const Icon(Icons.account_circle)),
        ]),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.node,
    required this.prev,
    required this.next,
    required this.selected,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.onEnter,
    required this.onReturn,
  });

  final FocusNode node;
  final FocusNode? prev, next; // opciones vecinas del menú
  final bool selected;
  final String label;
  final Widget icon, selectedIcon;
  final VoidCallback onEnter, onReturn;

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    final k = e.logicalKey;
    // OK: abre la sección de esta opción.
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.gameButtonA) {
      if (e is KeyDownEvent) onEnter();
      return KeyEventResult.handled;
    }
    // ▶: vuelve a la pantalla actual, donde estabas, sin cambiar de sección.
    if (k == LogicalKeyboardKey.arrowRight) {
      if (e is KeyDownEvent) onReturn();
      return KeyEventResult.handled;
    }
    // ◀ es el borde: no hay nada a la izquierda.
    if (k == LogicalKeyboardKey.arrowLeft) return KeyEventResult.handled;
    // ▲/▼: explícito entre opciones (no depende de qué recuerde el recorrido automático).
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      final to = k == LogicalKeyboardKey.arrowUp ? prev : next;
      if (e is KeyDownEvent || e is KeyRepeatEvent) to?.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: node,
      onKeyEvent: _onKey,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onEnter,
        child: AnimatedBuilder(
          animation: node,
          builder: (_, __) {
            final focused = node.hasFocus;
            final lit = selected || focused;
            return AnimatedContainer(
              duration: kFocusDuration,
              curve: kFocusCurve,
              width: 80,
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(vertical: 10),
              // Enfocado: pastilla de cristal (velo claro + filete fino + sombra), sin el marco
              // grueso de antes. El acento rojo de la izquierda marca dónde estás.
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: focused ? const Color(0x2EFFFFFF) : Colors.transparent,
                  border: Border.all(
                      color: focused
                          ? const Color(0x47FFFFFF)
                          : Colors.transparent,
                      width: 1),
                  boxShadow: focused
                      ? const [
                          BoxShadow(
                              color: Color(0x66000000),
                              blurRadius: 18,
                              offset: Offset(0, 6))
                        ]
                      : const <BoxShadow>[]),
              child: Stack(alignment: Alignment.center, children: [
                // Barrita de acento: alta con el foco, corta en la sección activa, nada en el resto.
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: AnimatedContainer(
                      duration: kFocusDuration,
                      curve: kFocusCurve,
                      width: 3,
                      height: focused ? 30 : (selected ? 14 : 0),
                      decoration: BoxDecoration(
                          color: _red, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                ),
                Column(mainAxisSize: MainAxisSize.min, children: [
                  AnimatedScale(
                    scale: focused ? 1.1 : 1,
                    duration: kFocusDuration,
                    curve: kFocusCurve,
                    child: IconTheme(
                        data: IconThemeData(
                            size: 28,
                            color: selected
                                ? _red
                                : (focused ? Colors.white : Colors.white54)),
                        child: selected ? selectedIcon : icon),
                  ),
                  const SizedBox(height: 4),
                  AnimatedDefaultTextStyle(
                    duration: kFocusDuration,
                    curve: kFocusCurve,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        letterSpacing: focused ? 0.3 : 0,
                        fontWeight: lit ? FontWeight.w700 : FontWeight.w500,
                        color: lit ? Colors.white : Colors.white54),
                    child: Text(label),
                  ),
                ]),
              ]),
            );
          },
        ),
      ),
    );
  }
}
