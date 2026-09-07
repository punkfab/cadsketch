import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/ui/sketch_canvas.dart';

// Deleting a vertex should remove the point and every segment incident to it,
// leaving the rest of the sketch consistent (no dangling segment endpoints, no
// orphan points).

ParametricSketch _triangle() {
  final s = ParametricSketch();
  s.points.addAll(const [Offset(0, 0), Offset(100, 0), Offset(50, 80)]);
  s.segments
    ..add(Segment(0, 1))
    ..add(Segment(1, 2))
    ..add(Segment(2, 0));
  return s;
}

void _assertConsistent(ParametricSketch s) {
  for (final seg in s.segments) {
    expect(seg.a, inInclusiveRange(0, s.points.length - 1), reason: 'seg.a in range');
    expect(seg.b, inInclusiveRange(0, s.points.length - 1), reason: 'seg.b in range');
  }
  // No orphan points (every point referenced by some segment) unless there are
  // no segments at all.
  if (s.segments.isNotEmpty) {
    final used = <int>{for (final seg in s.segments) ...[seg.a, seg.b]};
    expect(used.length, s.points.length, reason: 'no orphan points');
  }
}

void main() {
  test('removePoint drops the vertex and its incident segments', () {
    final s = _triangle();
    s.removePoint(1);
    expect(s.points.length, 2); // P0, P2 remain
    expect(s.segments.length, 1); // only the P2->P0 edge survives
    _assertConsistent(s);
  });

  test('removePoint on an isolated point just prunes it', () {
    final s = ParametricSketch();
    s.points.addAll(const [Offset(0, 0), Offset(10, 0), Offset(20, 0)]);
    s.segments.add(Segment(0, 1)); // point 2 is isolated
    s.removePoint(2);
    expect(s.points.length, 2);
    expect(s.segments.length, 1);
    _assertConsistent(s);
  });

  test('removePoint out of range is a no-op', () {
    final s = _triangle();
    s.removePoint(9);
    expect(s.points.length, 3);
    expect(s.segments.length, 3);
  });

  test('controller.deletePoint removes the vertex from the active part', () {
    final c = SketchController();
    final m = c.model;
    m.points.addAll(const [Offset(0, 0), Offset(100, 0), Offset(50, 80)]);
    m.segments
      ..add(Segment(0, 1))
      ..add(Segment(1, 2))
      ..add(Segment(2, 0));
    c.deletePoint(0);
    expect(c.model.points.length, 2);
    _assertConsistent(c.model);
  });

  // The real UI path: press a vertex to select it, then tap the selection bar's
  // Delete button. Exercises _onDown/_onUp/_selectionBar/_deleteSelection.
  testWidgets('tap a vertex then Delete removes it in the canvas', (tester) async {
    final c = SketchController();
    final m = c.model;
    // Points near the pane center so they're inside the viewport at zoom 1
    // (screen == model when there's no face reference and no pan).
    m.points.addAll(const [Offset(200, 200), Offset(320, 200), Offset(260, 300)]);
    m.segments
      ..add(Segment(0, 1))
      ..add(Segment(1, 2))
      ..add(Segment(2, 0));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
            width: 800, height: 600, child: SketchCanvas(controller: c)),
      ),
    ));
    await tester.pumpAndSettle();
    expect(m.points.length, 3);

    // Select vertex 0 by pressing it.
    await tester.tapAt(const Offset(200, 200));
    await tester.pumpAndSettle();

    // The selection bar's Delete button should now be present, and it must be a
    // POINT selection (not a segment picked by falling through to _handleTap).
    expect(find.text('Point'), findsOneWidget,
        reason: 'pressing a vertex selects the point, not a segment');
    final del = find.byTooltip('Delete (Del)');
    expect(del, findsOneWidget, reason: 'a selected point shows a Delete button');
    await tester.tap(del);
    await tester.pumpAndSettle();

    expect(c.model.points.length, lessThan(3),
        reason: 'deleting the selected vertex removes it');
  });
}
