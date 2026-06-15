import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/beautify.dart';
import 'package:ai_sketcher/sketch/entities.dart';

// These cover the pure-Dart recognition paths that don't need the native
// kernel (short/noise strokes -> raw decoration).
void main() {
  test('short strokes are kept as a raw decoration', () {
    final r = recognizeStroke([const Offset(0, 0), const Offset(3, 1)]);
    expect(r, isA<DecorationResult>());
    expect((r as DecorationResult).entity, isA<RawStroke>());
  });

  test('single-point strokes are kept as a raw decoration', () {
    final r = recognizeStroke([const Offset(5, 5)]);
    expect(r, isA<DecorationResult>());
    expect((r as DecorationResult).entity, isA<RawStroke>());
  });
}
