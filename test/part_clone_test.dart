import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/entities.dart';
import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/sketch/part.dart';
import 'package:ai_sketcher/ui/sketch_canvas.dart';

// Duplicating a part must be a DEEP copy so a reused part in an assembly can be
// edited independently. Plus the mate/connector bookkeeping that unmate + delete
// rely on.

Part _plate(String name) {
  final p = Part(name)
    ..depth = 20
    ..operation = FeatureOp.difference;
  final s = p.sketch;
  s.points.addAll(const [Offset(0, 0), Offset(10, 0), Offset(10, 10), Offset(0, 10)]);
  for (var i = 0; i < 4; i++) {
    s.segments.add(Segment(i, (i + 1) % 4));
  }
  s.constraints.add(SketchConstraint(ConstraintKind.horizontal, const [0]));
  p.decorations.add(CircleEntity(const Offset(5, 5), 3));
  p.connectors.add(MateConnector(1));
  return p;
}

void main() {
  test('clone is a deep, independent copy', () {
    final a = _plate('Plate');
    final b = a.clone('Plate copy');

    expect(b.name, 'Plate copy');
    expect(b.depth, 20);
    expect(b.operation, FeatureOp.difference);
    expect(b.sketch.points.length, 4);
    expect(b.sketch.segments.length, 4);
    expect(b.sketch.constraints.length, 1);
    expect(b.connectors.length, 1);
    expect((b.decorations.single as CircleEntity).radius, 3);

    // Mutating the copy must not touch the original.
    (b.decorations.single as CircleEntity).radius = 99;
    b.sketch.points.add(const Offset(20, 20));
    b.connectors.add(MateConnector(2));
    expect((a.decorations.single as CircleEntity).radius, 3);
    expect(a.sketch.points.length, 4);
    expect(a.connectors.length, 1);
  });

  test('duplicatePart appends a copy and makes it active', () {
    final c = SketchController();
    c.parts
      ..clear()
      ..add(_plate('Plate'));
    c.activeIndex = 0;
    c.duplicatePart(0);
    expect(c.parts.length, 2);
    expect(c.activeIndex, 1);
    expect(c.active.name, 'Plate copy');
  });

  test('removeConnector drops referencing mates and reindexes the rest', () {
    final c = SketchController();
    final a = _plate('A')..connectors.add(MateConnector(0)); // 2 connectors: 0,1
    final b = _plate('B'); // 1 connector: 0
    c.parts
      ..clear()
      ..addAll([a, b]);
    // Mate A.conn0<->B.conn0 and A.conn1<->B.conn0.
    c.addMate(0, 0, 1, 0);
    c.addMate(0, 1, 1, 0);
    expect(c.mates.length, 2);

    // Remove A's connector 0 → its mate goes, and A's connector 1 becomes 0.
    c.removeConnector(0, 0);
    expect(a.connectors.length, 1); // had 2, removed one
    expect(c.mates.length, 1);
    expect(c.mates.single.connectorA, 0); // was 1, reindexed down
  });

  test('clearMates and clearConnectors empty the assembly state', () {
    final c = SketchController();
    c.parts
      ..clear()
      ..addAll([_plate('A'), _plate('B')]);
    c.addMate(0, 0, 1, 0);
    c.clearMates();
    expect(c.mates, isEmpty);
    c.clearConnectors(0);
    expect(c.parts[0].connectors, isEmpty);
  });
}
