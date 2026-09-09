import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/entities.dart';
import 'package:ai_sketcher/sketch/part.dart';
import 'package:ai_sketcher/sketch/plane.dart';

// Regression: a boss whose sketch overhangs the face it was drawn on floated
// where it hung past the edge. The prism was extruded flat from the face plane,
// so there was nothing beneath the overhang — a circle on a thin cylinder facet
// (~10 units wide) almost always overhangs, which is what read as "sketch on
// face doesn't work / the boss is off to the side". Now the base lofts down to
// the next face ("up to next"): every base vertex is dropped along -normal
// onto the parent body, so there's no gap.

Offset centroid2d(List<Offset> pts) {
  var sx = 0.0, sy = 0.0;
  for (final p in pts) {
    sx += p.dx;
    sy += p.dy;
  }
  return Offset(sx / pts.length, sy / pts.length);
}

void main() {
  // A cylinder part: radius 50, depth 200, 32 facets (~9.8 wide each).
  Part cylinderPart() => Part('Cyl')
    ..depth = 200
    ..decorations.add(CircleEntity(const Offset(0, 0), 50));

  test('a circle overhanging a thin cylinder facet lofts down to the body', () {
    final base = cylinderPart();
    final body = base.buildSolid()!;
    const side = 2; // a thin side facet
    final plane = SketchPlane.fromFace(body, side);
    final ref = [for (final vi in body.faces[side]) plane.to2d(body.vertices[vi])];

    // A circle of radius 15 centred on a ~9.8-wide facet overhangs both edges.
    final boss = Part('Boss')
      ..plane = plane
      ..depth = 20
      ..referenceLoop = ref
      ..parent = base
      ..decorations.add(CircleEntity(centroid2d(ref), 15));

    final s = boss.solidOnPlane()!;
    final n = plane.normal;
    final down = n * -1.0;
    final baseCount = s.faces[0].length; // bottom ring = the profile
    final flat = extrudeOnPlane(
        [for (final vi in s.faces[0]) plane.to2d(s.vertices[vi])], plane, 20);

    // The flat prism (old behaviour) leaves a real gap under the overhang…
    var maxGapFlat = 0.0;
    for (var i = 0; i < baseCount; i++) {
      maxGapFlat = math.max(maxGapFlat, body.rayHit(flat.vertices[i], down) ?? 0);
    }
    expect(maxGapFlat, greaterThan(0.5),
        reason: 'the overhanging part of the flat prism floats above the body');

    // …whereas the lofted base sits ON the body: nothing beneath any vertex.
    var maxGap = 0.0, dropped = 0;
    for (var i = 0; i < baseCount; i++) {
      final v = s.vertices[i];
      maxGap = math.max(maxGap, body.rayHit(v, down) ?? 0);
      // Overhanging vertices were pulled below the face plane.
      final below = -((v - plane.origin).x * n.x +
          (v - plane.origin).y * n.y +
          (v - plane.origin).z * n.z);
      if (below > 1e-3) dropped++;
    }
    expect(maxGap, lessThan(1e-3), reason: 'no gap under the boss base');
    expect(dropped, greaterThan(0), reason: 'the overhang lofted down');
    // The top stays a flat cap at the extrude height above the face plane.
    for (final vi in s.faces[1]) {
      final v = s.vertices[vi] - plane.origin;
      final h = v.x * n.x + v.y * n.y + v.z * n.z;
      expect(h, closeTo(20, 1e-6));
    }
  });

  test('a boss fully inside its face is unchanged (no vertex drops)', () {
    final base = cylinderPart();
    final body = base.buildSolid()!;
    final plane = SketchPlane.fromFace(body, 1); // the round top cap
    final boss = Part('Boss')
      ..plane = plane
      ..depth = 10
      ..referenceLoop = const [Offset(0, 0)]
      ..parent = base
      ..decorations.add(CircleEntity(const Offset(0, 0), 10)); // well inside r=50
    final s = boss.solidOnPlane()!;
    final n = plane.normal;
    for (var i = 0; i < s.faces[0].length; i++) {
      final v = s.vertices[i] - plane.origin;
      expect(v.x * n.x + v.y * n.y + v.z * n.z, closeTo(0, 1e-6),
          reason: 'base stays on the face plane');
    }
  });

  test('a pocket (difference) is not lofted', () {
    final base = cylinderPart();
    final body = base.buildSolid()!;
    final plane = SketchPlane.fromFace(body, 2);
    final ref = [for (final vi in body.faces[2]) plane.to2d(body.vertices[vi])];
    final pocket = Part('Pocket')
      ..plane = plane
      ..depth = 20
      ..operation = FeatureOp.difference
      ..referenceLoop = ref
      ..parent = base
      ..decorations.add(CircleEntity(centroid2d(ref), 15));
    final s = pocket.solidOnPlane()!;
    final n = plane.normal;
    for (var i = 0; i < s.faces[0].length; i++) {
      final v = s.vertices[i] - plane.origin;
      expect(v.x * n.x + v.y * n.y + v.z * n.z, closeTo(0, 1e-6));
    }
  });
}
