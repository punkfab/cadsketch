import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/plane.dart';
import 'package:ai_sketcher/sketch/solid.dart';
import 'package:ai_sketcher/sketch/transform3.dart';

// SketchPlane.fromFace must produce a valid orthonormal frame whose normal
// matches the face and whose 2D coords all lie on the face plane — that's what
// lets the existing 2D solver drive geometry sketched on a body face.

void main() {
  final box = extrudeProfile(const [
    Offset(0, 0),
    Offset(10, 0),
    Offset(10, 10),
    Offset(0, 10),
  ], 10);

  test('fromFace: orthonormal frame, normal matches face, origin = centroid', () {
    for (var f = 0; f < box.faces.length; f++) {
      final plane = SketchPlane.fromFace(box, f);
      final n = box.faceNormal(f);

      // u, v unit and orthogonal; normal = u x v matches the face normal.
      expect(plane.u.length, closeTo(1, 1e-9));
      expect(plane.v.length, closeTo(1, 1e-9));
      expect(dot(plane.u, plane.v), closeTo(0, 1e-9));
      expect(dot(plane.normal, n), closeTo(1, 1e-6));

      // Origin is the face centroid.
      final c = box.faceCentroid(f);
      expect((plane.origin - c).length, closeTo(0, 1e-9));
    }
  });

  test('fromFace: sketch points map onto the face plane', () {
    final plane = SketchPlane.fromFace(box, 1); // a cap
    final n = plane.normal;
    for (final p in const [Offset(0, 0), Offset(5, -3), Offset(-8, 12)]) {
      final w = plane.to3d(p);
      // On the plane: (w - origin) is perpendicular to the normal.
      expect(dot(w - plane.origin, n), closeTo(0, 1e-9));
      // And round-trips back to the same 2D coordinate.
      final back = plane.to2d(w);
      expect((back - p).distance, closeTo(0, 1e-9));
    }
  });
}
