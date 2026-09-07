import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/plane.dart';
import 'package:ai_sketcher/sketch/solid.dart';

// Regression: a sketch-on-face plane took the raw Newell face normal, which is
// winding-dependent and points inward on some faces (a box's bottom cap, a
// cylinder's tessellated back faces). A boss then extruded INTO the body.
// SketchPlane.fromFace now orients the normal outward from the solid centroid.

List<Offset> _circle(double r, int n) => [
      for (var i = 0; i < n; i++)
        Offset(r * math.cos(2 * math.pi * i / n), r * math.sin(2 * math.pi * i / n)),
    ];

void _expectAllOutward(Solid s) {
  for (var f = 0; f < s.faces.length; f++) {
    final outward = s.faceCentroid(f) - s.centroid;
    if (outward.length < 1e-9) continue;
    final n = SketchPlane.fromFace(s, f).normal;
    expect(n.x * outward.x + n.y * outward.y + n.z * outward.z, greaterThan(0),
        reason: 'face $f plane normal must point outward');
  }
}

void main() {
  test('box: the bottom cap (inward Newell normal) flips outward', () {
    final box = extrudeProfile(
        const [Offset(0, 0), Offset(10, 0), Offset(10, 10), Offset(0, 10)], 20);
    // Face 0 is the bottom cap; its outward direction is -Z.
    final n = SketchPlane.fromFace(box, 0).normal;
    final outward = box.faceCentroid(0) - box.centroid;
    expect(n.x * outward.x + n.y * outward.y + n.z * outward.z, greaterThan(0));
    _expectAllOutward(box);
  });

  test('cylinder: every side + cap face plane normal points outward', () {
    final cyl = extrudeProfile(_circle(12, 24), 30);
    _expectAllOutward(cyl);
  });
}
