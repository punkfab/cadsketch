import 'dart:ui' show Offset;

// 2D triangulation of a simple polygon with interior holes (e.g. a plate with
// drilled holes), via hole-bridging + ear clipping. Pure Dart, no external deps
// — used to build a watertight mesh with holes for direct STL export, before a
// real CSG kernel (OCCT) exists. O(n^2); polygons here are small.

double _signedArea(List<Offset> p) {
  var a = 0.0;
  for (var i = 0, j = p.length - 1; i < p.length; j = i++) {
    a += (p[j].dx - p[i].dx) * (p[j].dy + p[i].dy);
  }
  return a / 2;
}

List<Offset> _oriented(List<Offset> p, {required bool positive}) {
  final ccw = _signedArea(p) > 0;
  return ccw == positive ? p : p.reversed.toList();
}

/// Merges [holes] into [outer] as one simple polygon by bridging each hole to
/// the outer boundary. Outer is normalised to one winding, holes to the other.
List<Offset> _bridge(List<Offset> outer, List<List<Offset>> holes) {
  var ring = _oriented(outer, positive: true);
  // Process holes right-to-left so earlier bridges don't block later ones.
  final hs = [for (final h in holes) _oriented(h, positive: false)]
    ..sort((a, b) => _maxX(b).compareTo(_maxX(a)));
  for (final hole in hs) {
    ring = _spliceHole(ring, hole);
  }
  return ring;
}

double _maxX(List<Offset> p) => p.map((o) => o.dx).reduce((a, b) => a > b ? a : b);

/// Splices [hole] into [ring] at a mutually visible bridge vertex.
List<Offset> _spliceHole(List<Offset> ring, List<Offset> hole) {
  // The hole's rightmost vertex is the bridge start.
  var hi = 0;
  for (var i = 1; i < hole.length; i++) {
    if (hole[i].dx > hole[hi].dx) hi = i;
  }
  final m = hole[hi];

  // Cast a ray +x from m; find the visible outer vertex to bridge to. Pick the
  // ring vertex that is closest to m along +x (simple, robust for holes fully
  // inside a simple outer boundary).
  var bi = -1;
  var bestDx = double.infinity;
  for (var i = 0; i < ring.length; i++) {
    final v = ring[i];
    if (v.dx >= m.dx) {
      final dx = v.dx - m.dx + (v.dy - m.dy).abs() * 1e-6; // tie-break by y
      if (dx < bestDx) {
        bestDx = dx;
        bi = i;
      }
    }
  }
  if (bi < 0) bi = 0; // degenerate fallback

  // Build the merged ring: ring[0..bi], bridge into hole (from hi around),
  // back to m, then ring[bi..end].
  final merged = <Offset>[];
  for (var i = 0; i <= bi; i++) {
    merged.add(ring[i]);
  }
  for (var k = 0; k <= hole.length; k++) {
    merged.add(hole[(hi + k) % hole.length]);
  }
  merged.add(ring[bi]); // return bridge
  for (var i = bi + 1; i < ring.length; i++) {
    merged.add(ring[i]);
  }
  return merged;
}

// STRICT interior test — a point exactly on an edge/vertex is NOT "inside", so
// the coincident bridge vertices don't deadlock ear clipping.
bool _pointInTri(Offset p, Offset a, Offset b, Offset c) {
  double cross(Offset u, Offset v, Offset w) =>
      (v.dx - u.dx) * (w.dy - u.dy) - (v.dy - u.dy) * (w.dx - u.dx);
  final d1 = cross(a, b, p), d2 = cross(b, c, p), d3 = cross(c, a, p);
  const e = 1e-9;
  return (d1 > e && d2 > e && d3 > e) || (d1 < -e && d2 < -e && d3 < -e);
}

/// Ear-clips a simple polygon (CCW). Returns triangles as Offset triples.
List<List<Offset>> _earClip(List<Offset> poly) {
  final v = _oriented(poly, positive: true);
  final idx = List<int>.generate(v.length, (i) => i);
  final tris = <List<Offset>>[];
  var guard = 0;
  while (idx.length > 3 && guard++ < 100000) {
    var clipped = false;
    for (var i = 0; i < idx.length; i++) {
      final ia = idx[(i - 1 + idx.length) % idx.length];
      final ib = idx[i];
      final ic = idx[(i + 1) % idx.length];
      final a = v[ia], b = v[ib], c = v[ic];
      // Convex corner? (CCW cross > 0)
      final cross = (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);
      if (cross <= 0) continue;
      // No other vertex inside the ear triangle?
      var empty = true;
      for (final j in idx) {
        if (j == ia || j == ib || j == ic) continue;
        if (_pointInTri(v[j], a, b, c)) {
          empty = false;
          break;
        }
      }
      if (!empty) continue;
      tris.add([a, b, c]);
      idx.removeAt(i);
      clipped = true;
      break;
    }
    if (!clipped) break; // avoid infinite loop on a degenerate polygon
  }
  if (idx.length == 3) {
    tris.add([v[idx[0]], v[idx[1]], v[idx[2]]]);
  }
  return tris;
}

/// Triangulates [outer] with interior [holes] into a list of CCW triangles.
List<List<Offset>> triangulateWithHoles(List<Offset> outer, List<List<Offset>> holes) {
  if (holes.isEmpty) return _earClip(outer);
  return _earClip(_bridge(outer, holes));
}
