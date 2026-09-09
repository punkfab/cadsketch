import 'dart:math' as math;
import 'dart:ui' show Offset;

// Minimal 3D for the harness. Extrude is a trivial prism generator (Dart on
// purpose — the hard B-rep math, booleans/fillets, is deferred to OCCT in the
// native build). A Solid is just vertices + edges; the wireframe view projects
// them orthographically. Faces are kept for the future (shading, mate connector
// placement) even though the wireframe doesn't need them yet.

class Vec3 {
  const Vec3(this.x, this.y, this.z);
  final double x, y, z;

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator *(double s) => Vec3(x * s, y * s, z * s);
  double get length => math.sqrt(x * x + y * y + z * z);
  Vec3 get normalized {
    final l = length;
    return l < 1e-12 ? this : this * (1 / l);
  }
}

class Solid {
  const Solid(this.vertices, this.edges, this.faces);
  final List<Vec3> vertices;
  final List<List<int>> edges; // each [i, j] indexes vertices
  final List<List<int>> faces; // each an ordered vertex-index ring

  Vec3 get centroid {
    var c = const Vec3(0, 0, 0);
    for (final v in vertices) {
      c = c + v;
    }
    return c * (1.0 / vertices.length);
  }

  /// Max distance of any vertex from the centroid (for view auto-fit).
  double get boundingRadius {
    final c = centroid;
    var r = 0.0;
    for (final v in vertices) {
      r = math.max(r, (v - c).length);
    }
    return r;
  }

  Vec3 faceCentroid(int f) {
    final ring = faces[f];
    var c = const Vec3(0, 0, 0);
    for (final i in ring) {
      c = c + vertices[i];
    }
    return c * (1.0 / ring.length);
  }

  /// Outward face normal via Newell's method (robust for non-planar rings).
  Vec3 faceNormal(int f) {
    final ring = faces[f];
    var nx = 0.0, ny = 0.0, nz = 0.0;
    for (var i = 0; i < ring.length; i++) {
      final cur = vertices[ring[i]];
      final nxt = vertices[ring[(i + 1) % ring.length]];
      nx += (cur.y - nxt.y) * (cur.z + nxt.z);
      ny += (cur.z - nxt.z) * (cur.x + nxt.x);
      nz += (cur.x - nxt.x) * (cur.y + nxt.y);
    }
    return Vec3(nx, ny, nz).normalized;
  }

  /// Index of the face whose centroid is closest to [p]. Used to map a face
  /// picked on a decomposition-region solid onto the corresponding face of the
  /// part's own solid (which is the frame a mate connector is interpreted in),
  /// so a mate point can't land on the wrong face.
  int faceNearest(Vec3 p) {
    var best = 0;
    var bestD = double.infinity;
    for (var f = 0; f < faces.length; f++) {
      final d = (faceCentroid(f) - p).length;
      if (d < bestD) {
        bestD = d;
        best = f;
      }
    }
    return best;
  }

  /// Distance along the unit ray [dir] from [origin] to the nearest face it
  /// hits, or null if it misses every face. A hit within [eps] behind the
  /// origin counts, so a ray started ON a face reports ~0. Each face is treated
  /// as a planar polygon: intersect its plane, then point-in-polygon on the
  /// plane's dominant axis. Used to drop a boss's base onto the body it sits
  /// on ("up to next") when its sketch overhangs the face it was drawn on.
  double? rayHit(Vec3 origin, Vec3 dir, {double eps = 1e-6}) {
    double? best;
    for (var f = 0; f < faces.length; f++) {
      final ring = faces[f];
      if (ring.length < 3) continue;
      final n = faceNormal(f);
      final denom = _dot(n, dir);
      if (denom.abs() < 1e-9) continue; // ray parallel to the face
      final t = _dot(n, vertices[ring[0]] - origin) / denom;
      if (t < -eps) continue; // behind the origin
      if (best != null && t >= best) continue;
      if (_inFace(origin + dir * t, ring, n)) best = t;
    }
    return best;
  }

