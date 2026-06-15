import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/assembly.dart';
import 'package:ai_sketcher/sketch/entities.dart';
import 'package:ai_sketcher/sketch/part.dart';
import 'package:ai_sketcher/ui/sketch_canvas.dart';

// End-to-end flows through SketchController: draw -> recognize -> solve ->
// extrude -> assemble -> parameterize. These cross module boundaries (kernel
// FFI included), so they run under `flutter test` with the native lib.

/// A straight stroke a->b with a midpoint (enough points + length to recognize).
List<Offset> _seg(Offset a, Offset b) => [a, Offset.lerp(a, b, 0.5)!, b];

/// Draws a rough rectangle as four separate strokes (corners merge).
void _drawRect(SketchController c, double w, double h) {
  c.addStroke(_seg(const Offset(0, 0), Offset(w, 2)));
  c.addStroke(_seg(Offset(w, 2), Offset(w + 2, h)));
  c.addStroke(_seg(Offset(w + 2, h), Offset(-2, h - 2)));
  c.addStroke(_seg(Offset(-2, h - 2), const Offset(1, 1)));
}

List<Offset> _circleStroke(Offset c, double r, int n) => List.generate(n, (i) {
      final t = 2 * math.pi * i / (n - 1);
      return Offset(c.dx + r * math.cos(t), c.dy + r * math.sin(t));
    });

double _width(Part p) {
  final s = p.buildSolid()!;
  var lo = double.infinity, hi = -double.infinity;
  for (final v in s.vertices) {
    lo = math.min(lo, v.x);
    hi = math.max(hi, v.x);
  }
  return hi - lo;
}

void main() {
  test('draw rectangle -> recognized as 4 segments -> extrudes to a prism', () {
    final c = SketchController();
    _drawRect(c, 200, 120);
    expect(c.model.segments.length, 4);
    expect(c.decorations, isEmpty);
    final solid = c.active.buildSolid();
    expect(solid, isNotNull);
    expect(solid!.vertices.length, 8);
  });

  test('draw circle -> decoration -> extrudes to a cylinder', () {
    final c = SketchController();
    c.addStroke(_circleStroke(const Offset(0, 0), 60, 40));
    expect(c.decorations.whereType<CircleEntity>(), isNotEmpty);
    expect(c.model.segments, isEmpty);
    final solid = c.active.buildSolid()!;
    expect(solid.vertices.length, 96); // 48 facets x 2
  });

  test('two parts mate into a coincident assembly', () {
    final c = SketchController();
    _drawRect(c, 100, 100);
    c.addConnector(1); // a cap of part 0
    c.addPart();
    _drawRect(c, 100, 100);
    c.addConnector(0); // a cap of part 1
    c.addMate(0, 0, 1, 0);

    final xf = solveAssembly(c.parts, c.mates);
    expect(xf.containsKey(1), isTrue);
    final sa = c.parts[0].buildSolid()!, sb = c.parts[1].buildSolid()!;
    final oa = xf[0]!.apply(c.parts[0].connectors[0].origin(sa));
    final ob = xf[1]!.apply(c.parts[1].connectors[0].origin(sb));
    expect((oa - ob).length, lessThan(1e-6));
  });

  test('shared parameter resizes the extruded solid', () {
    final c = SketchController();
    _drawRect(c, 200, 100);
    c.bindDimension(0, 'W'); // top edge -> W (~200)
    expect(_width(c.active), closeTo(200, 3));

    c.setParameter('W', 320);
    expect(_width(c.active), greaterThan(290)); // solid actually got wider
  });

  test('clear resets the active part only', () {
    final c = SketchController();
    _drawRect(c, 100, 100);
    c.addPart();
    _drawRect(c, 80, 80);
    expect(c.parts.length, 2);

    c.clear(); // clears active (part 2)
    expect(c.active.sketch.segments, isEmpty);
    expect(c.parts[0].sketch.segments.length, 4); // part 1 intact
  });

  test('driving a dimension changes the solved geometry', () {
    final c = SketchController();
    _drawRect(c, 200, 100);
    c.setDrivingLength(0, 300); // drive top edge length
    expect(c.model.measuredLength(0), closeTo(300, 2));
  });

  test('a circle radius is settable and resizes the cylinder', () {
    final c = SketchController();
    c.addStroke(_circleStroke(const Offset(0, 0), 60, 40));
    final ci = c.decorations.indexWhere((e) => e is CircleEntity);
    expect(ci, isNonNegative);
    c.setCircleRadius(ci, 40);
    expect((c.decorations[ci] as CircleEntity).radius, 40);
    expect(_width(c.active), closeTo(80, 2)); // diameter
  });

  test('a shared parameter drives a circle radius (and its cylinder)', () {
    final c = SketchController();
    c.addStroke(_circleStroke(const Offset(0, 0), 60, 40));
    final ci = c.decorations.indexWhere((e) => e is CircleEntity);
    c.bindCircleRadius(ci, 'D');
    c.setParameter('D', 100);
    expect((c.decorations[ci] as CircleEntity).radius, 100);
    expect(_width(c.active), closeTo(200, 2));
  });
}
