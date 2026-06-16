import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../ffi/sketch_kernel_ffi.dart';

// The parametric sketch: shared points, segments between them, and the
// constraints inferred among them. Lines drawn on the canvas feed in here;
// everything else (raw strokes, circles, arcs) stays decorative for now.
//
// Inference thresholds are tune-by-feel Dart constants on purpose (hot reload).
// The solve itself is delegated to the C++ kernel via FFI.

enum ConstraintKind { horizontal, vertical, perpendicular, parallel, equalLength }

/// Arc data attached to a segment whose endpoints (a, b) lie on a circle.
/// Center/radius are solver unknowns (point-on-circle), updated on solve.
class ArcData {
  ArcData(this.center, this.radius, this.sweep);
  Offset center;
  double radius;
  double sweep; // signed, from segment.a -> segment.b
}

class Segment {
  Segment(this.a, this.b);
  int a; // point index
  int b; // point index

  /// Driving length dimension. null => no driving dim (a measured/driven
  /// reference length is shown instead). When set, it becomes a distance
  /// constraint that drives the geometry.
  double? drivingLength;

  /// If non-null, this dimension is bound to a shared assembly parameter of
  /// this name; the controller keeps [drivingLength] in sync with it.
  String? lengthParam;

  /// If non-null, this segment is a circular arc (not a straight line).
  ArcData? arc;
  bool get isArc => arc != null;
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

  /// Two parallel segments whose lengths differ by less than this fraction are
  /// inferred equal-length (so opposite rectangle sides track together).
  static double equalLengthTolerance = 0.18;

  void clear() {
    points.clear();
    segments.clear();
    constraints.clear();
  }

  /// Adds a drawn line, inferring constraints against existing geometry, then
  /// re-solves the whole sketch in place.
  void addLine(Offset a, Offset b) {
    _addSegment(a, b);
    solve();
  }

  /// Adds a chain of connected segments (one stroke recognized as a polyline),
  /// inferring constraints for each, then solving once. Shared corners merge
  /// naturally because consecutive vertices coincide.
  void addPolyline(List<Offset> vertices) {
    var added = false;
    for (var i = 0; i + 1 < vertices.length; i++) {
      if (_addSegment(vertices[i], vertices[i + 1]) != null) added = true;
    }
    if (added) solve();
  }

  /// Adds one segment with inference but no solve. Returns its index, or null
  /// if it collapsed to zero length after merging.
  int? _addSegment(Offset a, Offset b) {
    final ia = _mergeOrAdd(a);
    final ib = _mergeOrAdd(b);
    if (ia == ib) return null;
    final si = segments.length;
    segments.add(Segment(ia, ib));
    _infer(si);
    return si;
  }

