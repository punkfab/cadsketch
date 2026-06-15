import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/ffi/sketch_kernel_ffi.dart';

// Stage 1 of unifying circles/arcs into the solver: radius is now a solve
// unknown, with point-on-circle / radius / tangent constraints.
void main() {
  test('kernel ABI v4', () => expect(SketchKernel.instance.version, 4));

  test('radius dimension drives a point onto the circle', () {
    final s = SketchKernel.instance.newSketch();
    final center = s.addPoint(const Offset(0, 0));
    final p = s.addPoint(const Offset(40, 0));
    s.fixPoint(center);
    final r = s.addRadius(40);
    s.pointOnCircle(p, center, r);
    s.constrainRadius(r, 100);
    expect(s.solve(), isTrue);
    expect(s.radius(r), closeTo(100, 1e-2));
    expect((s.point(p) - s.point(center)).distance, closeTo(100, 1e-2));
    s.dispose();
  });

  test('a line solves to tangent with a fixed-radius circle', () {
    final s = SketchKernel.instance.newSketch();
    final center = s.addPoint(const Offset(0, 0));
    s.fixPoint(center);
    final r = s.addRadius(50);
    s.constrainRadius(r, 50);
    final a = s.addPoint(const Offset(-100, -60));
    final b = s.addPoint(const Offset(100, -62));
    s.horizontal(a, b);
    s.tangentLine(a, b, center, r);
    expect(s.solve(), isTrue);

    final pa = s.point(a), pb = s.point(b);
    final abx = pb.dx - pa.dx, aby = pb.dy - pa.dy;
    final len = math.sqrt(abx * abx + aby * aby);
    final dist = ((0 - pa.dx) * aby - (0 - pa.dy) * abx).abs() / len;
    expect(dist, closeTo(50, 1e-2)); // perpendicular distance == radius
    s.dispose();
  });
}
