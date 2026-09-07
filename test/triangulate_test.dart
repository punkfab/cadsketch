import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/triangulate.dart';

double _triArea(List<Offset> t) =>
    ((t[1].dx - t[0].dx) * (t[2].dy - t[0].dy) -
            (t[2].dx - t[0].dx) * (t[1].dy - t[0].dy))
        .abs() /
    2;

double _sumArea(List<List<Offset>> tris) =>
    tris.fold(0.0, (s, t) => s + _triArea(t));

List<Offset> _circle(Offset c, double r, int n) => [
      for (var i = 0; i < n; i++)
        c + Offset(math.cos(2 * math.pi * i / n), math.sin(2 * math.pi * i / n)) * r,
    ];

void main() {
  test('a plain square triangulates to 2 triangles covering its area', () {
    final t = triangulateWithHoles(
        const [Offset(0, 0), Offset(10, 0), Offset(10, 10), Offset(0, 10)], const []);
    expect(t.length, 2);
    expect(_sumArea(t), closeTo(100, 1e-6));
  });

  test('square with a square hole: triangle area == outer - hole', () {
    final outer = const [Offset(0, 0), Offset(20, 0), Offset(20, 20), Offset(0, 20)];
    final hole = const [Offset(8, 8), Offset(12, 8), Offset(12, 12), Offset(8, 12)];
    final t = triangulateWithHoles(outer, [hole]);
    expect(_sumArea(t), closeTo(400 - 16, 1e-4)); // 400 outer - 16 hole
  });

  test('square with a circular hole covers outer minus the disc', () {
    final outer = const [Offset(0, 0), Offset(40, 0), Offset(40, 30), Offset(0, 30)];
    final hole = _circle(const Offset(20, 15), 5, 48);
    final t = triangulateWithHoles(outer, [hole]);
    // Area of the tessellated disc (48-gon), not pi*r^2.
    final discArea = 0.5 * 48 * 25 * math.sin(2 * math.pi / 48);
    expect(_sumArea(t), closeTo(1200 - discArea, 1e-2));
  });

  test('two holes both get cut', () {
    final outer = const [Offset(0, 0), Offset(30, 0), Offset(30, 10), Offset(0, 10)];
    final h1 = const [Offset(5, 3), Offset(9, 3), Offset(9, 7), Offset(5, 7)];
    final h2 = const [Offset(20, 3), Offset(24, 3), Offset(24, 7), Offset(20, 7)];
    final t = triangulateWithHoles(outer, [h1, h2]);
    expect(_sumArea(t), closeTo(300 - 16 - 16, 1e-4));
  });
}
