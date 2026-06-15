import 'package:flutter/material.dart';

import '../sketch/beautify.dart';
import '../sketch/entities.dart';

/// M0: capture strokes from pointer/stylus and render them.
/// M1: on pointer-up, beautify each stroke — straight ones snap to clean lines.
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
      widget.controller.add(beautifyStroke(stroke));
    }
    setState(() => _active = null);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      // Accept stylus, touch and mouse alike — the Huion shows up as one of these.
      onPointerDown: (e) => _start(e.localPosition),
      onPointerMove: (e) => _extend(e.localPosition),
      onPointerUp: (e) => _end(),
      onPointerCancel: (e) => _end(),
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) => CustomPaint(
          painter: _SketchPainter(widget.controller.entities, _active),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class SketchController extends ChangeNotifier {
  final List<SketchEntity> _entities = [];
  List<SketchEntity> get entities => List.unmodifiable(_entities);

  void add(SketchEntity e) {
    _entities.add(e);
    notifyListeners();
  }

  void clear() {
    _entities.clear();
    notifyListeners();
  }
}

class _SketchPainter extends CustomPainter {
  _SketchPainter(this.entities, this.active);

  final List<SketchEntity> entities;
  final List<Offset>? active;

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

    for (final e in entities) {
      switch (e) {
        case RawStroke(:final points):
          canvas.drawPath(_polyline(points), raw);
        case LineEntity(:final a, :final b):
          canvas.drawLine(a, b, line);
          canvas.drawCircle(a, 3, node);
          canvas.drawCircle(b, 3, node);
        case CircleEntity(:final center, :final radius):
          canvas.drawCircle(center, radius, line);
          canvas.drawCircle(center, 3, node);
        case ArcEntity(
            :final center,
            :final radius,
            :final startAngle,
            :final sweepAngle
          ):
          canvas.drawArc(
            Rect.fromCircle(center: center, radius: radius),
            startAngle,
            sweepAngle,
            false,
            line,
          );
          canvas.drawCircle(center, 3, node);
          canvas.drawCircle(
              center + Offset.fromDirection(startAngle, radius), 3, node);
          canvas.drawCircle(
              center + Offset.fromDirection(startAngle + sweepAngle, radius),
              3,
              node);
      }
    }

    final a = active;
    if (a != null && a.length >= 2) {
      canvas.drawPath(_polyline(a), raw);
    }
  }

  Path _polyline(List<Offset> pts) {
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    return path;
  }

  @override
  bool shouldRepaint(_SketchPainter old) =>
      old.entities != entities || old.active != active;
}
