import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/beautify.dart';
import 'package:ai_sketcher/sketch/entities.dart';

// Synthetic strokes with hand-wobble. Needs the native kernel (loaded from
// build/native via the FFI fallback path under `flutter test`).

List<Offset> _ellipse(double a, double b, double a0, double sweep, int n) =>
    List.generate(n, (i) {
      final t = a0 + sweep * (i / (n - 1));
      final rx = a + ((i % 4) - 1.5) * 1.5; // wobble
      final ry = b + ((i % 3) - 1) * 1.5;
      return Offset(rx * math.cos(t), ry * math.sin(t));
    });

List<Offset> _polygon(double r, int sides, int perEdge) {
  final pts = <Offset>[];
  for (var s = 0; s < sides; s++) {
    final a0 = 2 * math.pi * s / sides, a1 = 2 * math.pi * (s + 1) / sides;
    final p0 = Offset(r * math.cos(a0), r * math.sin(a0));
    final p1 = Offset(r * math.cos(a1), r * math.sin(a1));
    for (var i = 0; i < perEdge; i++) {
      final t = i / perEdge;
      pts.add(Offset(p0.dx + (p1.dx - p0.dx) * t, p0.dy + (p1.dy - p0.dy) * t));
    }
  }
  return pts..add(pts.first);
}

T _entity<T>(StrokeResult r) => (r as DecorationResult).entity as T;

void main() {
  test('full circle -> CircleEntity', () {
    final r = recognizeStroke(_ellipse(60, 60, 0, 2 * math.pi, 48));
    expect(_entity<CircleEntity>(r), isA<CircleEntity>());
  });

  test('freehand oval snaps to CircleEntity', () {
    final r = recognizeStroke(_ellipse(70, 48, 0, 2 * math.pi, 48));
    expect(r, isA<DecorationResult>());
    expect((r as DecorationResult).entity, isA<CircleEntity>());
  });

  test('half and quarter arcs -> ArcResult (model arc, joins contours)', () {
    expect(recognizeStroke(_ellipse(80, 80, 0, math.pi, 24)), isA<ArcResult>());
    expect(recognizeStroke(_ellipse(80, 80, 0, math.pi / 2, 16)), isA<ArcResult>());
  });

  test('polygons -> PolylineResult', () {
    expect(recognizeStroke(_polygon(60, 3, 12)), isA<PolylineResult>()); // triangle
    expect(recognizeStroke(_polygon(60, 4, 12)), isA<PolylineResult>()); // square
    expect(recognizeStroke(_polygon(60, 5, 10)), isA<PolylineResult>()); // pentagon
  });

  test('single straight stroke -> 2-vertex polyline', () {
    final r = recognizeStroke([
      const Offset(0, 0),
      const Offset(60, 1),
      const Offset(120, 0),
    ]);
    expect(r, isA<PolylineResult>());
    expect((r as PolylineResult).vertices.length, 2);
  });
}
