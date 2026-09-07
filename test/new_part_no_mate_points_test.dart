import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/plane.dart';
import 'package:ai_sketcher/ui/sketch_canvas.dart';

// Regression: creating a new part must NOT inherit the previous part's mate
// points (connectors). Only Duplicate copies them, deliberately. The 3D view
// draws the *active* part's own connectors, so a clean new part = no pins.

void main() {
  test('Add part: the new part has no mate points', () {
    final c = SketchController(); // parts[0]
    c.addConnector(1);
    c.addConnector(2);
    expect(c.parts[0].connectors, hasLength(2));

    c.addPart();
    expect(c.activeIndex, 1);
    expect(c.active.connectors, isEmpty); // no inheritance
    expect(identical(c.parts[0].connectors, c.parts[1].connectors), isFalse);
    expect(c.parts[0].connectors, hasLength(2)); // original untouched
  });

  test('Sketch on face (addPlaneSketch): the new part has no mate points', () {
    final c = SketchController();
    c.addConnector(0);
    c.addPlaneSketch(SketchPlane.xy, name: 'Face sketch');
    expect(c.active.name, 'Face sketch');
    expect(c.active.connectors, isEmpty);
    expect(c.parts[0].connectors, hasLength(1));
  });

  test('Duplicate DOES copy mate points (by design)', () {
    final c = SketchController();
    c.addConnector(3);
    c.duplicatePart(0);
    expect(c.active.name, endsWith('copy'));
    expect(c.active.connectors, hasLength(1)); // copied on purpose
    // ...but as an independent list, so removing one doesn't affect the original.
    expect(identical(c.parts[0].connectors, c.parts[1].connectors), isFalse);
    c.removeConnector(1, 0);
    expect(c.parts[1].connectors, isEmpty);
    expect(c.parts[0].connectors, hasLength(1));
  });
}
