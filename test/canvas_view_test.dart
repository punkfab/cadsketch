import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/mcp/host_document.dart';
import 'package:ai_sketcher/mcp/part_spec.dart';
import 'package:ai_sketcher/sketch/plane.dart';
import 'package:ai_sketcher/ui/sketch_canvas.dart';

// The 2D view transform (screen = model * zoom + pan), read off the painter.
//
// Both regressions showed up embedded in a chat host, because that is where a
// part arrives in millimetres near the origin and the view is fitted to it:
//   * wheel zoom scaled about a fixed anchor, so a fitted or panned drawing
//     slid off to the side as you zoomed;
//   * a sketch on a face kept the pan fitted to the body, so the face was off
//     screen and what you drew landed far from it.

({Offset pan, double zoom}) _view(WidgetTester tester) {
  final paint = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).firstWhere(
      (p) => p.painter.runtimeType.toString() == '_SketchPainter');
  final dynamic painter = paint.painter;
  return (pan: painter.pan as Offset, zoom: painter.zoom as double);
}

Future<SketchController> _pumpPlate(WidgetTester tester) async {
  final c = SketchController();
  await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SketchCanvas(controller: c))));
  // A host-drawn 80 x 40 mm plate: loadPartSpecs fits the view to it.
  loadPartSpecs(c, [
    PartSpec.fromJson({
      'name': 'plate',
      'depth': 4,
      'profile': [
        [0, 0],
        [80, 0],
        [80, 40],
        [0, 40]
      ],
    })
  ]);
  await tester.pump();
  return c;
}

void main() {
  testWidgets('wheel zoom keeps the point under the cursor where it is', (tester) async {
    await _pumpPlate(tester);
    final before = _view(tester);
    expect(before.zoom, greaterThan(2)); // fitted, so the old anchor is far away

    const cursor = Offset(520, 330);
    final under = (cursor - before.pan) / before.zoom;
    for (final dy in [120.0, 120.0, 120.0, -120.0]) {
      await tester.sendEventToBinding(
          PointerScrollEvent(position: cursor, scrollDelta: Offset(0, dy)));
      await tester.pump();
    }
    // A trackpad pinch reaches a web build as a scale signal.
    await tester.sendEventToBinding(
        const PointerScaleEvent(position: cursor, scale: 0.8));
    await tester.pump();
    final after = _view(tester);
    expect(after.zoom, lessThan(before.zoom * 0.8));
    expect(((cursor - after.pan) / after.zoom - under).distance, lessThan(1e-6));
  });

  testWidgets('a sketch on a face opens centred on that face', (tester) async {
    final c = await _pumpPlate(tester);
    final base = c.active;
    // The top face, as the 3D view hands it over: outline in plane coords,
    // origin at the face centroid.
    final solid = base.buildSolid()!;
    final plane = SketchPlane.fromFace(solid, 1);
    final reference = [for (final vi in solid.faces[1]) plane.to2d(solid.vertices[vi])];
    c.addPlaneSketch(plane, name: 'Face sketch', reference: reference, parent: base);
    await tester.pump();

    final v = _view(tester);
    final onScreen = [for (final p in reference) p * v.zoom + v.pan];
    final pane = tester.getSize(find.byType(SketchCanvas));
    for (final p in onScreen) {
      expect(p.dx, inInclusiveRange(0, pane.width));
      expect(p.dy, inInclusiveRange(0, pane.height));
    }
    // ...and filling a good part of the pane, not a speck.
    final width = onScreen.map((p) => p.dx).reduce((a, b) => a > b ? a : b) -
        onScreen.map((p) => p.dx).reduce((a, b) => a < b ? a : b);
    expect(width, greaterThan(pane.width * 0.4));
  });

  testWidgets('the default view is untouched when switching parts', (tester) async {
    final c = SketchController();
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SketchCanvas(controller: c))));
    c.addPart();
    await tester.pump();
    final v = _view(tester);
    expect(v.zoom, 1);
    expect(v.pan, Offset.zero);
  });
}
