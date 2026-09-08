import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/beautify.dart';
import 'package:ai_sketcher/ui/sketch_canvas.dart';

// Regression: recognition + merge thresholds are in MODEL units, so when zoomed
// in (or sketching on a small face), a normal on-screen stroke is only a few
// model units long and was dropped as noise / collapsed by the merge. Passing
// the zoom makes the thresholds screen-relative, so drawing works zoomed in.

void main() {
  test('a short stroke is noise at 1x but recognized when zoomed in', () {
    // 8 model units long — below the 12-unit noise floor at 1x, but at zoom 10
    // that's an 80px on-screen stroke and should be a real line.
    const stroke = [Offset(0, 0), Offset(4, 0), Offset(8, 0)];
    expect(recognizeStroke(stroke), isA<DecorationResult>());
    expect(recognizeStroke(stroke, scale: 10), isA<PolylineResult>());
  });

  test('addStroke persists a small shape drawn while zoomed in', () {
    final c = SketchController();
    // A ~10-unit square (100px on screen at zoom 10). At zoom 1 the 16-unit
    // merge tolerance collapses its 10-unit edges; at zoom 10 it must survive.
    const square = [
      Offset(0, 0), Offset(10, 0), Offset(10, 10), Offset(0, 10), Offset(0, 0)
    ];

    c.addStroke(List.of(square), zoom: 1);
    final atOne = c.model.segments.length;

    final c2 = SketchController();
    c2.addStroke(List.of(square), zoom: 10);
    expect(c2.model.segments.length, greaterThan(atOne),
        reason: 'zoomed-in drawing keeps the small edges (not over-merged)');
    expect(c2.model.segments.length, greaterThanOrEqualTo(3),
        reason: 'the square persisted as a real profile');
  });
}
