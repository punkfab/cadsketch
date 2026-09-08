import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/entities.dart';
import 'package:ai_sketcher/sketch/part.dart';
import 'package:ai_sketcher/sketch/plane.dart';
import 'package:ai_sketcher/sketch/solid.dart';

// Regression: a circle drawn on a face is a DECORATION (not a sketched loop), so
// the 3D view fell back to buildSolid — which extrudes on XY, ignoring the face
// plane — and the new circle floated off to the side. Part.solidOnPlane() (used
// by both 3D views) extrudes on the face plane instead.

void main() {
  test('a circle on a side face extrudes ON the face, not on XY', () {
    // A tall box; a side face's centroid is far from the origin (up at z≈100).
    final box = extrudeProfile(
        const [Offset(0, 0), Offset(10, 0), Offset(10, 10), Offset(0, 10)], 200);
    const sideFace = 2; // a side quad
    final plane = SketchPlane.fromFace(box, sideFace);
    final faceCentroid = box.faceCentroid(sideFace);
    expect(faceCentroid.length, greaterThan(80), reason: 'face is far from origin');

    final feat = Part('Boss')
      ..plane = plane
      ..depth = 5
      ..referenceLoop = [
        for (final vi in box.faces[sideFace]) plane.to2d(box.vertices[vi])
      ];
    // A circle centred on the face (plane-local origin).
    feat.decorations.add(CircleEntity(const Offset(0, 0), 3));

    // solidOnPlane sits ON the face...
    final onPlane = feat.solidOnPlane()!;
    for (final v in onPlane.vertices) {
      expect((v - faceCentroid).length, lessThan(20),
          reason: 'the boss is on the face');
    }

    // ...whereas buildSolid (the old fallback) puts it near the XY origin.
    expect(feat.buildSolid()!.centroid.length, lessThan(faceCentroid.length / 2),
        reason: 'buildSolid ignores the plane — floats off the face');
  });

  test('solidOnPlane direction follows the feature op (boss out / pocket in)', () {
    final box = extrudeProfile(
        const [Offset(0, 0), Offset(10, 0), Offset(10, 10), Offset(0, 10)], 20);
    final plane = SketchPlane.fromFace(box, 1); // top cap
    Part feat(FeatureOp op) => Part('f')
      ..plane = plane
      ..depth = 6
      ..operation = op
      ..referenceLoop = const [Offset(0, 0)]
      ..decorations.add(CircleEntity(const Offset(0, 0), 3));

    // Union extrudes outward (+normal), difference inward — opposite z spans.
    final boss = feat(FeatureOp.union).solidOnPlane()!;
    final pocket = feat(FeatureOp.difference).solidOnPlane()!;
    double maxZ(Solid s) => s.vertices.map((v) => v.z).reduce((a, b) => a > b ? a : b);
    expect(maxZ(boss), greaterThan(maxZ(pocket)));
  });
}
