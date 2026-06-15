import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/entities.dart';
import 'package:ai_sketcher/sketch/part.dart';

void main() {
  Part squarePart() {
    final p = Part('p');
    p.sketch.addPolyline(const [
      Offset(0, 0),
      Offset(40, 0),
      Offset(40, 30),
      Offset(0, 30),
      Offset(0, 0),
    ]);
    return p;
  }

  test('part builds a prism solid from a closed profile', () {
    final p = squarePart();
    final s = p.buildSolid();
    expect(s, isNotNull);
    expect(s!.vertices.length, 8); // 4 bottom + 4 top
    expect(s.faces.length, 6); // 2 caps + 4 sides
  });

  test('cap faces have vertical normals, side faces horizontal', () {
    final s = squarePart().buildSolid()!;
    // Faces 0,1 are the caps.
    for (final f in [0, 1]) {
      final n = s.faceNormal(f);
      expect(n.z.abs(), closeTo(1, 1e-6));
      expect(n.x.abs() + n.y.abs(), lessThan(1e-6));
    }
    // Faces 2..5 are the sides.
    for (var f = 2; f < 6; f++) {
      expect(s.faceNormal(f).z.abs(), lessThan(1e-6));
    }
  });

  test('connector origin/normal computed live from the solid', () {
    final p = squarePart();
    p.connectors.add(MateConnector(2)); // a side face
    final s = p.buildSolid()!;
    final c = p.connectors.first;
    expect(c.normal(s).length, closeTo(1, 1e-6));
    // origin is the face centroid -> lies within the solid bounds
    final o = c.origin(s);
    expect(o.z, inInclusiveRange(0, p.depth));
  });

  test('no closed profile -> no solid', () {
    final p = Part('open');
    p.sketch.addLine(const Offset(0, 0), const Offset(50, 0));
    expect(p.buildSolid(), isNull);
  });

  test('a circle decoration extrudes to a cylinder', () {
    final p = Part('cyl');
    p.decorations.add(const CircleEntity(Offset(0, 0), 30));
    final s = p.buildSolid();
    expect(s, isNotNull);
    expect(s!.vertices.length, 96); // 48 facets x 2 rings
    expect(s.faces.length, 50); // 2 caps + 48 sides
  });
}
