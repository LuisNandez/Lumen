import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _red = Color(0xFFE50914);

/// Una fila del menú (una pista, una calidad...).
class MenuOption {
  const MenuOption(this.label, this.selected, this.onTap, {this.detail});
  final String label;
  final String? detail;
  final bool selected;
  final VoidCallback onTap;
}

/// Una pestaña del menú. Con [delay] y [onDelay] se muestra abajo un ajuste de retraso/sincronía;
/// [footerBuilder] crea un control extra fijo al pie de la pestaña (p. ej. el tamaño de los
/// subtítulos). Recibe un callback para avisar al menú de que el control se está usando: mientras
/// está activo, el menú se oculta y solo queda ese control (arriba), para ver el video sin tapar.
class MenuSection {
  const MenuSection(this.title, this.icon, this.options,
      {this.emptyText,
      this.delayLabel,
      this.delay,
      this.onDelay,
      this.footerBuilder});
  final String title;
  final IconData icon;
  final List<MenuOption> options;
  final String? emptyText;
  final String? delayLabel;
  final double? delay;
  final ValueChanged<double>? onDelay;
  final Widget Function(ValueChanged<bool> setActive)? footerBuilder;
}

const _langs = {
  'es': 'Español',
  'spa': 'Español',
  'en': 'Inglés',
  'eng': 'Inglés',
  'ja': 'Japonés',
  'jpn': 'Japonés',
  'fr': 'Francés',
  'fre': 'Francés',
  'fra': 'Francés',
  'de': 'Alemán',
  'ger': 'Alemán',
  'deu': 'Alemán',
  'it': 'Italiano',
  'ita': 'Italiano',
  'pt': 'Portugués',
  'por': 'Portugués',
  'ru': 'Ruso',
  'rus': 'Ruso',
  'ko': 'Coreano',
  'kor': 'Coreano',
  'zh': 'Chino',
  'chi': 'Chino',
  'zho': 'Chino',
  'ca': 'Catalán',
  'cat': 'Catalán',
  'ar': 'Árabe',
  'ara': 'Árabe',
  'hi': 'Hindi',
  'hin': 'Hindi',
  'tr': 'Turco',
  'tur': 'Turco',
  'pl': 'Polaco',
  'pol': 'Polaco',
  'nl': 'Neerlandés',
  'dut': 'Neerlandés',
  'nld': 'Neerlandés',
  'sv': 'Sueco',
  'swe': 'Sueco',
  'la': 'Latín',
  'lat': 'Latín',
};

/// Texto de una pista: idioma en español como título y, si aporta algo, el nombre de la pista
/// como detalle. Sin idioma usa el nombre de la pista o "Pista N".
(String, String?) trackText(String id, String? title, String? lang) {
  var code = lang?.trim().toLowerCase();
  if (code == 'und' || code == 'unk') code = null;
  final name = code == null || code.isEmpty
      ? null
      : (_langs[code] ??
          _langs[code.split(RegExp('[-_]')).first] ??
          lang!.trim());
  final t = title?.trim();
  final hasT = t != null && t.isNotEmpty;
  if (name != null) {
    return (name, hasT && t.toLowerCase() != name.toLowerCase() ? t : null);
  }
  return (hasT ? t : 'Pista $id', null);
}

/// Panel lateral (desde la derecha) con pestañas. Al elegir una opción se cierra y se aplica.
///
/// [tv]: manejo con el mando. ◀ ▶ cambian de sección (Audio · Subtítulos · Calidad) sin tener
/// que subir a las pestañas, y el foco cae siempre en la opción elegida de la sección; las
/// pestañas y la ✕ no reciben foco (Atrás cierra el panel).
Future<void> showTrackMenu(BuildContext context,
    {required List<MenuSection> sections, int initial = 0, bool tv = false}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Cerrar',
    // Transparente: el oscurecido lo dibuja el propio panel, para poder quitarlo mientras se
    // ajusta el tamaño de los subtítulos y ver el video limpio.
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, __, ___) =>
        _TrackPanel(sections: sections, initial: initial, tv: tv),
    transitionBuilder: (_, anim, __, child) => SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

class _TrackPanel extends StatefulWidget {
  const _TrackPanel(
      {required this.sections, required this.initial, this.tv = false});
  final List<MenuSection> sections;
  final int initial;
  final bool tv;
  @override
  State<_TrackPanel> createState() => _TrackPanelState();
}

class _TrackPanelState extends State<_TrackPanel> {
  // Alto reservado al pie para el control extra (el control se dibuja aparte, ver build).
  static const _footerH = 56.0;
  static const _fade = Duration(milliseconds: 180);

  late int _tab = widget.initial.clamp(0, widget.sections.length - 1).toInt();
  late final List<double> _delays = [
    for (final s in widget.sections) s.delay ?? 0
  ];

  /// El control del pie se está usando: el resto del menú se oculta.
  bool _focus = false;
  Timer? _restore;

  /// TV: nodo de la opción donde cae el foco en la sección actual (la elegida, o la primera).
  final _listNode = FocusNode();