  /// Adds a circular arc as a segment whose endpoints merge with existing
  /// geometry (so it joins a contour), then re-solves. No line inference runs
  /// on arcs; their endpoints are held on the circle by the solver.
  void addArc(Offset start, Offset end, Offset center, double radius, double sweep) {
    final ia = _mergeOrAdd(start);
    final ib = _mergeOrAdd(end);
    if (ia == ib) return;
    segments.add(Segment(ia, ib)..arc = ArcData(center, radius, sweep));
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
    if (segments[si].isArc) return; // arcs don't get line constraints
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
      if (ti == si || segments[ti].isArc) continue;
      final acute = _acuteBetween(si, ti); // [0, pi/2]
      final isParallel = acute < relationAngleTolerance;
      final isPerp = (acute - math.pi / 2).abs() < relationAngleTolerance;

      // Equal-length: parallel + similar length. Runs even when both segments
      // are axis-locked, since that's exactly the opposite-rectangle-sides case
      // we want to link so a width dimension propagates.
      if (isParallel && _lengthsSimilar(si, ti)) {
        constraints.add(SketchConstraint(ConstraintKind.equalLength, [si, ti]));
      }

      // Perpendicular/parallel glyphs are redundant when both segments are
      // already axis-locked (the H/V constraints imply the relationship).
      if (sAxis && _hasAxis(ti)) continue;
      if (isPerp) {
        constraints.add(SketchConstraint(ConstraintKind.perpendicular, [si, ti]));
      } else if (isParallel) {
        constraints.add(SketchConstraint(ConstraintKind.parallel, [si, ti]));
      }
    }
  }

  bool _lengthsSimilar(int si, int ti) {
    final a = measuredLength(si);
    final b = measuredLength(ti);
    final m = math.max(a, b);
    if (m < 1e-6) return false;
    return (a - b).abs() / m <= equalLengthTolerance;
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
          case ConstraintKind.equalLength:
            final p = segments[c.segments[0]];
            final q = segments[c.segments[1]];
            s.equalLength(p.a, p.b, q.a, q.b);
        }
      }
      // Driving length dimensions become distance constraints (lines only).
      for (final seg in segments) {
        final len = seg.drivingLength;
        if (len != null && !seg.isArc) s.distance(seg.a, seg.b, len);
      }
      // Arcs: each gets a center point + radius unknown, with both endpoints
      // constrained onto the circle.
      final arcMeta = <(Segment, int, int)>[];
      for (final seg in segments) {
        final arc = seg.arc;
        if (arc == null) continue;
        final center = s.addPoint(arc.center);
        final rad = s.addRadius(arc.radius);
        s.pointOnCircle(seg.a, center, rad);
        s.pointOnCircle(seg.b, center, rad);
        arcMeta.add((seg, center, rad));
      }
      s.solve();
      for (var i = 0; i < points.length; i++) {
        points[i] = s.point(i);
      }
      for (final (seg, center, rad) in arcMeta) {
        seg.arc!
          ..center = s.point(center)
          ..radius = s.radius(rad);
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

  /// Returns the ordered point indices of a single closed profile loop, or
  /// null if the sketch isn't one simple closed polygon (the only case we
  /// extrude for now). Every point must have degree exactly 2.
  List<int>? closedLoop() {
    if (points.isEmpty || segments.length != points.length) return null;
    final adj = List.generate(points.length, (_) => <int>[]);
    for (final s in segments) {
      adj[s.a].add(s.b);
      adj[s.b].add(s.a);
    }
    if (adj.any((n) => n.length != 2)) return null;

    final loop = <int>[];
    var prev = -1;
    var cur = 0;
    do {
      loop.add(cur);
      final nbrs = adj[cur];
      final next = nbrs[0] != prev ? nbrs[0] : nbrs[1];
      prev = cur;
      cur = next;
      if (loop.length > points.length) return null; // not a single clean loop
    } while (cur != 0);
    return loop.length == points.length ? loop : null;
  }

  /// Ordered boundary of the closed contour as points, with arc edges
  /// tessellated. Null if there's no single closed loop. Used for extrusion.
  List<Offset>? closedProfile() {
    final loop = closedLoop();
    if (loop == null) return null;
    final profile = <Offset>[];
    for (var i = 0; i < loop.length; i++) {
      final ai = loop[i];
      final bi = loop[(i + 1) % loop.length];
      final seg = _segmentBetween(ai, bi);
      if (seg != null && seg.isArc) {
        // Traverse the arc in the loop's direction (negate sweep if reversed).
        final forward = seg.a == ai;
        final sweep = forward ? seg.arc!.sweep : -seg.arc!.sweep;
        profile.addAll(_tessellateArc(points[ai], seg.arc!.center, seg.arc!.radius, sweep));
      } else {
        profile.add(points[ai]);
      }
    }
    return profile;
  }

  Segment? _segmentBetween(int a, int b) {
    for (final s in segments) {
      if ((s.a == a && s.b == b) || (s.a == b && s.b == a)) return s;
    }
    return null;
  }

  /// Points along an arc from [start] (on the circle) sweeping [sweep] radians,
  /// excluding the end point (the next edge contributes it).
  List<Offset> _tessellateArc(Offset start, Offset center, double radius, double sweep) {
    final n = math.max(2, (sweep.abs() / 0.25).ceil());
    final a0 = math.atan2(start.dy - center.dy, start.dx - center.dx);
    return [
      for (var i = 0; i < n; i++)
        center +
            Offset(math.cos(a0 + sweep * i / n), math.sin(a0 + sweep * i / n)) *
                radius,
    ];
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

  /// Returns the nearest segment whose line is within [tolerance] of [p], or
  /// null. Lets a tap anywhere along an edge select it (much easier to hit than
  /// the small dimension label).
  int? hitTestSegment(Offset p, {double tolerance = 14}) {
    int? best;
    var bestDist = tolerance;
    for (var si = 0; si < segments.length; si++) {
      final s = segments[si];
      final d = _distanceToSegment(p, points[s.a], points[s.b]);
      if (d <= bestDist) {
        bestDist = d;
        best = si;
      }
    }
    return best;
  }

  double _distanceToSegment(Offset p, Offset a, Offset b) {
    final abx = b.dx - a.dx, aby = b.dy - a.dy;
    final len2 = abx * abx + aby * aby;
    if (len2 < 1e-9) return (p - a).distance;
    var t = ((p.dx - a.dx) * abx + (p.dy - a.dy) * aby) / len2;
    t = t.clamp(0.0, 1.0);
    return (p - Offset(a.dx + abx * t, a.dy + aby * t)).distance;
  }

  /// Sets (or clears, with null) a segment's driving length and re-solves.
  void setDrivingLength(int si, double? length) {
    segments[si].drivingLength = length;
    solve();
  }
}
