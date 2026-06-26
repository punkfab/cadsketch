import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/model.dart';

// Direct-manipulation editing: dragging a vertex (pin-and-relax solve) and
// deleting geometry while keeping the points/segments/constraints indices
// consistent (the kernel's "id == list index" contract).

ParametricSketch _square() {
  return ParametricSketch()
    ..addPolyline(const [
      Offset(0, 0),
      Offset(100, 0),
      Offset(100, 100),
      Offset(0, 100),
      Offset(0, 0),
    ]);
}

void main() {
  test('a closed square is 4 points / 4 segments', () {
    final m = _square();
    expect(m.points.length, 4);
    expect(m.segments.length, 4);
  });

  test('dragPoint pins the dragged vertex at the cursor', () {
    final m = _square();
    const target = Offset(140, 30);
    m.dragPoint(2, target);
    // The pinned vertex stays under the cursor; the rest relaxes around it.
    expect((m.points[2] - target).distance, lessThan(1.0));
  });

  test('hitTestPoint finds the nearest vertex within radius (else null)', () {
    final m = _square();
    expect(m.hitTestPoint(const Offset(102, 3)), 1); // near (100, 0)
    expect(m.hitTestPoint(const Offset(50, 50)), isNull); // mid, far from any
  });

  test('removeSegment drops the edge + its constraints, keeps a clean index set',
      () {
    final m = _square();
    final before = m.segments.length;
    m.removeSegment(0);
    expect(m.segments.length, before - 1);
    // Every constraint still references a valid (remapped) segment index.
    for (final c in m.constraints) {
      for (final s in c.segments) {
        expect(s, inInclusiveRange(0, m.segments.length - 1));
      }
    }
    // Removing one edge of the loop leaves all four corners still in use.
    expect(m.points.length, 4);
    // Every segment endpoint is a valid point index.
    for (final s in m.segments) {
      expect(s.a, inInclusiveRange(0, m.points.length - 1));
      expect(s.b, inInclusiveRange(0, m.points.length - 1));
    }
  });

  test('removePoint removes incident segments and prunes the orphaned vertex',
      () {
    final m = _square();
    m.removePoint(0); // corner shared by 2 edges
    expect(m.segments.length, 2); // its two edges go
    expect(m.points.length, 3); // the corner is pruned (now unused)
    for (final s in m.segments) {
      expect(s.a, inInclusiveRange(0, m.points.length - 1));
      expect(s.b, inInclusiveRange(0, m.points.length - 1));
    }
  });

  test('deleting every segment empties the sketch', () {
    final m = _square();
    while (m.segments.isNotEmpty) {
      m.removeSegment(0);
    }
    expect(m.segments, isEmpty);
    expect(m.points, isEmpty);
    expect(m.constraints, isEmpty);
  });
}
