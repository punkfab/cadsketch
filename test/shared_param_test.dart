import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/ui/sketch_canvas.dart';

const _rect200x100 = [
  Offset(0, 0),
  Offset(200, 0),
  Offset(200, 100),
  Offset(0, 100),
  Offset(0, 0),
];

void main() {
  test('a shared parameter drives bound dimensions across parts', () {
    final c = SketchController();
    c.model.addPolyline(_rect200x100);
    c.bindDimension(0, 'W'); // part 1 top edge -> W

    c.addPart();
    c.model.addPolyline(const [
      Offset(0, 0),
      Offset(150, 0),
      Offset(150, 80),
      Offset(0, 80),
      Offset(0, 0),
    ]);
    c.bindDimension(0, 'W'); // part 2 top edge -> same W

    c.setParameter('W', 250);
    expect(c.parts[0].sketch.measuredLength(0), closeTo(250, 0.5));
    expect(c.parts[1].sketch.measuredLength(0), closeTo(250, 0.5));
  });

  test('a literal length edit unbinds the parameter', () {
    final c = SketchController();
    c.model.addPolyline(_rect200x100);
    c.bindDimension(0, 'W');
    expect(c.model.segments[0].lengthParam, 'W');
    c.setDrivingLength(0, 123);
    expect(c.model.segments[0].lengthParam, isNull);
  });
}
