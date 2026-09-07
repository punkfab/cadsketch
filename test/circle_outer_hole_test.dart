import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/entities.dart';
import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/sketch/part.dart';

// Regression: profileWithHoles only ever treated SKETCHED loops as the outer
// boundary, so a circle outline with a sketched hole inside (e.g. a triangle)
// picked the small triangle as "outer" and the big circle as a "hole" — an
// inverted, non-renderable solid. Circles are now outer-boundary candidates too:
// the largest region wins the boundary, the rest inside it are holes.

void main() {
  test('a triangular hole inside a circle: circle is the outer boundary', () {
    final p = Part('washer')..depth = 10;
    // Outer boundary: a circle decoration.
    p.decorations.add(CircleEntity(const Offset(0, 0), 30));
    // Inner hole: a small sketched triangle around the center.
    final s = p.sketch;
    s.points.addAll(const [Offset(-8, -6), Offset(8, -6), Offset(0, 8)]);
    for (var i = 0; i < 3; i++) {
      s.segments.add(Segment(i, (i + 1) % 3));
    }

    final pw = p.profileWithHoles()!;
    // The circle (tessellated to many points) is the outer, NOT the 3-pt triangle.
    expect(pw.outer.length, greaterThan(3));
    expect(pw.holes.length, 1);
    expect(pw.holes.first.length, 3, reason: 'the triangle is the hole');
    expect(p.hasHoles, isTrue);

    // 2 caps + 48 outer (circle) walls + 3 triangle walls.
    expect(p.buildSolid()!.faces.length, 2 + 48 + 3);
  });

  test('a plain circle still extrudes to a solid cylinder (no holes)', () {
    final p = Part('disc')..depth = 10;
    p.decorations.add(CircleEntity(const Offset(0, 0), 20));
    expect(p.hasHoles, isFalse);
    expect(p.buildSolid()!.faces.length, 2 + 48); // 2 caps + 48 side walls
  });

  test('a smaller circle inside a bigger circle is a round hole', () {
    final p = Part('ring')..depth = 10;
    p.decorations
      ..add(CircleEntity(const Offset(0, 0), 30))
      ..add(CircleEntity(const Offset(0, 0), 10));
    final pw = p.profileWithHoles()!;
    expect(pw.holes.length, 1);
    expect(p.hasHoles, isTrue);
  });
}
