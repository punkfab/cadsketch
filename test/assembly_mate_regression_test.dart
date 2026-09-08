import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/sketch/plane.dart';
import 'package:ai_sketcher/sketch/solid.dart';
import 'package:ai_sketcher/ui/assembly_view.dart';
import 'package:ai_sketcher/ui/sketch_canvas.dart';

// Regressions for: phantom mate points (duplicate carrying connectors) and parts
// vanishing from the assembly (features orphaned when their base body is deleted).

void _square(ParametricSketch m, double w, double h) {
  final b = m.points.length;
  m.points.addAll([Offset(0, 0), Offset(w, 0), Offset(w, h), Offset(0, h)]);
  for (var i = 0; i < 4; i++) {
    m.segments.add(Segment(b + i, b + (i + 1) % 4));
  }
}

SketchController _square1() {
  final c = SketchController();
  _square(c.model, 40, 30);
  return c;
}

void main() {
  test('duplicating a part does NOT copy its mate points (no phantom pins)', () {
    final c = _square1();
    c.addConnector(2); // an explicit mate point on part 0
    expect(c.active.connectors.length, 1);

    c.duplicatePart(0);
    expect(c.parts.length, 2);
    expect(c.parts[1].connectors, isEmpty,
        reason: 'a duplicate starts with no mate points');
  });

  test('a new part has no mate points even if another part has them', () {
    final c = _square1();
    c.addConnector(2);
    c.addPart();
    expect(c.active.connectors, isEmpty);
  });

  test('a base body + its feature render as ONE assembly body', () {
    final c = _square1();
    final base = c.parts[0];
    c.addPlaneSketch(SketchPlane.xy, name: 'Boss',
        reference: const [Offset(0, 0), Offset(20, 0), Offset(20, 20)],
        parent: base);
    _square(c.model, 20, 20); // the feature profile
    expect(assemblyBodies(c.parts, c.mates).length, 1);
  });

  test('deleting a base body keeps its features in the assembly (re-parented)',
      () {
    final c = _square1(); // part 0: base
    final base = c.parts[0];
    c.addPlaneSketch(SketchPlane.xy, name: 'Boss',
        reference: const [Offset(0, 0), Offset(20, 0), Offset(20, 20)],
        parent: base);
    _square(c.model, 20, 20); // part 1: the feature
    expect(assemblyBodies(c.parts, c.mates).length, 1);

    c.removePart(0); // delete the base
    expect(c.parts.length, 1);
    expect(c.parts[0].parent, isNull,
        reason: 'the orphaned feature is promoted to a base body');
    expect(assemblyBodies(c.parts, c.mates).length, 1,
        reason: 'the ex-feature still shows in the assembly');
  });

  test('deleting a feature leaves the base body visible', () {
    final c = _square1(); // part 0: base
    final base = c.parts[0];
    c.addPlaneSketch(SketchPlane.xy, name: 'Boss',
        reference: const [Offset(0, 0), Offset(20, 0), Offset(20, 20)],
        parent: base);
    _square(c.model, 20, 20); // part 1: the feature
    c.removePart(1); // delete the feature
    expect(c.parts.length, 1);
    expect(assemblyBodies(c.parts, c.mates).length, 1);
  });

  test('an imported-mesh part shows as its own assembly body', () {
    final c = _square1(); // part 0: a sketched base body
    final mesh = extrudeProfile(
        const [Offset(0, 0), Offset(20, 0), Offset(20, 20), Offset(0, 20)], 10);
    c.importSolid('mesh', mesh); // part 1: imported geometry
    expect(assemblyBodies(c.parts, c.mates).length, 2,
        reason: 'both the sketched body and the imported mesh appear');
  });

  test('a part with an open (non-closed) sketch is simply absent, not a crash',
      () {
    final c = _square1(); // part 0: a closed body
    c.addPart(); // part 1
    c.model.points.addAll(const [Offset(0, 0), Offset(30, 0)]); // one open edge
    c.model.segments.add(Segment(0, 1));
    final bodies = assemblyBodies(c.parts, c.mates);
    expect(bodies.length, 1, reason: 'only the closed body extrudes');
  });
}
