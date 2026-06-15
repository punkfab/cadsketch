import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/model.dart';

// Regularization toward the drawn positions should keep under-constrained
// degrees of freedom from running far away from where they were sketched.
void main() {
  test('under-constrained sketch stays near drawn positions (no runaway)', () {
    final m = ParametricSketch();
    m.addLine(const Offset(0, 0), const Offset(120, 8)); // ~horizontal
    m.addLine(const Offset(122, 10), const Offset(118, 130)); // ~perpendicular

    // Drawn region spans ~130px; nothing should fly hundreds of px away.
    for (final p in m.points) {
      expect(p.dx.abs() < 400 && p.dy.abs() < 400, isTrue, reason: 'runaway: $p');
    }
  });

  test('axis snapping still works with regularization', () {
    final m = ParametricSketch();
    m.addLine(const Offset(0, 0), const Offset(200, 6)); // ~horizontal
    final s = m.segments[0];
    expect((m.points[s.a].dy - m.points[s.b].dy).abs(), lessThan(0.5));
  });
}
