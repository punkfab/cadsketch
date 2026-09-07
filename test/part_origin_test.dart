import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/entities.dart';
import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/sketch/part.dart';

// The part origin datum is the bounding-box centre of the sketch geometry
// (points + circles), so mating/assembly have a stable, obvious reference frame.

void main() {
  test('origin is the bbox centre of the sketch points', () {
    final p = Part('r');
    p.sketch.points.addAll(const [
      Offset(10, 20),
      Offset(50, 20),
      Offset(50, 60),
      Offset(10, 60),
    ]);
    expect(p.originLocal(), const Offset(30, 40)); // (10..50, 20..60) centre
  });

  test('circles extend the bbox by their radius', () {
    final p = Part('c');
    p.decorations.add(CircleEntity(const Offset(100, 100), 10)); // 90..110
    expect(p.originLocal(), const Offset(100, 100));
    p.sketch.points.add(const Offset(0, 0)); // now bbox 0..110
    expect(p.originLocal(), const Offset(55, 55));
  });

  test('no geometry yet -> no origin', () {
    expect(Part('empty').originLocal(), isNull);
  });
}
