import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/entities.dart';
import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/sketch/part.dart';

// Regression: a mate point stored a bare face INDEX, but drilling a hole makes
// buildSolid return a longer face list (extrudeProfile -> extrudeWithHolesSolid),
// so the old index pointed at a different face and the pin jumped. Connectors now
// anchor to their face centroid and re-resolve by nearest centroid, so they stay
// put across the edit.

Part _plate() {
  final p = Part('plate')..depth = 10;
  final s = p.sketch;
  s.points.addAll(const [Offset(0, 0), Offset(40, 0), Offset(40, 30), Offset(0, 30)]);
  for (var i = 0; i < 4; i++) {
    s.segments.add(Segment(i, (i + 1) % 4));
  }
  return p;
}

void main() {
  test('a mate point stays on its face after a hole is drilled', () {
    final p = _plate();
    final before = p.buildSolid()!;
    expect(before.faces.length, 6);

    // A mate point on an outer side face (index 3: one of the 4 side walls).
    const faceIdx = 3;
    final faceCentroid = before.faceCentroid(faceIdx);
    p.connectors.add(MateConnector(faceIdx, anchor: faceCentroid));

    // Drill a hole: buildSolid now returns many more faces, so the raw index 3
    // would point somewhere else.
    p.decorations.add(CircleEntity(const Offset(20, 15), 5));
    final after = p.buildSolid()!;
    expect(after.faces.length, greaterThan(before.faces.length));

    // The connector re-resolves to the SAME outer face — its origin is unchanged.
    final resolvedOrigin = p.connectors.first.origin(after);
    expect((resolvedOrigin - faceCentroid).length, lessThan(1e-6));

    // And its normal still points outward (away from the solid centroid).
    final n = p.connectors.first.normal(after);
    final outward = p.connectors.first.origin(after) - after.centroid;
    expect(n.x * outward.x + n.y * outward.y + n.z * outward.z, greaterThan(0));
  });

  test('a legacy connector (no anchor) falls back to the clamped face index', () {
    final p = _plate();
    final s = p.buildSolid()!;
    p.connectors.add(MateConnector(2)); // no anchor
    expect(p.connectors.first.resolvedFace(s), 2);
  });
}
