import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/entities.dart';
import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/sketch/part.dart';

// buildSolid now drills interior holes so the 3D wireframe shows them, matching
// STL export.

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
  test('a plain plate: no holes, buildSolid is a 6-face box', () {
    final p = _plate();
    expect(p.hasHoles, isFalse);
    expect(p.buildSolid()!.faces.length, 6); // 2 caps + 4 sides
  });

  test('an interior circle drills a hole (2 caps + 4 outer + 48 hole walls)', () {
    final p = _plate()..decorations.add(CircleEntity(const Offset(20, 15), 6));
    expect(p.hasHoles, isTrue);
    expect(p.buildSolid()!.faces.length, 6 + 48);
  });

  test('a sketched inner loop drills a hole (2 caps + 4 outer + 4 inner walls)', () {
    final p = _plate();
    final s = p.sketch;
    s.points.addAll(const [Offset(10, 10), Offset(30, 10), Offset(30, 20), Offset(10, 20)]);
    for (var i = 0; i < 4; i++) {
      s.segments.add(Segment(4 + i, 4 + (i + 1) % 4));
    }
    expect(p.hasHoles, isTrue);
    expect(p.buildSolid()!.faces.length, 6 + 4);
  });

  // Regression: an inner sketch that ISN'T a clean closed loop (e.g. a hole
  // drawn freehand that didn't close) must NOT make the whole outer profile
  // vanish. Loop extraction is robust — it keeps the closed loops it can find
  // and ignores open chains.
  test('an unclosed inner chain does not make the outer profile disappear', () {
    final p = _plate(); // closed outer square (4 pts / 4 segs)
    final s = p.sketch;
    // An OPEN inner chain: 4-5-6, no closing edge back to 4.
    s.points.addAll(const [Offset(10, 10), Offset(30, 10), Offset(30, 20)]);
    s.segments
      ..add(Segment(4, 5))
      ..add(Segment(5, 6));
    expect(p.buildSolid(), isNotNull, reason: 'the outer still extrudes');
    expect(p.buildSolid()!.faces.length, 6, reason: 'outer box, no hole');
    expect(p.hasHoles, isFalse);
  });

  test('outer + a second closed inner loop still drills a hole even with a '
      'stray open chain present', () {
    final p = _plate();
    final s = p.sketch;
    // A clean inner square (hole) ...
    s.points.addAll(const [Offset(8, 8), Offset(20, 8), Offset(20, 18), Offset(8, 18)]);
    for (var i = 0; i < 4; i++) {
      s.segments.add(Segment(4 + i, 4 + (i + 1) % 4));
    }
    // ... plus a stray open chain that must be ignored.
    s.points.addAll(const [Offset(30, 24), Offset(36, 26)]);
    s.segments.add(Segment(8, 9));
    expect(p.hasHoles, isTrue, reason: 'the closed inner loop is a hole');
    expect(p.buildSolid()!.faces.length, 6 + 4);
  });
}
