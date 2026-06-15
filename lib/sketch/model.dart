import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../ffi/sketch_kernel_ffi.dart';

// The parametric sketch: shared points, segments between them, and the
// constraints inferred among them. Lines drawn on the canvas feed in here;
// everything else (raw strokes, circles, arcs) stays decorative for now.
//
// Inference thresholds are tune-by-feel Dart constants on purpose (hot reload).
// The solve itself is delegated to the C++ kernel via FFI.

enum ConstraintKind { horizontal, vertical, perpendicular, parallel }

class Segment {
  Segment(this.a, this.b);
  int a; // point index
  int b; // point index

  /// Driving length dimension. null => no driving dim (a measured/driven
  /// reference length is shown instead). When set, it becomes a distance
  /// constraint that drives the geometry.
  double? drivingLength;
}

class SketchConstraint {
  SketchConstraint(this.kind, this.segments);
  final ConstraintKind kind;
  final List<int> segments; // 1 segment for H/V, 2 for perpendicular/parallel
}

class ParametricSketch {
  final List<Offset> points = [];
  final List<Segment> segments = [];
  final List<SketchConstraint> constraints = [];

  // --- Tunables (hot-reloadable) ---
  /// Endpoints within this distance (logical px) merge into one shared point.
  static double mergeTolerance = 16.0;

  /// How close to an axis (radians) a segment must be to be called H/V.
  static double axisAngleTolerance = 0.14; // ~8°

  /// How close to 0°/90° two segments must be to infer parallel/perpendicular.
  static double relationAngleTolerance = 0.14;

  void clear() {
    points.clear();
    segments.clear();
    constraints.clear();
  }

  /// Adds a drawn line, inferring constraints against existing geometry, then
  /// re-solves the whole sketch in place.
  void addLine(Offset a, Offset b) {
    final ia = _mergeOrAdd(a);
    final ib = _mergeOrAdd(b);
    if (ia == ib) return; // zero-length after merge
    final si = segments.length;
    segments.add(Segment(ia, ib));
    _infer(si);
    solve();
  }

  int _mergeOrAdd(Offset p) {
    for (var i = 0; i < points.length; i++) {
      if ((points[i] - p).distance <= mergeTolerance) return i;
    }
    points.add(p);
    return points.length - 1;
  }

  void _infer(int si) {
    final ang = _segAngle(si); // undirected, [0, pi)
    final isH = ang < axisAngleTolerance || ang > math.pi - axisAngleTolerance;
    final isV = (ang - math.pi / 2).abs() < axisAngleTolerance;

    var sAxis = false;
    if (isH) {
      constraints.add(SketchConstraint(ConstraintKind.horizontal, [si]));
      sAxis = true;
    } else if (isV) {
      constraints.add(SketchConstraint(ConstraintKind.vertical, [si]));
      sAxis = true;
    }

    for (var ti = 0; ti < segments.length; ti++) {
      if (ti == si) continue;
      // If both segments are already axis-locked, their relationship is implied
      // — don't clutter with a redundant perpendicular/parallel glyph.
      if (sAxis && _hasAxis(ti)) continue;
      final acute = _acuteBetween(si, ti); // [0, pi/2]
      if ((acute - math.pi / 2).abs() < relationAngleTolerance) {
        constraints.add(SketchConstraint(ConstraintKind.perpendicular, [si, ti]));
      } else if (acute < relationAngleTolerance) {
        constraints.add(SketchConstraint(ConstraintKind.parallel, [si, ti]));
      }
    }
  }

  bool _hasAxis(int seg) => constraints.any((c) =>
      (c.kind == ConstraintKind.horizontal ||
          c.kind == ConstraintKind.vertical) &&
      c.segments.first == seg);

  /// Builds a kernel sketch from the model, solves, and reads positions back.
  /// LM only accepts downhill steps, so results are never worse than as-drawn.
  void solve() {
    if (segments.isEmpty) return;
    final s = SketchKernel.instance.newSketch();
    try {
      for (final p in points) {
        s.addPoint(p); // kernel id == list index
      }
      s.fixPoint(0); // anchor one point to remove the translation DOF
      for (final c in constraints) {
        switch (c.kind) {
          case ConstraintKind.horizontal:
            final seg = segments[c.segments[0]];
            s.horizontal(seg.a, seg.b);
          case ConstraintKind.vertical:
            final seg = segments[c.segments[0]];
            s.vertical(seg.a, seg.b);
          case ConstraintKind.perpendicular:
            final p = segments[c.segments[0]];
            final q = segments[c.segments[1]];
            s.perpendicular(p.a, p.b, q.a, q.b);
          case ConstraintKind.parallel:
            final p = segments[c.segments[0]];
            final q = segments[c.segments[1]];
            s.parallel(p.a, p.b, q.a, q.b);
        }
      }
      // Driving length dimensions become distance constraints.
      for (final seg in segments) {
        final len = seg.drivingLength;
        if (len != null) s.distance(seg.a, seg.b, len);
      }
      s.solve();
      for (var i = 0; i < points.length; i++) {
        points[i] = s.point(i);
      }
    } finally {
      s.dispose();
    }
  }

  // --- Geometry helpers (used by inference and the painter) ---

  double _segAngle(int si) {
    final s = segments[si];
    final d = points[s.b] - points[s.a];
    var a = math.atan2(d.dy, d.dx);
    if (a < 0) a += math.pi; // collapse to undirected [0, pi)
    return a;
  }

  double _acuteBetween(int si, int ti) {
    final d = (_segAngle(si) - _segAngle(ti)).abs();
    return math.min(d, math.pi - d);
  }

  Offset segMid(int si) {
    final s = segments[si];
    return (points[s.a] + points[s.b]) / 2;
  }

  /// Unit normal of a segment (for offsetting glyphs off the line).
  Offset segNormal(int si) {
    final s = segments[si];
    final d = points[s.b] - points[s.a];
    final len = d.distance;
    if (len < 1e-6) return Offset.zero;
    return Offset(-d.dy / len, d.dx / len);
  }

  int degree(int pointIndex) {
    var n = 0;
    for (final s in segments) {
      if (s.a == pointIndex || s.b == pointIndex) n++;
    }
    return n;
  }

  double measuredLength(int si) {
    final s = segments[si];
    return (points[s.b] - points[s.a]).distance;
  }

  /// Anchor for a segment's dimension label — midpoint pushed to the opposite
  /// side from the constraint glyphs so they don't overlap.
  Offset dimAnchor(int si) => segMid(si) - segNormal(si) * 16;

  /// Returns the segment whose dimension label is within [radius] of [p], or
  /// null. Used to route taps to dimension editing.
  int? hitTestDimension(Offset p, {double radius = 18}) {
    for (var si = 0; si < segments.length; si++) {
      if ((dimAnchor(si) - p).distance <= radius) return si;
    }
    return null;
  }

  /// Sets (or clears, with null) a segment's driving length and re-solves.
  void setDrivingLength(int si, double? length) {
    segments[si].drivingLength = length;
    solve();
  }
}
