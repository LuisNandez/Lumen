import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Loader mínimo (puerto a Flutter del `MinimalVideoLoader` de Compose):
/// anillo tenue con un arco de 85° que gira una vuelta cada 850 ms.
class MinimalVideoLoader extends StatefulWidget {
  const MinimalVideoLoader({super.key, this.color = const Color(0xFFEF343D)});
  final Color color;

  @override
  State<MinimalVideoLoader> createState() => _MinimalVideoLoaderState();
}

class _MinimalVideoLoaderState extends State<MinimalVideoLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 850))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 38,
      height: 38,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) => CustomPaint(
              painter: _MinimalPainter(_c.value * 360.0, widget.color)),
        ),
      ),
    );
  }
}

class _MinimalPainter extends CustomPainter {
  _MinimalPainter(this.rotationDeg, this.color);
  final double rotationDeg;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const width = 2.5;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..isAntiAlias = true;
    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(
        center, size.shortestSide / 2, p..color = Colors.white.withOpacity(0.11));
    canvas.drawArc(
        Offset.zero & size,
        (rotationDeg - 90.0) * math.pi / 180.0,
        85.0 * math.pi / 180.0,
        false,
        p..color = color);
  }

  @override
  bool shouldRepaint(_MinimalPainter old) =>
      old.rotationDeg != rotationDeg || old.color != color;
}