  bool get _tv => widget.tv;

  /// TV: pasa a la sección de al lado (◀ = anterior, ▶ = siguiente) y enfoca su opción elegida.
  KeyEventResult _tabKeys(FocusNode _, KeyEvent e) {
    if (!_tv || e is! KeyDownEvent) return KeyEventResult.ignored;
    final d = e.logicalKey == LogicalKeyboardKey.arrowLeft
        ? -1
        : e.logicalKey == LogicalKeyboardKey.arrowRight
            ? 1
            : 0;
    if (d == 0) return KeyEventResult.ignored;
    final n = _tab + d;
    if (n >= 0 && n < widget.sections.length) {
      setState(() => _tab = n);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _listNode.context != null) _listNode.requestFocus();
      });
    }
    return KeyEventResult.handled; // en los bordes no hace nada (no se pierde el foco)
  }

  @override
  void dispose() {
    _restore?.cancel();
    _listNode.dispose();
    super.dispose();
  }

  /// Al soltar el control el menú no vuelve de golpe: espera un momento para poder ver el
  /// resultado (un toque en la barra empieza y termina al instante).
  void _setFocus(bool on) {
    _restore?.cancel();
    if (on) {
      if (!_focus) setState(() => _focus = true);
    } else {
      _restore = Timer(const Duration(milliseconds: 1400), () {
        if (mounted) setState(() => _focus = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final s = widget.sections[_tab];
    final hasFooter = s.footerBuilder != null;
    final width = math.min(_tv ? 480.0 : 400.0, size.width * (_tv ? 0.6 : 0.92));
    return Stack(children: [
      // Oscurecido de fondo (antes lo ponía la barrera); se quita al ajustar el tamaño.
      Positioned.fill(
        child: IgnorePointer(
          child: AnimatedOpacity(
              opacity: _focus ? 0 : 1,
              duration: _fade,
              child: const ColoredBox(color: Colors.black45)),
        ),
      ),
      Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: _focus ? Colors.transparent : const Color(0xF2121212),
          clipBehavior: Clip.antiAlias,
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.horizontal(left: Radius.circular(20))),
          child: SizedBox(
            width: width,
            height: double.infinity,
            child: SafeArea(
              child: Stack(children: [
                // Todo el menú; se desvanece y deja de recibir toques mientras dura el ajuste.
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: _focus,
                    child: AnimatedOpacity(
                      opacity: _focus ? 0 : 1,
                      duration: _fade,
                      child: Column(children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 14, 8, 0),
                          child: Row(children: [
                            const Expanded(
                                child: Text('Reproducción',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700))),
                            ExcludeFocus(
                              excluding: _tv,
                              child: IconButton(
                                  icon: const Icon(Icons.close_rounded,
                                      color: Colors.white70),
                                  tooltip: 'Cerrar',
                                  onPressed: () => Navigator.pop(context)),
                            ),
                          ]),
                        ),
                        Row(children: [
                          if (_tv)
                            Icon(Icons.chevron_left_rounded,
                                color: _tab > 0 ? Colors.white54 : Colors.white12),
                          for (var i = 0; i < widget.sections.length; i++)
                            Expanded(child: _tabButton(i)),
                          if (_tv)
                            Icon(Icons.chevron_right_rounded,
                                color: _tab < widget.sections.length - 1
                                    ? Colors.white54
                                    : Colors.white12),
                        ]),
                        const Divider(height: 1, color: Colors.white12),
                        Expanded(
                          child: s.options.isEmpty
                              ? Focus(
                                  // TV: aunque no haya opciones, ◀ ▶ siguen cambiando de sección.
                                  focusNode: _listNode,
                                  autofocus: _tv,
                                  canRequestFocus: _tv,
                                  onKeyEvent: _tabKeys,
                                  child: Center(
                                      child: Padding(
                                          padding: const EdgeInsets.all(24),
                                          child: Text(
                                              s.emptyText ?? 'Sin opciones.',
                                              textAlign: TextAlign.center,
                                              style: const TextStyle(
                                                  color: Colors.white54)))),
                                )
                              : ListView(
                                  key: ValueKey(_tab),
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 6),
                                  children: [
                                      for (var k = 0;
                                          k < s.options.length;
                                          k++)
                                        _tile(s.options[k],
                                            owner: k ==
                                                _entryIndex(s.options))
                                    ]),
                        ),
                        if (s.onDelay != null) _delayBar(s),
                        if (hasFooter) const SizedBox(height: _footerH),
                      ]),
                    ),
                  ),
                ),
                // Control del pie. Es SIEMPRE el mismo widget (no se reconstruye al cambiar de
                // sitio), así el arrastre en curso no se corta: solo cambia su alineación.
                if (hasFooter)
                  Align(
                    alignment:
                        _focus ? Alignment.topCenter : Alignment.bottomCenter,
                    child: Container(
                      height: _footerH,
                      margin: EdgeInsets.all(_focus ? 12 : 0),
                      decoration: BoxDecoration(
                        color: _focus ? const Color(0xF2121212) : null,
                        borderRadius: BorderRadius.circular(_focus ? 14 : 0),
                        border: _focus
                            ? null
                            : const Border(
                                top: BorderSide(color: Colors.white12)),
                      ),
                      child: Center(child: s.footerBuilder!(_setFocus)),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _tabButton(int i) {
    final s = widget.sections[i];
    final sel = i == _tab;
    return InkWell(
      canRequestFocus: !_tv,
      onTap: () => setState(() => _tab = i),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
            border: Border(
                bottom: BorderSide(
                    color: sel ? _red : Colors.transparent, width: 3))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(s.icon, size: 22, color: sel ? Colors.white : Colors.white54),
          const SizedBox(height: 4),
          Text(s.title,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                  color: sel ? Colors.white : Colors.white54)),
        ]),
      ),
    );
  }

  /// Índice de la opción donde cae el foco: la elegida o, si no hay, la primera.
  int _entryIndex(List<MenuOption> opts) {
    final i = opts.indexWhere((o) => o.selected);
    return i < 0 ? 0 : i;
  }

  /// [owner]: es la opción donde cae el foco al abrir el panel o cambiar de sección.
  Widget _tile(MenuOption o, {bool owner = false}) {
    return Focus(
      // Solo recibe las teclas que le llegan desde la opción de dentro (◀ ▶ en TV).
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _tabKeys,
      child: _OptionTile(
        option: o,
        tv: _tv,
        focusNode: owner ? _listNode : null,
        autofocus: owner,
        onTap: () {
          Navigator.pop(context);
          o.onTap();
        },
      ),
    );
  }

  /// Ajuste fino de retraso (pasos de 0,25 s); tocar el valor lo deja en 0.
  Widget _delayBar(MenuSection s) {
    final v = _delays[_tab];
    void set(double x) {
      x = (x.clamp(-30.0, 30.0) * 100).round() / 100;
      setState(() => _delays[_tab] = x);
      s.onDelay!(x);
    }

    final label =
        v == 0 ? '0 s' : '${v > 0 ? '+' : '−'}${v.abs().toStringAsFixed(2)} s';
    return Container(
      decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Colors.white12))),
      padding: const EdgeInsets.fromLTRB(20, 6, 8, 6),
      child: Row(children: [
        const Icon(Icons.timer_outlined, size: 20, color: Colors.white54),
        const SizedBox(width: 10),
        Expanded(
            child: Text(s.delayLabel ?? 'Retraso',
                style: const TextStyle(color: Colors.white70, fontSize: 13.5))),
        IconButton(
            icon: const Icon(Icons.remove_circle_outline, color: Colors.white),
            tooltip: '−0,25 s',
            onPressed: () => set(v - 0.25)),
        GestureDetector(
          onTap: () => set(0),
          child: SizedBox(
              width: 68,
              child: Text(label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: v == 0 ? Colors.white70 : Colors.orangeAccent,
                      fontWeight: FontWeight.w600))),
        ),
        IconButton(
            icon: const Icon(Icons.add_circle_outline, color: Colors.white),
            tooltip: '+0,25 s',
            onPressed: () => set(v + 0.25)),
      ]),
    );
  }
}
/// Una opción del menú. En TV lleva marco blanco al enfocarla y letra más grande.
class _OptionTile extends StatefulWidget {
  const _OptionTile(
      {required this.option,
      required this.tv,
      required this.onTap,
      this.focusNode,
      this.autofocus = false});
  final MenuOption option;
  final bool tv, autofocus;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  @override
  State<_OptionTile> createState() => _OptionTileState();
}