  /// Point-in-polygon for [p] (assumed on the face's plane): project both onto
  /// the plane's dominant axis pair and run the even-odd crossing test.
  bool _inFace(Vec3 p, List<int> ring, Vec3 n) {
    final ax = n.x.abs(), ay = n.y.abs(), az = n.z.abs();
    final (int i0, int i1) =
        az >= ax && az >= ay ? (0, 1) : (ax >= ay ? (1, 2) : (0, 2));
    double c(Vec3 v, int i) => i == 0 ? v.x : (i == 1 ? v.y : v.z);
    final px = c(p, i0), py = c(p, i1);
    var inside = false;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final a = vertices[ring[i]], b = vertices[ring[j]];
      final axx = c(a, i0), ayy = c(a, i1), bxx = c(b, i0), byy = c(b, i1);
      if ((ayy > py) != (byy > py) &&
          px < (bxx - axx) * (py - ayy) / (byy - ayy) + axx) {
        inside = !inside;
      }
    }
    return inside;
  }
}

double _dot(Vec3 a, Vec3 b) => a.x * b.x + a.y * b.y + a.z * b.z;

/// Extrudes a closed 2D profile (in the sketch's X/Y) by [depth] along Z into a
/// prism. Bottom ring is vertices 0..n-1, top ring is n..2n-1.
Solid extrudeProfile(List<Offset> profile, double depth) {
  final n = profile.length;
  final verts = <Vec3>[
    for (final p in profile) Vec3(p.dx, p.dy, 0),
    for (final p in profile) Vec3(p.dx, p.dy, depth),
  ];
  final edges = <List<int>>[];
  final sides = <List<int>>[];
  for (var i = 0; i < n; i++) {
    final j = (i + 1) % n;
    edges.add([i, j]); // bottom ring
    edges.add([n + i, n + j]); // top ring
    edges.add([i, n + i]); // vertical
    sides.add([i, j, n + j, n + i]); // side quad
  }
  final faces = <List<int>>[
    [for (var i = 0; i < n; i++) i], // bottom cap
    [for (var i = 0; i < n; i++) n + i], // top cap
    ...sides,
  ];
  return Solid(verts, edges, faces);
}

/// Extrudes [outer] with interior [holes] drilled through, as a wireframe-model
/// Solid: caps are the OUTER rings (faces 0/1) — the holes show through the
/// inner-ring edges and their side walls, so the 3D wireframe reads as a holed
/// part (matching STL export). Face 0 = bottom cap, 1 = top cap, then outer side
/// quads, then each hole's side quads.
Solid extrudeWithHolesSolid(
    List<Offset> outer, List<List<Offset>> holes, double depth) {
  final verts = <Vec3>[];
  final edges = <List<int>>[];

  int addRingVerts(List<Offset> loop) {
    final base = verts.length;
    for (final p in loop) {
      verts.add(Vec3(p.dx, p.dy, 0));
    }
    for (final p in loop) {
      verts.add(Vec3(p.dx, p.dy, depth));
    }
    return base;
  }

  final n = outer.length;
  final ob = addRingVerts(outer);
  final faces = <List<int>>[
    [for (var i = 0; i < n; i++) ob + i], // 0: bottom cap (outer ring)
    [for (var i = 0; i < n; i++) ob + n + i], // 1: top cap (outer ring)
  ];

  void ringEdgesAndWalls(int base, int m) {
    for (var i = 0; i < m; i++) {
      final j = (i + 1) % m;
      edges.add([base + i, base + j]); // bottom ring
      edges.add([base + m + i, base + m + j]); // top ring
      edges.add([base + i, base + m + i]); // vertical
      faces.add([base + i, base + j, base + m + j, base + m + i]); // side quad
    }
  }

  ringEdgesAndWalls(ob, n);
  for (final h in holes) {
    ringEdgesAndWalls(addRingVerts(h), h.length);
  }
  return Solid(verts, edges, faces);
}
