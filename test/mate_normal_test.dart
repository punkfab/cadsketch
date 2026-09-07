import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/part.dart';
import 'package:ai_sketcher/sketch/solid.dart';

// Regression: a mate point's normal must point OUT of the solid on every face,
// including the cap whose raw extrude winding points inward. Otherwise a fasten
// (which opposes normals) orients that mate backwards / into the part.

void main() {
  test('mate normal points outward on every face of an extruded prism', () {
    final solid = extrudeProfile(const [
      Offset(0, 0),
      Offset(10, 0),
      Offset(10, 10),
      Offset(0, 10),
    ], 10);
    final c = solid.centroid;
    for (var f = 0; f < solid.faces.length; f++) {
      final n = MateConnector(f).normal(solid);
      final d = solid.faceCentroid(f) - c; // face centroid relative to body center
      final outward = n.x * d.x + n.y * d.y + n.z * d.z;
      expect(outward >= 0, isTrue, reason: 'face $f normal points inward ($outward)');
    }
  });
}
