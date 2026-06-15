import 'dart:ui' show Offset;

// Sketch entity model. Deliberately minimal for M0/M1 — this is the structure
// that will eventually be serialized to JSON for the AI assistant (M5) and
// handed to the constraint solver (M2), so keep it clean and frontend-agnostic.

sealed class SketchEntity {
  const SketchEntity();
}

/// A raw freehand stroke that wasn't recognized as a primitive yet.
class RawStroke extends SketchEntity {
  const RawStroke(this.points);
  final List<Offset> points;
}

/// A clean, snapped line segment (the M1 beautification result).
class LineEntity extends SketchEntity {
  const LineEntity(this.a, this.b);
  final Offset a;
  final Offset b;
}

/// A full circle.
class CircleEntity extends SketchEntity {
  const CircleEntity(this.center, this.radius);
  final Offset center;
  final double radius;
}

/// A circular arc. Angles are in radians in screen space (atan2(dy, dx), so
/// positive sweep is clockwise on screen — matching Canvas.drawArc).
class ArcEntity extends SketchEntity {
  const ArcEntity(this.center, this.radius, this.startAngle, this.sweepAngle);
  final Offset center;
  final double radius;
  final double startAngle;
  final double sweepAngle;
}
