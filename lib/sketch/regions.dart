import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'model.dart';

// Finds the bounded regions (faces) of a sketch treated as a planar graph, so a
// master sketch with internal dividing lines can be split into parts — one per
// enclosed region. This is the geometry core of Phase 1 region-partition
// decomposition.
//
// Method: a half-edge (DCEL) face traversal. Each segment becomes two directed
// half-edges. From a half-edge u→v, the next half-edge around a face is found at
// v by rotating clockwise from the reverse direction (v→u) to the next incident
// edge. With angles measured in math coordinates (y up; sketch y is down, so we
// negate it), this traces every bounded face counterclockwise (positive signed
// area) and the single unbounded outer face clockwise (negative). Keeping
// positive-area faces drops the outer ring and any degenerate slivers.

/// One enclosed region: the ordered point indices of its boundary loop, the
/// tessellated boundary (arcs expanded) for extrusion, and, parallel to the
/// profile, the source point index of each profile vertex (-1 for points
/// interpolated along an arc). The source list lets a shared segment be located
/// as a profile edge so its extruded side face can be used as a mate connector.
class Region {
  Region(this.loop, this.profile, this.profileSource);
  final List<int> loop;
  final List<Offset> profile;
  final List<int> profileSource;
}

/// Two regions share a segment (an internal divider): after extrusion this edge
/// becomes a coincident side face on each, i.e. an auto-captured mating surface.
class RegionAdjacency {
  RegionAdjacency(this.regionA, this.regionB, this.pa, this.pb);
  final int regionA, regionB;
  final int pa, pb; // shared segment endpoints (point indices)
}

class RegionSet {
  RegionSet(this.regions, this.adjacencies);
  final List<Region> regions;
  final List<RegionAdjacency> adjacencies;

  bool get isPartitioned => regions.length > 1;
}

/// Decomposes [s] into its bounded regions and their shared-edge adjacencies.
RegionSet findRegions(ParametricSketch s) {
  final pts = s.points;
  if (pts.length < 3 || s.segments.length < 3) {
    return RegionSet(const [], const []);
  }

  // Adjacency: vertex -> neighbors, sorted CCW by angle (math coords).
  final neighbors = List.generate(pts.length, (_) => <int>[]);
  for (final seg in s.segments) {
    if (!neighbors[seg.a].contains(seg.b)) neighbors[seg.a].add(seg.b);
    if (!neighbors[seg.b].contains(seg.a)) neighbors[seg.b].add(seg.a);
  }
  double angle(int from, int to) {
    final d = pts[to] - pts[from];
    return math.atan2(-d.dy, d.dx); // negate y: sketch is y-down
  }
  for (var v = 0; v < pts.length; v++) {
    neighbors[v].sort((a, b) => angle(v, a).compareTo(angle(v, b)));
  }

  // Trace faces by following next half-edges until we return to the start.
  final visited = <int>{}; // key: u * pts.length + v
  int key(int u, int v) => u * pts.length + v;
  final rawLoops = <List<int>>[];
  for (final seg in s.segments) {
    for (final he in [
      [seg.a, seg.b],
      [seg.b, seg.a],
    ]) {
      var u = he[0], v = he[1];
      if (visited.contains(key(u, v))) continue;
      final loop = <int>[];
      while (!visited.contains(key(u, v))) {
        visited.add(key(u, v));
        loop.add(u);
        // next half-edge: at v, rotate clockwise from u (the reverse dir).
        final nb = neighbors[v];
        final idx = nb.indexOf(u);
        final next = nb[(idx - 1 + nb.length) % nb.length];
        u = v;
        v = next;
        if (loop.length > pts.length + 1) break; // guard against malformed graph
      }
      if (loop.length >= 3) rawLoops.add(loop);
    }
  }

  // Keep bounded faces (positive signed area in math coords); drop the outer
  // ring and slivers.
  double signedArea(List<int> loop) {
    var a = 0.0;
    for (var i = 0; i < loop.length; i++) {
      final p = pts[loop[i]];
      final q = pts[loop[(i + 1) % loop.length]];
      a += p.dx * (-q.dy) - q.dx * (-p.dy);
    }
    return a / 2;
  }
  final regions = <Region>[];
  for (final loop in rawLoops) {
    if (signedArea(loop) <= 1e-6) continue;
    final (profile, source) = _buildProfile(s, loop);
    if (profile.length >= 3) regions.add(Region(loop, profile, source));
  }

  // Shared-segment adjacencies: an undirected segment used by exactly two
  // regions is an internal divider between them.
  final usedBy = <int, List<int>>{};
  for (var ri = 0; ri < regions.length; ri++) {
    final loop = regions[ri].loop;
    for (var i = 0; i < loop.length; i++) {
      final a = loop[i], b = loop[(i + 1) % loop.length];
      final k = a < b ? a * pts.length + b : b * pts.length + a;
      (usedBy[k] ??= []).add(ri);
    }
  }
  final adj = <RegionAdjacency>[];
  usedBy.forEach((k, regs) {
    if (regs.length == 2) {
      final a = k ~/ pts.length, b = k % pts.length;
      adj.add(RegionAdjacency(regs[0], regs[1], a, b));
    }
  });

  return RegionSet(regions, adj);
}

/// Tessellated boundary of [loop] (arcs expanded), with a parallel list giving
/// the source point index of each profile vertex (-1 for arc-interpolated).
(List<Offset>, List<int>) _buildProfile(ParametricSketch s, List<int> loop) {
  final profile = <Offset>[];
  final source = <int>[];
  for (var i = 0; i < loop.length; i++) {
    final ai = loop[i];
    final bi = loop[(i + 1) % loop.length];
    final seg = _segmentBetween(s, ai, bi);
    if (seg != null && seg.isArc) {
      final forward = seg.a == ai;
      final sweep = forward ? seg.arc!.sweep : -seg.arc!.sweep;
      final pts = _tessellateArc(
          s.points[ai], seg.arc!.center, seg.arc!.radius, sweep);
      for (var j = 0; j < pts.length; j++) {
        profile.add(pts[j]);
        source.add(j == 0 ? ai : -1); // first vertex is the real corner
      }
    } else {
      profile.add(s.points[ai]);
      source.add(ai);
    }
  }
  return (profile, source);
}

Segment? _segmentBetween(ParametricSketch s, int a, int b) {
  for (final seg in s.segments) {
    if ((seg.a == a && seg.b == b) || (seg.a == b && seg.b == a)) return seg;
  }
  return null;
}

List<Offset> _tessellateArc(
    Offset start, Offset center, double radius, double sweep) {
  final n = math.max(2, (sweep.abs() / 0.25).ceil());
  final a0 = math.atan2(start.dy - center.dy, start.dx - center.dx);
  return [
    for (var i = 0; i < n; i++)
      center +
          Offset(math.cos(a0 + sweep * i / n), math.sin(a0 + sweep * i / n)) *
              radius,
  ];
}
