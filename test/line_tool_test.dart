import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/ui/sketch_canvas.dart';

// The Line tool places a chain of connected segments by tapping. Tapping on (or
// near) an existing vertex snaps to it, so you can continue a line from an
// existing point — the segment welds onto that vertex instead of duplicating it.

Widget _host(SketchController c) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
            width: 800, height: 600, child: SketchCanvas(controller: c)),
      ),
    );

void main() {
  test('addSegmentBetween welds onto an existing endpoint (continuation)', () {
    final c = SketchController();
    c.model.addLine(const Offset(0, 0), const Offset(100, 0)); // seg 0
    expect(c.model.points.length, 2);
    // Continue from the existing endpoint (100, 0).
    c.addSegmentBetween(const Offset(100, 0), const Offset(100, 50));
    expect(c.model.points.length, 3, reason: 'only one new point is added');
    expect(c.model.segments.length, 2);
    // The shared corner has degree 2 (both segments meet there).
    final shared = c.model.points
        .indexWhere((p) => (p - const Offset(100, 0)).distance < 1e-6);
    expect(c.model.degree(shared), 2);
  });

  testWidgets('Line tool continues a chain from an existing vertex',
      (tester) async {
    final c = SketchController();
    final m = c.model;
    // One existing segment; screen == model at zoom 1 with no face reference.
    m.points.addAll(const [Offset(200, 200), Offset(300, 200)]);
    m.segments.add(Segment(0, 1));

    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    // Turn the Line tool on.
    await tester.tap(find.byTooltip('Line tool: tap to place a connected chain'));
    await tester.pumpAndSettle();

    // Tap the existing endpoint (200,200) to start the chain there...
    await tester.tapAt(const Offset(200, 200));
    await tester.pumpAndSettle();
    // ...then tap a new location to drop the next connected vertex.
    await tester.tapAt(const Offset(200, 320));
    await tester.pumpAndSettle();

    expect(m.segments.length, 2, reason: 'a new segment was added to the chain');
    expect(m.points.length, 3, reason: 'the chain welded onto the existing vertex');
  });
}
