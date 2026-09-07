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
}
