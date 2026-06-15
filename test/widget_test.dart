import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/beautify.dart';
import 'package:ai_sketcher/sketch/entities.dart';

// beautifyStroke's line branch needs the native kernel loadable, which isn't
// available under `flutter test`. These cover the pure-Dart classification
// paths only.
void main() {
  test('short strokes are kept raw, not beautified', () {
    final e = beautifyStroke([const Offset(0, 0), const Offset(3, 1)]);
    expect(e, isA<RawStroke>());
  });

  test('single-point strokes are kept raw', () {
    final e = beautifyStroke([const Offset(5, 5)]);
    expect(e, isA<RawStroke>());
  });
}
