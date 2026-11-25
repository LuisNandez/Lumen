import 'dart:math' as math;

import 'package:flutter/material.dart';

const Color kLoaderAccent = Color(0xFFFF3B43);

/// Animación de carga (puerto a Flutter del `ElegantVideoLoader` de Compose):
/// anillo con arco rojo giratorio (1,2 s) y núcleo que pulsa (0,75 s, ida y vuelta).
class ElegantVideoLoader extends StatefulWidget {
  const ElegantVideoLoader({super.key, this.accentColor = kLoaderAccent});
  final Color accentColor;

  @override
  State<ElegantVideoLoader> createState() => _ElegantVideoLoaderState();
}

class _ElegantVideoLoaderState extends State<ElegantVideoLoader>
    with TickerProviderStateMixin {
  late final AnimationController _rotation = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat();
  late final AnimationController _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 750),
      lowerBound: 0.45,
      upperBound: 1.0)
    ..repeat(reverse: true);
  late final Animation<double> _pulseCurve =
      CurvedAnimation(parent: _pulse, curve: Curves.fastOutSlowIn);

  @override
  void dispose() {
    _rotation.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 86,
      height: 86,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: Listenable.merge([_rotation, _pulse]),
          builder: (_, __) => CustomPaint(
            painter: _LoaderPainter(
              rotationDeg: _rotation.value * 360.0,
              // Mismo rango que en Compose: 0.45 → 1.0 con curva FastOutSlowIn.
              pulse: 0.45 + (1.0 - 0.45) * _pulseCurve.value,
              accent: widget.accentColor,
            ),
          ),
        ),
      ),
    );
  }
}

class _LoaderPainter extends CustomPainter {
  _LoaderPainter(
      {required this.rotationDeg, required this.pulse, required this.accent});
  final double rotationDeg, pulse;
  final Color accent;

  static double _rad(double deg) => deg * math.pi / 180.0;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const ringRadius = 28.0;
    final rect = Rect.fromCircle(center: center, radius: ringRadius);
    final start = _rad(rotationDeg - 90.0);
    final sweep = _rad(110.0);

    Paint stroke(Color c, double w, {bool round = false}) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = round ? StrokeCap.round : StrokeCap.butt
      ..isAntiAlias = true;
    Paint fill(Color c) => Paint()
      ..color = c
      ..isAntiAlias = true;

    // Fondo circular discreto
    canvas.drawCircle(center, 43, fill(const Color(0xDD121317)));
    // Anillo fijo
    canvas.drawCircle(
        center, ringRadius, stroke(Colors.white.withOpacity(0.09), 2));
    // Halo exterior rojo
    canvas.drawArc(rect, start, sweep, false,
        stroke(accent.withOpacity(0.13), 7, round: true));
    // Arco rojo principal
    canvas.drawArc(rect, start, sweep, false, stroke(accent, 2.5, round: true));
    // Anillo interior
    canvas.drawCircle(center, 11, stroke(accent.withOpacity(0.17), 1));
    // Resplandor central
    canvas.drawCircle(
        center, 9 * pulse, fill(accent.withOpacity(0.16 * pulse)));
    // Núcleo pulsante
    canvas.drawCircle(center, 3 * pulse, fill(accent.withOpacity(pulse)));
  }

  @override
  bool shouldRepaint(_LoaderPainter old) =>
      old.rotationDeg != rotationDeg ||
      old.pulse != pulse ||
      old.accent != accent;
}
