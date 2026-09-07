import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/dxf.dart';
import 'package:ai_sketcher/sketch/entities.dart';
import 'package:ai_sketcher/ui/sketch_canvas.dart';

/// Builds DXF text from (group code, value) pairs — one per line, as DXF wants.
String _dxf(List<(int, Object)> pairs) =>
    '${pairs.map((p) => '${p.$1}\n${p.$2}').join('\n')}\n';

// A drawing with one of each supported entity.
final _mixed = _dxf([
  (0, 'SECTION'), (2, 'ENTITIES'),
  (0, 'LINE'), (10, 0.0), (20, 0.0), (11, 40.0), (21, 0.0),
  (0, 'CIRCLE'), (10, 20.0), (20, 15.0), (40, 5.0),
  (0, 'LWPOLYLINE'), (90, 4), (70, 1),
  (10, 0.0), (20, 0.0),
  (10, 40.0), (20, 0.0),
  (10, 40.0), (20, 30.0),
  (10, 0.0), (20, 30.0),
  (0, 'ARC'), (10, 0.0), (20, 0.0), (40, 10.0), (50, 0.0), (51, 90.0),
  (0, 'ENDSEC'), (0, 'EOF'),
]);

// A single closed square as an LWPOLYLINE.
final _square = _dxf([
  (0, 'SECTION'), (2, 'ENTITIES'),
  (0, 'LWPOLYLINE'), (90, 4), (70, 1),
  (10, 0.0), (20, 0.0),
  (10, 40.0), (20, 0.0),
  (10, 40.0), (20, 30.0),
  (10, 0.0), (20, 30.0),
  (0, 'ENDSEC'), (0, 'EOF'),
]);

void main() {
  test('parseDxf reads LINE / LWPOLYLINE / CIRCLE / ARC', () {
    final d = parseDxf(_mixed);
    expect(d.lines.length, 1);
    expect(d.lines.first.a, const Offset(0, 0));
    expect(d.lines.first.b, const Offset(40, 0));

    expect(d.polylines.length, 1);
    expect(d.polylines.first.closed, isTrue);
    expect(d.polylines.first.points.length, 4);

    expect(d.circles.length, 1);
    expect(d.circles.first.center, const Offset(20, 15));
    expect(d.circles.first.radius, 5.0);

    expect(d.arcs.length, 1);
    expect(d.arcs.first.radius, 10.0);
    expect(d.arcs.first.startDeg, 0.0);
    expect(d.arcs.first.endDeg, 90.0);

    expect(d.entityCount, 4);
    expect(d.isEmpty, isFalse);
  });

  test('parseDxf on empty/blank text yields an empty drawing', () {
    expect(parseDxf('').isEmpty, isTrue);
  });

  test('importDxf: a closed polyline becomes an extrudable profile', () {
    final c = SketchController();
    c.importDxf('sq', parseDxf(_square));
    final p = c.active;
    expect(p.name, 'sq');
    expect(p.sketch.points.length, 4, reason: 'closed loop welds to 4 vertices');
    expect(p.sketch.segments.length, 4);
    // Every vertex degree 2 -> a single closed loop -> extrudes to a 6-face box.
    expect(p.buildSolid()!.faces.length, 6);
  });

  test('importDxf: a CIRCLE becomes a circle decoration', () {
    final c = SketchController();
    c.importDxf('mixed', parseDxf(_mixed));
    expect(c.active.decorations.whereType<CircleEntity>().length, 1);
    // The closed polyline still drives the profile.
    expect(c.active.buildSolid()!.faces.length, greaterThan(6)); // box + circle hole walls
  });

  test('importDxf flips Y so the drawing is upright (DXF is Y-up)', () {
    final c = SketchController();
    c.importDxf('sq', parseDxf(_square));
    // DXF ys were 0 and 30; flipped to 0 and -30.
    final ys = c.active.sketch.points.map((p) => p.dy).toList()..sort();
    expect(ys.first, -30);
    expect(ys.last, 0);
  });
}
