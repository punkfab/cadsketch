import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/model.dart';

double _distToLine(Offset c, Offset a, Offset b) {
  final abx = b.dx - a.dx, aby = b.dy - a.dy;
  final len = math.sqrt(abx * abx + aby * aby);
  return ((c.dx - a.dx) * aby - (c.dy - a.dy) * abx).abs() / len;
}

void main() {
  test('a line meeting an arc tangentially infers and solves tangency', () {
    final m = ParametricSketch();
    m.addLine(const Offset(0, 50), const Offset(100, 50)); // horizontal
    m.addArc(const Offset(100, 50), const Offset(150, 100),
        const Offset(100, 98), 50, math.pi / 2); // ~tangent, center perturbed

    expect(m.constraints.any((c) => c.kind == ConstraintKind.tangent), isTrue);

    final line = m.segments[0];
    final arc = m.segments[1].arc!;
    // tangent: perpendicular distance from the arc center to the line == radius
    expect(_distToLine(arc.center, m.points[line.a], m.points[line.b]),
        closeTo(arc.radius, 1.0));
  });

  test('a clearly non-tangent meeting does not infer tangency', () {
    final m = ParametricSketch();
    m.addLine(const Offset(0, 0), const Offset(100, 0));
    m.addArc(const Offset(100, 0), const Offset(100, 60),
        const Offset(160, 0), 60, math.pi / 2); // radius along the line
    expect(m.constraints.any((c) => c.kind == ConstraintKind.tangent), isFalse);
  });
}
