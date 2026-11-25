import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:server_core/server_core.dart';

/// Editor para dejar cualquier imagen lista como avatar (JPG cuadrado de 512 px).
/// Devuelve el id del avatar guardado, o null si se cancela.
Future<String?> showAvatarEditor(
        BuildContext context, MediaServer server, String imagePath) =>
    showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AvatarEditor(server: server, imagePath: imagePath),
    );

double _cl(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

class _AvatarEditor extends StatefulWidget {
  const _AvatarEditor({required this.server, required this.imagePath});
  final MediaServer server;
  final String imagePath;

  @override
  State<_AvatarEditor> createState() => _AvatarEditorState();
}

class _AvatarEditorState extends State<_AvatarEditor> {
  static const double _view = 360; // lado de la vista previa en pantalla
  static const _rootPack = ''; // "carpeta principal" en el selector
  static const _newPack = '\u0001nuevo'; // opción "Crear paquete nuevo..."
  static String _lastPack = _rootPack; // se recuerda el último paquete elegido

  late List<String> _packs;
  String _pack = _rootPack;
  static const _maxZoom = 4.0;

  AvatarSource? _src;
  String? _error;
  late final TextEditingController _id;
  AvatarFit _fit = AvatarFit.cover;
  AvatarBackground _bg = AvatarBackground.blur;
  double _zoom = 1, _dx = 0, _dy = 0;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _packs = widget.server.avatarPacks();
    if (_packs.contains(_lastPack)) _pack = _lastPack;
    _id = TextEditingController(
        text: widget.server.suggestAvatarId(widget.imagePath, pack: _pack));
    _load();
  }

  @override
  void dispose() {
    _id.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await widget.server.openAvatarImage(widget.imagePath);
      if (!mounted) return;
      setState(() => _src = s);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error =
          e is FormatException ? e.message : 'No se pudo abrir la imagen: $e');
    }
  }

  Color get _solid {
    switch (_bg) {
      case AvatarBackground.white:
        return Colors.white;
      case AvatarBackground.black:
        return Colors.black;
      case AvatarBackground.dark:
      case AvatarBackground.blur:
        return const Color(0xFF202024);
    }
  }

  void _center() => setState(() {
        _zoom = 1;
        _dx = 0;
        _dy = 0;
      });

  void _pan(DragUpdateDetails d, AvatarSource src) {
    if (_fit != AvatarFit.cover) return;
    final w = src.width.toDouble(), h = src.height.toDouble();
    final side = math.min(w, h) / _zoom;
    final s = _view / side; // píxeles de pantalla por píxel de la imagen
    final freeX = (w - side) / 2, freeY = (h - side) / 2;
    setState(() {
      if (freeX > 0.5) _dx = _cl(_dx - d.delta.dx / (s * freeX), -1, 1);
      if (freeY > 0.5) _dy = _cl(_dy - d.delta.dy / (s * freeY), -1, 1);
    });
  }

  Widget _img(AvatarSource src) => Image.memory(src.preview,
      fit: BoxFit.fill, filterQuality: FilterQuality.medium, gaplessPlayback: true);

  Widget _blurredBackground(AvatarSource src) {
    final w = src.width.toDouble(), h = src.height.toDouble();
    final s = _view / math.min(w, h); // "cover"
    return ClipRect(
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Stack(children: [
          Positioned(
              left: (_view - w * s) / 2,
              top: (_view - h * s) / 2,
              width: w * s,
              height: h * s,
              child: _img(src)),
        ]),
      ),
    );
  }

  Widget _canvas(AvatarSource src) {
    final w = src.width.toDouble(), h = src.height.toDouble();
    if (_fit == AvatarFit.cover) {
      final side = math.min(w, h) / _zoom;
      final s = _view / side;
      final x0 = (w - side) / 2 * (1 + _dx);
      final y0 = (h - side) / 2 * (1 + _dy);
      return Stack(children: [
        Positioned.fill(child: ColoredBox(color: _solid)), // por si la imagen es transparente
        Positioned(left: -x0 * s, top: -y0 * s, width: w * s, height: h * s, child: _img(src)),
      ]);
    }
    final s = _view / math.max(w, h);
    final tw = w * s, th = h * s;
    return Stack(children: [
      Positioned.fill(
          child: _bg == AvatarBackground.blur
              ? _blurredBackground(src)
              : ColoredBox(color: _solid)),
      Positioned(
          left: (_view - tw) / 2,
          top: (_view - th) / 2,
          width: tw,
          height: th,
          child: _img(src)),
    ]);
  }

  Widget _viewport(AvatarSource src) {
    return Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent && _fit == AvatarFit.cover) {
          setState(() => _zoom = _cl(_zoom - e.scrollDelta.dy / 400, 1, _maxZoom));
        }
      },
      child: MouseRegion(
        cursor: _fit == AvatarFit.cover ? SystemMouseCursors.grab : MouseCursor.defer,
        child: GestureDetector(
          onPanUpdate: (d) => _pan(d, src),
          child: SizedBox(
            width: _view,
            height: _view,
            child: ClipRect(
              child: Stack(children: [
                Positioned.fill(child: _canvas(src)),
                const Positioned.fill(
                    child: IgnorePointer(child: CustomPaint(painter: _CircleGuide()))),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  /// Selector de destino: carpeta principal, paquetes existentes o uno nuevo.
  Widget _packPicker() => InputDecorator(
        decoration: const InputDecoration(
            labelText: 'Guardar en',
            isDense: true,
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.folder_outlined, size: 20)),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            isExpanded: true,
            isDense: true,
            value: _pack,
            items: [
              const DropdownMenuItem(
                  value: _rootPack, child: Text('Carpeta principal (sin paquete)')),
              for (final n in _packs)
                DropdownMenuItem(value: n, child: Text(n, overflow: TextOverflow.ellipsis)),
              const DropdownMenuItem(
                  value: _newPack,
                  child: Row(children: [
                    Icon(Icons.create_new_folder_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('Crear paquete nuevo…'),
                  ])),
            ],
            onChanged: _saving ? null : _onPack,
          ),
        ),
      );

  Future<void> _onPack(String? v) async {
    if (v == null) return;
    if (v != _newPack) {
      setState(() {
        _pack = v;
        _lastPack = v;
        _error = null;
      });
      return;
    }
    final created = await showDialog<String>(
        context: context, builder: (_) => _NewPackDialog(server: widget.server));
    if (created == null || !mounted) return; // cancelado: se queda el que estaba
    setState(() {
      _packs = widget.server.avatarPacks();
      _pack = created;
      _lastPack = created;
      _error = null;
    });
  }

  Future<void> _save() async {
    final id = _id.text.trim();
    if (!isValidAvatarId(id)) {
      setState(() => _error =
          'El nombre solo admite letras, números, - y _ (sin espacios ni acentos).');
      return;
    }
    var overwrite = false;
    final pack = _pack.isEmpty ? null : _pack;
    if (widget.server.avatarIdTaken(id, pack: pack)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Ya existe ese avatar'),
          content: Text('Ya hay un avatar llamado "$id"'
              '${pack == null ? '' : ' en el paquete "$pack"'}. ¿Quieres reemplazarlo?\n\n'
              'Los perfiles que lo usan mostrarán la imagen nueva.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reemplazar')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      overwrite = true;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.server.importAvatar(widget.imagePath,
          id: id,
          pack: pack,
          overwrite: overwrite,
          crop: AvatarCrop(fit: _fit, zoom: _zoom, dx: _dx, dy: _dy, background: _bg));
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is FormatException
            ? e.message
            : (e is StateError ? e.message : 'No se pudo guardar: $e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final src = _src;
    return AlertDialog(
      title: const Text('Añadir avatar'),
      content: SizedBox(
        width: _view + 8,
        child: src == null
            ? SizedBox(
                height: 120,
                child: Center(
                    child: _error != null
                        ? Text(_error!, style: const TextStyle(color: Colors.redAccent))
                        : const CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  _viewport(src),
                  const SizedBox(height: 6),
                  Text(
                      _fit == AvatarFit.cover
                          ? 'Arrastra para encuadrar y usa la rueda o el control para acercar. '
                              'La app solo muestra lo que queda dentro del círculo.'
                          : 'La imagen entera, centrada, sobre el fondo elegido.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white60, fontSize: 12)),
                  const SizedBox(height: 10),
                  SegmentedButton<AvatarFit>(
                    segments: const [
                      ButtonSegment(
                          value: AvatarFit.cover,
                          icon: Icon(Icons.crop),
                          label: Text('Recortar')),
                      ButtonSegment(
                          value: AvatarFit.contain,
                          icon: Icon(Icons.fit_screen_outlined),
                          label: Text('Ajustar entera')),
                    ],
                    selected: {_fit},
                    onSelectionChanged: (v) => setState(() => _fit = v.first),
                  ),
                  if (_fit == AvatarFit.cover)
                    Row(children: [
                      const Icon(Icons.zoom_out, size: 18),
                      Expanded(
                          child: Slider(
                              value: _zoom,
                              min: 1,
                              max: _maxZoom,
                              onChanged: (v) => setState(() => _zoom = v))),
                      const Icon(Icons.zoom_in, size: 18),
                      const SizedBox(width: 4),
                      IconButton(
                          tooltip: 'Centrar',
                          icon: const Icon(Icons.center_focus_strong),
                          onPressed: _center),
                    ])
                  else
                    const SizedBox(height: 8),
                  Wrap(spacing: 8, children: [
                    for (final e in const {
                      AvatarBackground.blur: 'Difuminado',
                      AvatarBackground.dark: 'Oscuro',
                      AvatarBackground.white: 'Blanco',
                      AvatarBackground.black: 'Negro',
                    }.entries)
                      ChoiceChip(
                          label: Text(e.value),
                          selected: _bg == e.key,
                          onSelected: (_) => setState(() => _bg = e.key)),
                  ]),
                  const SizedBox(height: 10),
                  _packPicker(),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _id,
                    decoration: const InputDecoration(
                        labelText: 'Nombre del avatar',
                        suffixText: '.jpg',
                        isDense: true,
                        border: OutlineInputBorder()),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                  ],
                ]),
              ),
      ),
      actions: [
        TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: Text(src == null && _error != null ? 'Cerrar' : 'Cancelar')),
        if (src != null)
          FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label: const Text('Guardar')),
      ],
    );
  }
}

/// Pide el nombre de un paquete nuevo y lo crea (subcarpeta). Devuelve su nombre.
class _NewPackDialog extends StatefulWidget {
  const _NewPackDialog({required this.server});
  final MediaServer server;

  @override
  State<_NewPackDialog> createState() => _NewPackDialogState();
}

class _NewPackDialogState extends State<_NewPackDialog> {
  final _c = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _create() {
    try {
      Navigator.pop(context, widget.server.createAvatarPack(_c.text));
    } on FormatException catch (e) {
      setState(() => _err = e.message);
    } catch (e) {
      setState(() => _err = 'No se pudo crear la carpeta: $e');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Nuevo paquete'),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: _c,
            autofocus: true,
            maxLength: 64,
            decoration: InputDecoration(
                labelText: 'Nombre del paquete',
                helperText: 'Se crea una carpeta con este nombre en la carpeta de avatares.',
                helperMaxLines: 2,
                errorText: _err,
                border: const OutlineInputBorder()),
            onChanged: (_) {
              if (_err != null) setState(() => _err = null);
            },
            onSubmitted: (_) => _create(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(onPressed: _create, child: const Text('Crear')),
        ],
      );
}

/// Oscurece lo que queda fuera del círculo (lo que la app recorta) y dibuja el borde.
class _CircleGuide extends CustomPainter {
  const _CircleGuide();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shade = Path.combine(
        PathOperation.difference, Path()..addRect(rect), Path()..addOval(rect));
    canvas.drawPath(shade, Paint()..color = const Color(0x99000000));
    canvas.drawOval(
        rect.deflate(0.75),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.white70);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
