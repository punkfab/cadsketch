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

double _absArea(List<Offset> p) {
  var a = 0.0;
  for (var i = 0, j = p.length - 1; i < p.length; j = i++) {
    a += (p[j].dx - p[i].dx) * (p[j].dy + p[i].dy);
  }
  return a.abs() / 2;
}

Offset _centroid(List<Offset> p) {
  var x = 0.0, y = 0.0;
  for (final o in p) {
    x += o.dx;
    y += o.dy;
  }
  return Offset(x / p.length, y / p.length);
}

/// Triangles for exporting a part, with holes cut through the solid. Interior
/// loops — a sketched inner loop OR a circle decoration inside the profile —
/// become drilled holes. The largest closed loop is the outer boundary. Unlike
/// the wireframe [Part.buildSolid], this produces a watertight mesh WITH holes.
List<List<Vec3>> partExportTriangles(Part part) {
  final profiles = part.sketch.allProfiles()..sort((a, b) => _absArea(b).compareTo(_absArea(a)));
  if (profiles.isEmpty || profiles.first.length < 3) {
    final s = part.buildSolid();
    return s == null ? const [] : solidTriangles(s);
  }
  final outer = profiles.first;
  final holes = <List<Offset>>[
    // Sketched inner loops contained in the outer boundary.
    for (var i = 1; i < profiles.length; i++)
      if (_inside(outer, _centroid(profiles[i]))) profiles[i],
    // Circle decorations inside the outer boundary.
    for (final e in part.decorations)
      if (e is CircleEntity && _inside(outer, e.center)) _tessellate(e),
  ];
  return extrudeWithHolesTriangles(outer, holes, part.depth, part.plane);
}
