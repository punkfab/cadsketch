import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/ui/sketch_canvas.dart';

// Undo/redo: per-part sketch history. Discrete edits record the pre-edit state;
// a drag coalesces (beginSketchEdit ... endSketchEdit) into one step.

SketchController _square() {
  final c = SketchController();
  final m = c.model;
  m.points.addAll(
      const [Offset(0, 0), Offset(40, 0), Offset(40, 30), Offset(0, 30)]);
  for (var i = 0; i < 4; i++) {
    m.segments.add(Segment(i, (i + 1) % 4));
  }
  return c;
}

void main() {
  test('undo then redo a delete', () {
    final c = _square();
    expect(c.canUndo, isFalse);

    c.deleteSegment(0);
    final afterDelete = c.model.segments.length;
    expect(afterDelete, lessThan(4));
    expect(c.canUndo, isTrue);

    c.undo();
    expect(c.model.segments.length, 4, reason: 'the segment is back');
    expect(c.canUndo, isFalse);
    expect(c.canRedo, isTrue);

    c.redo();
    expect(c.model.segments.length, afterDelete);
  });

  test('a drag coalesces into a single undo step', () {
    final c = _square();
    c.beginSketchEdit();
    c.movePoint(2, const Offset(80, 60));
    c.movePoint(2, const Offset(90, 70)); // many moves, one gesture
    c.endSketchEdit();

    expect(c.model.points[2].dx, closeTo(90, 1e-6));
    c.undo();
    expect(c.model.points[2].dx, closeTo(40, 1e-6),
        reason: 'the whole drag reverts in one step');
    expect(c.model.points[2].dy, closeTo(30, 1e-6));
    expect(c.canUndo, isFalse, reason: 'the drag was a single step');
  });

  test('cancelSketchEdit drops a no-op gesture (tap without drag)', () {
    final c = _square();
    c.beginSketchEdit();
    c.cancelSketchEdit();
    expect(c.canUndo, isFalse);
  });

  test('undo history is per-part', () {
    final c = _square();
    c.deleteSegment(0); // records on part 0
    c.addPart(); // part 1 becomes active, with its own empty history
    expect(c.canUndo, isFalse, reason: 'the new part has no history');
    c.setActive(0);
    expect(c.canUndo, isTrue, reason: "part 0's history is intact");
  });

  test('deleting a whole point is undoable', () {
    final c = _square();
    c.deletePoint(0);
    expect(c.model.points.length, lessThan(4));
    c.undo();
    expect(c.model.points.length, 4);
  });
}