class _OptionTileState extends State<_OptionTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final o = widget.option;
    final tv = widget.tv;
    final ring = tv && _focused;
    return Padding(
      padding: tv
          ? const EdgeInsets.symmetric(horizontal: 10, vertical: 2)
          : EdgeInsets.zero,
      child: InkWell(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        borderRadius: tv ? BorderRadius.circular(12) : null,
        focusColor: tv ? Colors.transparent : null,
        onFocusChange: (f) => setState(() => _focused = f &&
            FocusManager.instance.highlightMode ==
                FocusHighlightMode.traditional),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: tv
              ? BoxDecoration(
                  color: ring
                      ? Colors.white24
                      : (o.selected ? Colors.white10 : null),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: ring ? Colors.white : Colors.transparent,
                      width: 2.5))
              : BoxDecoration(color: o.selected ? Colors.white10 : null),
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: tv ? 14 : 12),
          child: Row(children: [
            Icon(
                o.selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: tv ? 26 : 22,
                color: o.selected ? _red : Colors.white38),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(o.label,
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: tv ? 17 : 15,
                            fontWeight:
                                o.selected ? FontWeight.w700 : FontWeight.w400)),
                    if (o.detail != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(o.detail!,
                              style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: tv ? 14 : 12.5))),
                  ]),
            ),
          ]),
        ),
      ),
    );
  }
}
