import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/sketch/part.dart';

// Stage 2: arcs are model entities that join closed line+arc contours, solve
// (endpoints held on the circle), tessellate for extrusion, and extrude.

ParametricSketch _slot() {
  final m = ParametricSketch();
  m.addLine(const Offset(0, 40), const Offset(100, 40)); // top
  m.addArc(const Offset(100, 40), const Offset(100, 0),
      const Offset(100, 20), 20, -math.pi); // right cap
  m.addLine(const Offset(100, 0), const Offset(0, 0)); // bottom
  m.addArc(const Offset(0, 0), const Offset(0, 40),
      const Offset(0, 20), 20, -math.pi); // left cap
  return m;
}

void main() {
  test('slot contour: 4 points, 2 arcs, endpoints solved onto their circles', () {
    final m = _slot();
    expect(m.points.length, 4);
    expect(m.segments.length, 4);
    expect(m.segments.where((s) => s.isArc).length, 2);
    for (final s in m.segments.where((s) => s.isArc)) {
      expect((m.points[s.a] - s.arc!.center).distance, closeTo(s.arc!.radius, 1.0));
      expect((m.points[s.b] - s.arc!.center).distance, closeTo(s.arc!.radius, 1.0));
    }
  });

  test('slot tessellates into a closed profile and extrudes', () {
    final m = _slot();
    final profile = m.closedProfile();
    expect(profile, isNotNull);
    expect(profile!.length, greaterThan(10)); // arcs become many points

    final part = Part('slot');
    // rebuild the same contour on the part's sketch
    part.sketch.addLine(const Offset(0, 40), const Offset(100, 40));
    part.sketch.addArc(const Offset(100, 40), const Offset(100, 0),
        const Offset(100, 20), 20, -math.pi);
    part.sketch.addLine(const Offset(100, 0), const Offset(0, 0));
    part.sketch.addArc(const Offset(0, 0), const Offset(0, 40),
        const Offset(0, 20), 20, -math.pi);
    final solid = part.buildSolid();
    expect(solid, isNotNull);
    expect(solid!.vertices.length, part.sketch.closedProfile()!.length * 2);
  });

  test('plain rectangle (no arcs) still extrudes as before', () {
    final p = Part('rect');
    p.sketch.addPolyline(const [
      Offset(0, 0),
      Offset(120, 0),
      Offset(120, 80),
      Offset(0, 80),
      Offset(0, 0),
    ]);
    final s = p.buildSolid();
    expect(s, isNotNull);
    expect(s!.vertices.length, 8); // unaffected by the arc path
  });
}
