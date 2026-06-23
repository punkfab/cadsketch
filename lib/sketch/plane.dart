import 'dart:ui' show Offset;

import 'solid.dart';
import 'transform3.dart';

// A sketch plane: an origin and an orthonormal (u, v) frame in 3D, with the
// normal = u × v. A 2D sketch lives in (u, v) coordinates and maps into the
// shared 3D scene via [to3d]; picked 3D points map back via [to2d]. This is the
// seam that lets the existing 2D solver (kernel unchanged) drive geometry on
// arbitrary planes/faces — the foundation for in-context 3D sketching. For now
// the master sketch sits on the base XY plane, reproducing the legacy extrude.
class SketchPlane {
  const SketchPlane(this.origin, this.u, this.v);

  final Vec3 origin;
  final Vec3 u; // 2D +x direction in world
  final Vec3 v; // 2D +y direction in world

  Vec3 get normal => cross(u, v).normalized;

  /// Base XY plane: sketch x/y == world x/y, normal +Z. Matches the legacy
  /// extrude (profile in X/Y swept along +Z).
  static const xy = SketchPlane(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0));

  /// Base XZ plane (normal +Y).
  static const xz = SketchPlane(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 0, 1));

  /// Base YZ plane (normal +X).
  static const yz = SketchPlane(Vec3(0, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1));

  /// A sketch frame on face [f] of [solid]: origin at the face centroid, normal
  /// = the face's outward normal, with an arbitrary in-plane (u, v) basis. Lets
  /// you sketch directly on a body face (in-context / multi-plane).
  factory SketchPlane.fromFace(Solid solid, int f) {
    final origin = solid.faceCentroid(f);
    final n = solid.faceNormal(f);
    // Pick a reference axis least parallel to n, project out n to get u.
    final ref = n.x.abs() < 0.9 ? const Vec3(1, 0, 0) : const Vec3(0, 1, 0);
    final u = (ref - n * dot(ref, n)).normalized;
    final v = cross(n, u).normalized;
    return SketchPlane(origin, u, v);
  }

  Vec3 to3d(Offset p) => origin + u * p.dx + v * p.dy;

  /// Projects a world point onto this plane's (u, v) coordinates.
  Offset to2d(Vec3 w) {
    final d = w - origin;
    return Offset(dot(d, u), dot(d, v));
  }
}

/// Extrudes a closed 2D [profile] (in plane coordinates) by [depth] along the
/// plane normal into a prism. Bottom ring is the profile on the plane; top ring
/// is offset by normal*depth. Face/edge layout matches [extrudeProfile]: face 0
/// = bottom cap, face 1 = top cap, faces 2..2+n-1 = side quads (one per profile
/// edge, in profile order), so a profile edge index i maps to side face 2+i.
Solid extrudeOnPlane(List<Offset> profile, SketchPlane plane, double depth) {
  final n = profile.length;
  final off = plane.normal * depth;
  final verts = <Vec3>[
    for (final p in profile) plane.to3d(p),
    for (final p in profile) plane.to3d(p) + off,
  ];
  final edges = <List<int>>[];
  final sides = <List<int>>[];
  for (var i = 0; i < n; i++) {
    final j = (i + 1) % n;
    edges.add([i, j]);
    edges.add([n + i, n + j]);
    edges.add([i, n + i]);
    sides.add([i, j, n + j, n + i]);
  }
  final faces = <List<int>>[
    [for (var i = 0; i < n; i++) i],
    [for (var i = 0; i < n; i++) n + i],
    ...sides,
  ];
  return Solid(verts, edges, faces);
}
