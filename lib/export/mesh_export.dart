import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../sketch/entities.dart';
import '../sketch/part.dart';
import '../sketch/plane.dart';
import '../sketch/solid.dart';
import '../sketch/triangulate.dart';
import 'stl.dart';

const int _circleFacets = 48;

List<Offset> _tessellate(CircleEntity c) => [
      for (var i = 0; i < _circleFacets; i++)
        c.center +
            Offset(math.cos(2 * math.pi * i / _circleFacets),
                    math.sin(2 * math.pi * i / _circleFacets)) *
                c.radius,
    ];

bool _inside(List<Offset> poly, Offset p) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.dy > p.dy) != (b.dy > p.dy) &&
        p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

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

/// Triangles for exporting a part: a holed extrude when the profile has interior
/// circle holes, otherwise the part's own solid (or imported mesh). Unlike the
/// wireframe [Part.buildSolid], this cuts interior circles through the solid so
/// a plate exports WITH its holes.
List<List<Vec3>> partExportTriangles(Part part) {
  final profile = part.sketch.closedProfile();
  if (profile == null || profile.length < 3) {
    final s = part.buildSolid();
    return s == null ? const [] : solidTriangles(s);
  }
  final holes = <List<Offset>>[
    for (final e in part.decorations)
      if (e is CircleEntity && _inside(profile, e.center)) _tessellate(e),
  ];
  return extrudeWithHolesTriangles(profile, holes, part.depth, part.plane);
}
