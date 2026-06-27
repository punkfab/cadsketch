import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/stroke_font.dart';

// Text is a contour source that emits the same polyline primitive a hand stroke
// does. These lock the contract addText relies on: real polylines, centered on
// the origin, scaled to the requested cap height.

void main() {
  test('emits polylines for letters and digits; space emits nothing', () {
    expect(textToStrokes('A'), isNotEmpty);
    expect(textToStrokes('3'), isNotEmpty);
    expect(textToStrokes('   '), isEmpty);
    // Every stroke is a real polyline (>= 2 points).
    for (final s in textToStrokes('M3')) {
      expect(s.length, greaterThanOrEqualTo(2));
    }
  });

  test('is centered on the origin so it can drop on a datum point', () {
    final strokes = textToStrokes('HELLO', size: 30);
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final s in strokes) {
      for (final p in s) {
        if (p.dx < minX) minX = p.dx;
        if (p.dx > maxX) maxX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dy > maxY) maxY = p.dy;
      }
    }
    expect((minX + maxX) / 2, closeTo(0, 1e-9));
    expect((minY + maxY) / 2, closeTo(0, 1e-9));
  });

  test('cap height scales with size', () {
    double height(String t, double size) {
      var minY = double.infinity, maxY = -double.infinity;
      for (final s in textToStrokes(t, size: size)) {
        for (final p in s) {
          if (p.dy < minY) minY = p.dy;
          if (p.dy > maxY) maxY = p.dy;
        }
      }
      return maxY - minY;
    }

    expect(height('I', 60), closeTo(2 * height('I', 30), 1e-6));
  });

  test('lowercase folds to uppercase (same glyphs)', () {
    expect(textToStrokes('abc').length, textToStrokes('ABC').length);
  });
}
