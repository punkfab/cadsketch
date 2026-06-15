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
}

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
