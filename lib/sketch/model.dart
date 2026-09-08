import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../ffi/sketch_kernel.dart';

// The parametric sketch: shared points, segments between them, and the
// constraints inferred among them. Lines drawn on the canvas feed in here;
// everything else (raw strokes, circles, arcs) stays decorative for now.
//
// Inference thresholds are tune-by-feel Dart constants on purpose (hot reload).
// The solve itself is delegated to the C++ kernel via FFI.

enum ConstraintKind {
  horizontal,
  vertical,
  perpendicular,
  parallel,
  equalLength,
  tangent, // segments[0] = line, segments[1] = arc
}

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

  /// How close to perpendicular (line vs radius at the shared point) a line and
  /// an adjacent arc must be to infer tangency. ~17°.
  static double tangentAngleTolerance = 0.3;

  /// Two parallel segments whose lengths differ by less than this fraction are
  /// inferred equal-length (so opposite rectangle sides track together).
  static double equalLengthTolerance = 0.18;

  void clear() {
    points.clear();
    segments.clear();
    constraints.clear();
  }

  /// A deep copy: points (Offsets are values), segments (with their arc /
  /// dimension state), and constraints are all duplicated into a fresh sketch.
  ParametricSketch clone() {
    final s = ParametricSketch();
    s.points.addAll(points);
    for (final seg in segments) {
      final ns = Segment(seg.a, seg.b)
        ..drivingLength = seg.drivingLength
        ..lengthParam = seg.lengthParam;
      final arc = seg.arc;
      if (arc != null) ns.arc = ArcData(arc.center, arc.radius, arc.sweep);
      s.segments.add(ns);
    }
    for (final c in constraints) {
      s.constraints.add(SketchConstraint(c.kind, List<int>.from(c.segments)));
    }
    return s;
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

  /// Adds imported line geometry (e.g. from DXF) FAITHFULLY: welds endpoints
  /// that coincide within [weld], but runs no constraint inference and no solve,
  /// so the profile matches the source drawing exactly (the solver would
  /// otherwise snap near-axis edges and distort a precise import). The caller
  /// pre-tessellates arcs into short segments. Points already in the sketch are
  /// reused as weld targets.
  void addImportedLines(List<(Offset, Offset)> lines, {double weld = 1e-6}) {
    int idx(Offset p) {
      for (var i = 0; i < points.length; i++) {
        if ((points[i] - p).distance <= weld) return i;
      }
      points.add(p);
      return points.length - 1;
    }

    for (final (a, b) in lines) {
      final ia = idx(a), ib = idx(b);
      if (ia != ib) segments.add(Segment(ia, ib));
    }
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
    _inferTangency(si);
    return si;
  }

  /// Adds a circular arc as a segment whose endpoints merge with existing
  /// geometry (so it joins a contour), then re-solves. No line inference runs
  /// on arcs; their endpoints are held on the circle by the solver.
  void addArc(Offset start, Offset end, Offset center, double radius, double sweep) {
    final ia = _mergeOrAdd(start);
    final ib = _mergeOrAdd(end);
    if (ia == ib) return;
    final si = segments.length;
    segments.add(Segment(ia, ib)..arc = ArcData(center, radius, sweep));
    _inferTangency(si);
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

  /// Infers tangency between segment [si] and any adjacent segment of the other
  /// kind (one line, one arc) sharing a point, when the line is ~perpendicular
  /// to the arc's radius there (i.e. tangent to the circle).
  void _inferTangency(int si) {
    final s = segments[si];
    for (var ti = 0; ti < segments.length; ti++) {
      if (ti == si) continue;
      final t = segments[ti];
      if (s.isArc == t.isArc) continue; // need exactly one line + one arc
      final int lineIdx = s.isArc ? ti : si;
      final int arcIdx = s.isArc ? si : ti;
      final line = segments[lineIdx];
      final arc = segments[arcIdx];

      final shared = _sharedPoint(line, arc);
      if (shared == null) continue;
      if (_hasTangent(lineIdx, arcIdx)) continue;

      final radial = points[shared] - arc.arc!.center;
      final other = line.a == shared ? line.b : line.a;
      final dir = points[other] - points[shared];
      if (radial.distance < 1e-6 || dir.distance < 1e-6) continue;
      final cosA = (radial.dx * dir.dx + radial.dy * dir.dy) /
          (radial.distance * dir.distance);
      final angle = math.acos(cosA.clamp(-1.0, 1.0));
      if ((angle - math.pi / 2).abs() < tangentAngleTolerance) {
        constraints.add(SketchConstraint(ConstraintKind.tangent, [lineIdx, arcIdx]));
      }
    }
  }

  int? _sharedPoint(Segment a, Segment b) {
    if (a.a == b.a || a.a == b.b) return a.a;
    if (a.b == b.a || a.b == b.b) return a.b;
    return null;
  }

  bool _hasTangent(int lineIdx, int arcIdx) => constraints.any((c) =>
      c.kind == ConstraintKind.tangent &&
      c.segments[0] == lineIdx &&
      c.segments[1] == arcIdx);

  /// Builds a kernel sketch from the model, solves, and reads positions back.
  /// LM only accepts downhill steps, so results are never worse than as-drawn.
  ///
  /// [drag] pins an additional point (beyond the translation anchor) at its
  /// current position, so dragging a vertex holds it under the cursor while the
  /// rest of the sketch relaxes around it.
  void solve({int? drag}) {
    if (segments.isEmpty) return;
    final s = SketchKernel.instance.newSketch();
    try {
      for (final p in points) {
        s.addPoint(p); // kernel id == list index
      }
      s.fixPoint(0); // anchor one point to remove the translation DOF
      if (drag != null && drag != 0 && drag >= 0 && drag < points.length) {
        s.fixPoint(drag); // hold the dragged vertex; the rest relaxes
      }
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
          case ConstraintKind.tangent:
            break; // applied after arc centers/radii are created (below)
        }
      }
      // Driving length dimensions become distance constraints (lines only).
      for (final seg in segments) {
        final len = seg.drivingLength;
        if (len != null && !seg.isArc) s.distance(seg.a, seg.b, len);
      }
      // Arcs: each gets a center point + radius unknown, with both endpoints
      // constrained onto the circle. Keyed by segment index for tangents.
      final arcMeta = <int, ({int center, int rad})>{};
      for (var si = 0; si < segments.length; si++) {
        final arc = segments[si].arc;
        if (arc == null) continue;
        final center = s.addPoint(arc.center);
        final rad = s.addRadius(arc.radius);
        s.pointOnCircle(segments[si].a, center, rad);
        s.pointOnCircle(segments[si].b, center, rad);
        arcMeta[si] = (center: center, rad: rad);
      }
      // Tangency: line tangent to the adjacent arc's circle.
      for (final c in constraints) {
        if (c.kind != ConstraintKind.tangent) continue;
        final line = segments[c.segments[0]];
        final meta = arcMeta[c.segments[1]];
        if (meta != null) s.tangentLine(line.a, line.b, meta.center, meta.rad);
      }
      s.solve();
      for (var i = 0; i < points.length; i++) {
        points[i] = s.point(i);
      }
      for (final entry in arcMeta.entries) {
        segments[entry.key].arc!
          ..center = s.point(entry.value.center)
          ..radius = s.radius(entry.value.rad);
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
    return loop == null ? null : _profileForLoop(loop);
  }

  /// Every disjoint closed loop of the sketch (each vertex degree 2). Lets a
  /// sketched inner loop be treated as a hole. Null if the graph isn't a clean
  /// set of simple cycles.
  List<List<int>>? allClosedLoops() {
    if (points.isEmpty || segments.length != points.length) return null;
    final adj = List.generate(points.length, (_) => <int>[]);
    for (final s in segments) {
      adj[s.a].add(s.b);
      adj[s.b].add(s.a);
    }
    if (adj.any((n) => n.length != 2)) return null;

    final visited = List.filled(points.length, false);
    final loops = <List<int>>[];
    for (var start = 0; start < points.length; start++) {
      if (visited[start]) continue;
      final loop = <int>[];
      var prev = -1, cur = start;
      do {
        visited[cur] = true;
        loop.add(cur);
        final nbrs = adj[cur];
        final next = nbrs[0] != prev ? nbrs[0] : nbrs[1];
        prev = cur;
        cur = next;
        if (loop.length > points.length) return null;
      } while (cur != start);
      loops.add(loop);
    }
    return loops;
  }

  /// Tessellated profiles for every closed loop (see [allClosedLoops]).
  List<List<Offset>> allProfiles() =>
      [for (final loop in allClosedLoops() ?? const <List<int>>[]) _profileForLoop(loop)];

  List<Offset> _profileForLoop(List<int> loop) {
    final profile = <Offset>[];
    for (var i = 0; i < loop.length; i++) {
      final ai = loop[i];
      final bi = loop[(i + 1) % loop.length];
      final seg = _segmentBetween(ai, bi);
      if (seg != null && seg.isArc) {
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

  // --- Direct manipulation: drag a vertex, delete geometry ---

  /// Index of the nearest point handle within [radius] (logical px) of [p], or
  /// null. Lets a press grab a vertex to drag it. [exclude] skips one index
  /// (the vertex being dragged, when looking for a weld target).
  int? hitTestPoint(Offset p, {double radius = 14, int? exclude}) {
    int? best;
    var bestDist = radius;
    for (var i = 0; i < points.length; i++) {
      if (i == exclude) continue;
      final d = (points[i] - p).distance;
      if (d <= bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  /// Welds point [from] onto [into] (a coincidence): repoints every segment,
  /// drops any that collapse to zero length, prunes the now-unused [from], and
  /// re-solves. This is how dragging a vertex onto another closes a path or
  /// joins two chains. Returns the surviving vertex index.
  int mergePoints(int from, int into) {
    if (from == into ||
        from < 0 ||
        into < 0 ||
        from >= points.length ||
        into >= points.length) {
      return into;
    }
    for (final s in segments) {
      if (s.a == from) s.a = into;
      if (s.b == from) s.b = into;
    }
    final collapsed = <int>{
      for (var i = 0; i < segments.length; i++)
        if (segments[i].a == segments[i].b) i
    };
    if (collapsed.isNotEmpty) {
      _removeSegments(collapsed); // remaps constraints, prunes from, re-solves
    } else {
      _pruneOrphanPoints();
      solve();
    }
    // Only `from` is newly orphaned, so indices above it shift down by one.
    return into > from ? into - 1 : into;
  }

  /// Moves point [pi] to [to] and re-solves with that vertex pinned, so the
  /// rest of the sketch relaxes around it while constraints hold elsewhere.
  void dragPoint(int pi, Offset to) {
    if (pi < 0 || pi >= points.length) return;
    points[pi] = to;
    solve(drag: pi);
  }

  /// Removes constraint [i] and re-solves (so the geometry relaxes without it).
  void removeConstraint(int i) {
    if (i < 0 || i >= constraints.length) return;
    constraints.removeAt(i);
    solve();
  }

  /// True if a constraint of [kind] over segment set [segs] already exists.
  /// Two-segment relations (parallel/perp/equal) are compared unordered.
  bool hasConstraint(ConstraintKind kind, List<int> segs) {
    for (final c in constraints) {
      if (c.kind != kind) continue;
      if (segs.length == 1) {
        if (c.segments.isNotEmpty && c.segments[0] == segs[0]) return true;
      } else if (c.segments.length == segs.length &&
          c.segments.toSet().containsAll(segs)) {
        return true;
      }
    }
    return false;
  }

  /// While dragging point [pi] toward [raw], snap it so the edges touching it
  /// line up with an axis (horizontal / vertical) or become parallel /
  /// perpendicular to a nearby edge, when they're within [snapAngle] of that
  /// alignment. Returns the snapped target and the NEW constraint candidates
  /// that hold there (existing constraints are not repeated). The caller moves
  /// the point to [target] live and applies [candidates] on release — so the
  /// alignment then persists until deleted. Snap-and-apply inference.
  ({Offset target, List<SketchConstraint> candidates}) snapDrag(int pi, Offset raw,
      {double snapAngle = 0.12}) {
    final incident = <int>[]; // segments touching pi (straight lines only)
    for (var si = 0; si < segments.length; si++) {
      final s = segments[si];
      if (s.isArc) continue;
      if (s.a == pi || s.b == pi) incident.add(si);
    }
    if (incident.isEmpty) return (target: raw, candidates: const []);

    var target = raw;
    final candidates = <SketchConstraint>[];

    // Pass 1: axis snaps. These compose cleanly — one fixes y (horizontal), one
    // fixes x (vertical) — so a corner can lock both its edges to axes at once.
    double? bestH, snapY;
    int? hSeg;
    double? bestV, snapX;
    int? vSeg;
    for (final si in incident) {
      final other = points[_otherEnd(si, pi)];
      final d = raw - other;
      if (d.distance < 1e-6) continue;
      final aH = _angleFrom(d, 0); // distance to horizontal
      final aV = _angleFrom(d, math.pi / 2); // distance to vertical
      if (aH < snapAngle && (bestH == null || aH < bestH)) {
        bestH = aH;
        snapY = other.dy;
        hSeg = si;
      }
      if (aV < snapAngle && (bestV == null || aV < bestV)) {
        bestV = aV;
        snapX = other.dx;
        vSeg = si;
      }
    }
    if (snapY != null) {
      target = Offset(target.dx, snapY);
      if (!hasConstraint(ConstraintKind.horizontal, [hSeg!])) {
        candidates.add(SketchConstraint(ConstraintKind.horizontal, [hSeg]));
      }
    }
    if (snapX != null) {
      target = Offset(snapX, target.dy);
      if (!hasConstraint(ConstraintKind.vertical, [vSeg!])) {
        candidates.add(SketchConstraint(ConstraintKind.vertical, [vSeg]));
      }
    }

    // Pass 2: parallel / perpendicular to another edge — only when no axis snap
    // applied (a rotation would fight the axis x/y snaps), and only for the
    // longest incident edge, rotating it about its far end onto the alignment.
    if (candidates.isEmpty) {
      final si = incident.reduce((a, b) =>
          (raw - points[_otherEnd(a, pi)]).distance >
                  (raw - points[_otherEnd(b, pi)]).distance
              ? a
              : b);
      final other = points[_otherEnd(si, pi)];
      final d = raw - other;
      final len = d.distance;
      if (len >= 1e-6) {
        SketchConstraint? best;
        Offset? bestTarget;
        double bestErr = snapAngle;
        for (var tj = 0; tj < segments.length; tj++) {
          if (tj == si || segments[tj].isArc) continue;
          final t = segments[tj];
          final td = points[t.b] - points[t.a];
          if (td.distance < 1e-6) continue;
          final unit = td / td.distance;
          final acute = _acute(d, td);
          if (acute < bestErr) {
            final sign = (d.dx * unit.dx + d.dy * unit.dy) >= 0 ? 1.0 : -1.0;
            bestErr = acute;
            bestTarget = other + unit * (sign * len);
            best = SketchConstraint(ConstraintKind.parallel, [si, tj]);
          }
          final perp = (acute - math.pi / 2).abs();
          if (perp < bestErr) {
            final pu = Offset(-unit.dy, unit.dx);
            final sign = (d.dx * pu.dx + d.dy * pu.dy) >= 0 ? 1.0 : -1.0;
            bestErr = perp;
            bestTarget = other + pu * (sign * len);
            best = SketchConstraint(ConstraintKind.perpendicular, [si, tj]);
          }
        }
        if (best != null && bestTarget != null) {
          target = bestTarget;
          if (!hasConstraint(best.kind, best.segments)) candidates.add(best);
        }
      }
    }

    return (target: target, candidates: candidates);
  }

  int _otherEnd(int si, int pi) => segments[si].a == pi ? segments[si].b : segments[si].a;

  /// Smallest angle between direction [d] and the axis at [axis] radians (or its
  /// opposite), in [0, pi/2].
  double _angleFrom(Offset d, double axis) {
    var a = (math.atan2(d.dy, d.dx) - axis).abs() % math.pi;
    if (a > math.pi / 2) a = math.pi - a;
    return a;
  }

  /// Acute angle between two direction vectors, in [0, pi/2].
  double _acute(Offset a, Offset b) {
    final aa = math.atan2(a.dy, a.dx), bb = math.atan2(b.dy, b.dx);
    var d = (aa - bb).abs() % math.pi;
    if (d > math.pi / 2) d = math.pi - d;
    return d;
  }

  /// Removes segment [si] (and its arc), dropping constraints that reference it
  /// and any now-unused points, then re-solves.
  void removeSegment(int si) {
    if (si < 0 || si >= segments.length) return;
    _removeSegments({si});
  }

  /// Removes point [pi] along with every segment incident to it.
  void removePoint(int pi) {
    if (pi < 0 || pi >= points.length) return;
    final incident = <int>{};
    for (var i = 0; i < segments.length; i++) {
      if (segments[i].a == pi || segments[i].b == pi) incident.add(i);
    }
    _removeSegments(incident);
  }

  /// Drops the given segments, remapping constraint segment-indices and pruning
  /// orphaned points, then re-solves. The single choke point for deletion so
  /// the points/segments/constraints index invariants stay consistent.
  void _removeSegments(Set<int> remove) {
    if (remove.isNotEmpty) {
      final kept = [
        for (var i = 0; i < segments.length; i++)
          if (!remove.contains(i)) i
      ];
      final segRemap = {for (var n = 0; n < kept.length; n++) kept[n]: n};
      final newConstraints = <SketchConstraint>[
        for (final c in constraints)
          if (!c.segments.any(remove.contains))
            SketchConstraint(c.kind, [for (final s in c.segments) segRemap[s]!])
      ];
      final newSegments = [for (final i in kept) segments[i]];
      segments
        ..clear()
        ..addAll(newSegments);
      constraints
        ..clear()
        ..addAll(newConstraints);
    }
    _pruneOrphanPoints();
    solve();
  }

  /// Removes points no segment references, remapping endpoint indices so the
  /// kernel's "id == list index" contract still holds on the next solve.
  void _pruneOrphanPoints() {
    if (points.isEmpty) return;
    final used = List<bool>.filled(points.length, false);
    for (final s in segments) {
      used[s.a] = true;
      used[s.b] = true;
    }
    if (!used.contains(false)) return;
    final keep = [
      for (var i = 0; i < points.length; i++)
        if (used[i]) i
    ];
    final remap = {for (var n = 0; n < keep.length; n++) keep[n]: n};
    final newPoints = [for (final i in keep) points[i]];
    for (final s in segments) {
      s.a = remap[s.a]!;
      s.b = remap[s.b]!;
    }
    points
      ..clear()
      ..addAll(newPoints);
  }
}
