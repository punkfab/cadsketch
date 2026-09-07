import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/ui/sketch_canvas.dart';

// Regression: clicking a dimension number opens its editor. The labels are drawn
// at a constant on-screen size, so the hit-test runs in screen space — this
// verifies a tap on the number (not the line) reaches the editor.

void main() {
  testWidgets('tapping a dimension number opens the editor', (tester) async {
    final c = SketchController();
    final s = c.active.sketch;
    // A horizontal segment with a driving dimension, centred in the pane.
    s.points.addAll(const [Offset(300, 300), Offset(500, 300)]);
    s.segments.add(Segment(0, 1)..drivingLength = 200);

    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SketchCanvas(controller: c))));
    await tester.pump();

    // In an 800x600 test surface with no reference loop, the view centres so
    // pan == 0 and zoom == 1, i.e. model coords == screen coords — so the
    // dimension anchor is exactly where the label is drawn.
    final anchor = c.model.dimAnchor(0);
    await tester.tapAt(anchor);
    await tester.pumpAndSettle();

    // The dimension editor dialog is now shown (it has a text field).
    expect(find.byType(TextField), findsWidgets);
  });
}
