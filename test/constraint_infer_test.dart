import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/ui/sketch_canvas.dart';

// Drag-time constraint inference: as a vertex is dragged, near-axis / near-
// parallel / near-perpendicular edges snap and the constraint is applied on
// release (persisting until deleted). Constraint glyphs are tappable to delete.

void main() {
  test('snapDrag snaps a near-horizontal edge and offers an H constraint', () {
    final s = ParametricSketch();
    s.points.addAll(const [Offset(0, 0), Offset(160, 40)]);
    s.segments.add(Segment(0, 1));
    // Drag p1 to where the edge from p0=(0,0) is nearly horizontal.
    final r = s.snapDrag(1, const Offset(160, 2));
    expect(r.target.dy, 0.0, reason: 'y snaps to the other endpoint');
    expect(r.candidates.length, 1);
    expect(r.candidates.first.kind, ConstraintKind.horizontal);
  });

  test('snapDrag snaps a near-vertical edge to vertical', () {
    final s = ParametricSketch();
    s.points.addAll(const [Offset(0, 0), Offset(40, 160)]);
    s.segments.add(Segment(0, 1));
    final r = s.snapDrag(1, const Offset(2, 160));
    expect(r.target.dx, 0.0);
    expect(r.candidates.single.kind, ConstraintKind.vertical);
  });

  test('snapDrag infers parallel to a diagonal edge (no axis snap)', () {
    final s = ParametricSketch();
    s.points.addAll(const [
      Offset(0, 0), Offset(100, 100), // seg0: a 45° reference edge
      Offset(0, 60), Offset(80, 120), // seg1: drag p3
    ]);
    s.segments
      ..add(Segment(0, 1))
      ..add(Segment(2, 3));
    final r = s.snapDrag(3, const Offset(80, 138)); // ~44°, near seg0's 45°
    expect(r.candidates.any((c) => c.kind == ConstraintKind.parallel), isTrue);
    // Snapped edge runs at 45° from p2=(0,60): target.dx == target.dy - 60.
    expect(r.target.dx - (r.target.dy - 60), closeTo(0, 1e-6));
  });

  test('snapDrag does not repeat an existing constraint', () {
    final s = ParametricSketch();
    s.points.addAll(const [Offset(0, 0), Offset(160, 40)]);
    s.segments.add(Segment(0, 1));
    s.constraints.add(SketchConstraint(ConstraintKind.horizontal, [0]));
    final r = s.snapDrag(1, const Offset(160, 2));
    expect(r.target.dy, 0.0, reason: 'still snaps to honour the constraint');
    expect(r.candidates, isEmpty, reason: 'H is already present');
  });

  test('removeConstraint drops it and re-solves', () {
    final s = ParametricSketch();
    s.points.addAll(const [Offset(0, 0), Offset(160, 0)]);
    s.segments.add(Segment(0, 1));
    s.constraints.add(SketchConstraint(ConstraintKind.horizontal, [0]));
    s.removeConstraint(0);
    expect(s.constraints, isEmpty);
  });

  testWidgets('drag near-horizontal applies H; tapping its glyph deletes it',
      (tester) async {
    final c = SketchController();
    final m = c.model;
    m.points.addAll(const [Offset(200, 300), Offset(360, 340)]);
    m.segments.add(Segment(0, 1));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: SizedBox(
              width: 800, height: 600, child: SketchCanvas(controller: c))),
    ));
    await tester.pumpAndSettle();
    expect(m.constraints, isEmpty);

    // Grab p1 and drag it up so the edge from p0=(200,300) goes horizontal.
    final g = await tester.startGesture(const Offset(360, 340));
    for (final y in [330, 318, 305, 301]) {
      await tester.pump(const Duration(milliseconds: 8));
      await g.moveTo(Offset(360, y.toDouble()));
    }
    await g.up();
    await tester.pumpAndSettle();

    expect(m.constraints.any((k) => k.kind == ConstraintKind.horizontal), isTrue,
        reason: 'the snapped alignment persists as an H constraint');

    // Tap the H glyph (segMid + normal*16 = (280,300)+(0,16)) to select it.
    await tester.tapAt(const Offset(280, 316));
    await tester.pumpAndSettle();
    expect(find.text('Horizontal'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete (Del)'));
    await tester.pumpAndSettle();
    expect(m.constraints, isEmpty, reason: 'the constraint was deleted');
  });
}
