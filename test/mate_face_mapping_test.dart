import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/solid.dart';

// A mate point picked on a decomposition-region solid must map to the correct
// face of the part's OWN solid — otherwise it lands on the wrong face. The
// mapping is by nearest face centroid (Solid.faceNearest).

void main() {
  test('faceNearest returns the same face for that face\'s own centroid', () {
    final s = extrudeProfile(const [
      Offset(0, 0),
      Offset(20, 0),
      Offset(20, 10),
      Offset(0, 10),
    ], 10);
    for (var f = 0; f < s.faces.length; f++) {
      expect(s.faceNearest(s.faceCentroid(f)), f);
    }
  });

  test('a region face maps to the corresponding whole-part face', () {
    // Whole part: a 20x10 plate. Extrude layout: face 0 = bottom cap (z=0),
    // face 1 = top cap (z=10).
    final whole = extrudeProfile(const [
      Offset(0, 0),
      Offset(20, 0),
      Offset(20, 10),
      Offset(0, 10),
    ], 10);
    // A left-half REGION (0..10). Its top-cap centroid (5,5,10) is a different
    // face INDEX on the region, but geometrically it's the whole part's top cap.
    final region = extrudeProfile(const [
      Offset(0, 0),
      Offset(10, 0),
      Offset(10, 10),
      Offset(0, 10),
    ], 10);
    const regionTopCap = 1;
    final mapped = whole.faceNearest(region.faceCentroid(regionTopCap));
    expect(mapped, 1, reason: 'region top cap should map to the whole-part top cap');
    // ...and definitely not the bottom cap.
    expect(mapped, isNot(0));
  });
}
