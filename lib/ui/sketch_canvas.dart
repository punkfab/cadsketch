import 'package:flutter/material.dart';

import '../sketch/beautify.dart';
import '../sketch/entities.dart';
import '../sketch/model.dart';

/// Captures strokes; lines feed the parametric model (inferred + solved),
/// everything else is kept as a decorative entity. Constraints are rendered
/// as CAD-style glyphs over the geometry.
class SketchCanvas extends StatefulWidget {
  const SketchCanvas({super.key, required this.controller});

  final SketchController controller;

  @override
  State<SketchCanvas> createState() => _SketchCanvasState();
}

class _SketchCanvasState extends State<SketchCanvas> {
  List<Offset>? _active;

  void _start(Offset p) => setState(() => _active = [p]);
  void _extend(Offset p) => setState(() => _active?.add(p));

  void _end() {
    final stroke = _active;
    if (stroke != null && stroke.length >= 2) {
      widget.controller.addEntity(beautifyStroke(stroke));
    }
    setState(() => _active = null);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) => _start(e.localPosition),
      onPointerMove: (e) => _extend(e.localPosition),
      onPointerUp: (e) => _end(),
      onPointerCancel: (e) => _end(),
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) => CustomPaint(
          painter: _SketchPainter(widget.controller, _active),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class SketchController extends ChangeNotifier {
  final ParametricSketch model = ParametricSketch();
  final List<SketchEntity> decorations = [];

  void addEntity(SketchEntity e) {
    if (e is LineEntity) {
      model.addLine(e.a, e.b);
    } else {
      decorations.add(e);
    }
    notifyListeners();
  }

  void clear() {
    model.clear();
    decorations.clear();
    notifyListeners();
  }
}

class _SketchPainter extends CustomPainter {
  _SketchPainter(this.controller, this.active);

  final SketchController controller;
  final List<Offset>? active;

  static const _glyphColor = Color(0xFFFFC857);

  @override
  void paint(Canvas canvas, Size size) {
    final raw = Paint()
      ..color = Colors.blueGrey.shade400
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    final line = Paint()
      ..color = Colors.cyanAccent.shade400
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final node = Paint()..color = Colors.cyanAccent.shade100;
    final junction = Paint()
      ..color = _glyphColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    // Decorative entities (non-line).
    for (final e in controller.decorations) {
      switch (e) {
        case RawStroke(:final points):
          canvas.drawPath(_polyline(points), raw);
        case LineEntity():
          break; // lines live in the model
        case CircleEntity(:final center, :final radius):
          canvas.drawCircle(center, radius, line);
          canvas.drawCircle(center, 3, node);
        case ArcEntity(
            :final center,
            :final radius,
            :final startAngle,
            :final sweepAngle
          ):
          canvas.drawArc(Rect.fromCircle(center: center, radius: radius),
              startAngle, sweepAngle, false, line);
          canvas.drawCircle(center, 3, node);
      }
    }

    final m = controller.model;

    // Solved segments.
    for (final s in m.segments) {
      canvas.drawLine(m.points[s.a], m.points[s.b], line);
    }
    // Point nodes; shared points (degree >= 2) get a coincident ring.
    for (var i = 0; i < m.points.length; i++) {
      final p = m.points[i];
      canvas.drawCircle(p, 3, node);
      if (m.degree(i) >= 2) canvas.drawCircle(p, 6, junction);
    }
    // Constraint glyphs.
    for (final c in m.constraints) {
      _drawConstraint(canvas, m, c);
    }

    // In-progress stroke.
    final a = active;
    if (a != null && a.length >= 2) canvas.drawPath(_polyline(a), raw);
  }

  void _drawConstraint(Canvas canvas, ParametricSketch m, SketchConstraint c) {
    switch (c.kind) {
      case ConstraintKind.horizontal:
        _badgeText(canvas, _offsetMid(m, c.segments[0]), 'H');
      case ConstraintKind.vertical:
        _badgeText(canvas, _offsetMid(m, c.segments[0]), 'V');
      case ConstraintKind.perpendicular:
        final at = (_offsetMid(m, c.segments[0]) +
                _offsetMid(m, c.segments[1])) /
            2;
        _badgePaint(canvas, at, _drawPerp);
      case ConstraintKind.parallel:
        final at = (_offsetMid(m, c.segments[0]) +
                _offsetMid(m, c.segments[1])) /
            2;
        _badgePaint(canvas, at, _drawParallel);
    }
  }

  // Glyph anchor: segment midpoint pushed off the line along its normal.
  Offset _offsetMid(ParametricSketch m, int si) =>
      m.segMid(si) + m.segNormal(si) * 16;

  void _badgeBg(Canvas canvas, Offset center) {
    final r = RRect.fromRectAndRadius(
        Rect.fromCenter(center: center, width: 18, height: 18),
        const Radius.circular(4));
    canvas.drawRRect(r, Paint()..color = const Color(0xCC1A2026));
    canvas.drawRRect(
        r,
        Paint()
          ..color = _glyphColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
  }

  void _badgeText(Canvas canvas, Offset center, String label) {
    _badgeBg(canvas, center);
    final tp = TextPainter(
      text: TextSpan(
          text: label,
          style: const TextStyle(
              color: _glyphColor, fontSize: 11, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  void _badgePaint(Canvas canvas, Offset center, void Function(Canvas, Offset) sym) {
    _badgeBg(canvas, center);
    sym(canvas, center);
  }

  void _drawPerp(Canvas canvas, Offset c) {
    final p = Paint()
      ..color = _glyphColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    // A small right-angle symbol.
    canvas.drawLine(c + const Offset(-4, -5), c + const Offset(-4, 4), p);
    canvas.drawLine(c + const Offset(-4, 4), c + const Offset(5, 4), p);
    canvas.drawLine(c + const Offset(-4, 1), c + const Offset(-1, 1), p);
    canvas.drawLine(c + const Offset(-1, 1), c + const Offset(-1, 4), p);
  }

  void _drawParallel(Canvas canvas, Offset c) {
    final p = Paint()
      ..color = _glyphColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawLine(c + const Offset(-3, -5), c + const Offset(-3, 5), p);
    canvas.drawLine(c + const Offset(3, -5), c + const Offset(3, 5), p);
  }

  Path _polyline(List<Offset> pts) {
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    return path;
  }

  @override
  bool shouldRepaint(_SketchPainter old) => true;
}
