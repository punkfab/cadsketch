import 'dart:ui' show Offset;

import '../sketch/part.dart';
import '../sketch/plane.dart';
import '../sketch/solid.dart';
import '../sketch/triangulate.dart';
import 'stl.dart';

/// A watertight triangle mesh for the extruded profile [outer] with [holes]
/// drilled through it, on [plane] by [depth]: triangulated caps (outer minus
/// holes) top and bottom, outer side walls, and inward-facing hole walls.
List<List<Vec3>> extrudeWithHolesTriangles(
    List<Offset> outer, List<List<Offset>> holes, double depth, SketchPlane plane) {
  final off = plane.normal * depth;
  Vec3 lo(Offset p) => plane.to3d(p);
  Vec3 hi(Offset p) => plane.to3d(p) + off;

  final tris = <List<Vec3>>[];
  for (final t in triangulateWithHoles(outer, holes)) {
    tris.add([lo(t[0]), lo(t[2]), lo(t[1])]); // bottom cap
    tris.add([hi(t[0]), hi(t[1]), hi(t[2])]); // top cap
  }
  void wall(List<Offset> loop) {
    for (var i = 0; i < loop.length; i++) {
      final a = loop[i], b = loop[(i + 1) % loop.length];
      final a0 = lo(a), b0 = lo(b), a1 = hi(a), b1 = hi(b);
      tris.add([a0, b0, b1]);
      tris.add([a0, b1, a1]);
    }
  }

  wall(outer);
  for (final h in holes) {
    wall(h);
  }
  return tris;
}

/// Triangles for exporting a part, with holes cut through the solid — a watertight
/// mesh, unlike the wireframe [Part.buildSolid]. Interior holes (sketched inner
/// loop or an interior circle) come from [Part.profileWithHoles].
List<List<Vec3>> partExportTriangles(Part part) {
  final pw = part.profileWithHoles();
  if (pw == null) {
    final s = part.buildSolid();
    return s == null ? const [] : solidTriangles(s);
  }
  return extrudeWithHolesTriangles(pw.outer, pw.holes, part.depth, part.plane);
}
