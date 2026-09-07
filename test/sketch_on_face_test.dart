import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/sketch/plane.dart';
import 'package:ai_sketcher/ui/sketch_canvas.dart';

// Regression: drawing on a "sketch on a face" (a Part with a referenceLoop and a
// non-base plane) must still capture strokes into the active part's sketch. The
// face sketch is anchored on its reference-outline centroid, so a stroke drawn
// at the pane centre lands on the face.

Widget _host(SketchController c) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
            width: 800, height: 600, child: SketchCanvas(controller: c)),
      ),
    );

Future<void> _dragLine(WidgetTester tester, Offset from, Offset to) async {
  final g = await tester.startGesture(from);
  for (var i = 1; i <= 6; i++) {
    await tester.pump(const Duration(milliseconds: 8));
    await g.moveTo(Offset.lerp(from, to, i / 6)!);
  }
  await g.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('drawing a line on a face sketch adds a segment', (tester) async {
    final c = SketchController();
    // Enter a "sketch on a face": a new part on a plane with the parent face's
    // outline as its reference (a square centred at model (500,400)).
    c.addPlaneSketch(
      SketchPlane.xy,
      name: 'Face sketch',
      reference: const [
        Offset(440, 340),
        Offset(560, 340),
        Offset(560, 460),
        Offset(440, 460),
      ],
    );
    expect(c.active.referenceLoop, isNotNull);
    expect(c.model.segments, isEmpty);

    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    // The reference centroid (500,400) sits at the pane centre (400,300); draw a
    // short straight stroke across the centre.
    await _dragLine(tester, const Offset(360, 300), const Offset(440, 300));

    expect(c.model.segments, isNotEmpty,
        reason: 'a stroke drawn on the face is captured into its sketch');
  });

  testWidgets('drawing still works on the base-plane sketch too', (tester) async {
    final c = SketchController(); // default base part, no reference
    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();
    await _dragLine(tester, const Offset(360, 300), const Offset(440, 300));
    expect(c.model.segments, isNotEmpty);
  });

  // Regression: "one part per tab" hid the parent body the moment a face sketch
  // became active, so a boss/pocket showed alone and the containing part
  // vanished. A face feature must render in context with its parent — both are
  // in the 3D view's visible set.
  test('a face feature is shown in context with its parent body', () {
    final c = SketchController();
    final base = c.active; // index 0 — the body we sketch on
    c.addPart(); // index 1 — an unrelated second body
    final other = c.parts[1];
    c.setActive(0);

    // Sketch on a face of the base body.
    c.addPlaneSketch(
      SketchPlane.xy,
      name: 'Face sketch',
      reference: const [Offset(0, 0), Offset(10, 0), Offset(10, 10), Offset(0, 10)],
      parent: base,
    );
    final feature = c.active; // index 2
    expect(feature.parent, same(base));
    expect(feature.root, same(base));
    expect(base.root, same(base));

    // With the feature active, its parent is visible too — but not the unrelated
    // body.
    final visible = c.visiblePartIndices().toSet();
    expect(visible.contains(c.parts.indexOf(base)), isTrue,
        reason: 'the containing part still shows');
    expect(visible.contains(c.parts.indexOf(feature)), isTrue);
    expect(visible.contains(c.parts.indexOf(other)), isFalse);

    // Selecting the base shows the same family.
    c.setActive(c.parts.indexOf(base));
    expect(c.visiblePartIndices().toSet(), visible);

    // An unrelated body on its own shows only itself.
    c.setActive(c.parts.indexOf(other));
    expect(c.visiblePartIndices(), [c.parts.indexOf(other)]);
  });
}
