import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/ui/sketch_canvas.dart';

// Pinch-to-zoom in the 2D sketch canvas (the on-device zoom the app lacked —
// scroll-wheel zoom is desktop-only). A two-finger spread should zoom the view,
// which surfaces the "reset view" button; tapping it returns to 1x and hides it.

Future<void> _pumpCanvas(WidgetTester tester, SketchController c) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: SketchCanvas(controller: c))));

void main() {
  testWidgets('two-finger pinch zooms the canvas; reset returns to 1x', (tester) async {
    final c = SketchController();
    addTearDown(c.dispose);
    await _pumpCanvas(tester, c);

    // Not zoomed yet → no reset button.
    expect(find.byType(FloatingActionButton), findsNothing);

    // Two fingers spreading apart = zoom in.
    final g1 = await tester.startGesture(const Offset(380, 300), pointer: 1);
    final g2 = await tester.startGesture(const Offset(420, 300), pointer: 2);
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await g1.moveBy(const Offset(-24, 0));
      await g2.moveBy(const Offset(24, 0));
      await tester.pump();
    }
    await g1.up();
    await g2.up();
    await tester.pump();

    // The view moved → the reset-view button is now shown.
    expect(find.byType(FloatingActionButton), findsOneWidget);

    // Resetting returns to the default view and hides the button.
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('right-button drag pans the view (desktop/web) without drawing',
      (tester) async {
    final c = SketchController();
    addTearDown(c.dispose);
    await _pumpCanvas(tester, c);

    expect(find.byType(FloatingActionButton), findsNothing);
    final before = c.active.sketch.points.length;

    // A secondary-button (right-click) drag pans, so the reset button appears...
    final g =
        await tester.startGesture(const Offset(300, 300), buttons: kSecondaryButton);
    for (var i = 0; i < 5; i++) {
      await g.moveBy(const Offset(20, 12));
      await tester.pump();
    }
    await g.up();
    await tester.pump();

    expect(find.byType(FloatingActionButton), findsOneWidget,
        reason: 'right-drag pans the view');
    // ...and it must NOT have drawn a stroke.
    expect(c.active.sketch.points.length, before,
        reason: 'a pan drag adds no geometry');
  });

  testWidgets('one finger still draws (does not trigger the pan/zoom path)', (tester) async {
    final c = SketchController();
    addTearDown(c.dispose);
    await _pumpCanvas(tester, c);

    // A single-finger drag is a stroke, not a view manipulation: no reset button.
    final g = await tester.startGesture(const Offset(200, 200), pointer: 1);
    await g.moveBy(const Offset(60, 40));
    await tester.pump();
    await g.up();
    await tester.pump();
    expect(find.byType(FloatingActionButton), findsNothing);
  });
}
