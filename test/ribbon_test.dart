import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/ribbon.dart';
import 'package:ai_sketcher/sketch/plane.dart';
import 'package:ai_sketcher/sketch/stroke_font.dart';

// Embossing turns a single-stroke mark into an extrudable closed contour: the
// stroke becomes a ribbon of the given width, which the existing extrude
// pipeline raises into 3D. These pin that bridge.

double _signedArea(List<Offset> poly) {
  var a = 0.0;
  for (var i = 0; i < poly.length; i++) {
    final p = poly[i], q = poly[(i + 1) % poly.length];
    a += p.dx * q.dy - q.dx * p.dy;
  }
  return a / 2;
}

void main() {
  test('a straight stroke ribbonizes to a rectangle of the right area', () {
    final ribbon = strokeRibbon(const [Offset(0, 0), Offset(10, 0)], 2);
    expect(ribbon.length, 4); // 2 points each side
    // 10 long x 2 wide = area 20 (sign depends on winding).
    expect(_signedArea(ribbon).abs(), closeTo(20, 1e-6));
  });

  test('degenerate strokes produce no ribbon', () {
    expect(strokeRibbon(const [Offset(3, 3)], 2), isEmpty);
    expect(strokeRibbon(const [Offset(3, 3), Offset(3, 3)], 2), isEmpty);
  });

  test('text strokes ribbonize into extrudable prisms on a plane', () {
    final strokes = textToStrokes('I', size: 30); // a few clean strokes
    expect(strokes, isNotEmpty);
    var prisms = 0;
    for (final s in strokes) {
      final ribbon = strokeRibbon(s, 2.2);
      if (ribbon.length >= 3) {
        final solid = extrudeOnPlane(ribbon, SketchPlane.xy, 8);
        // A prism: bottom + top cap + one side per ribbon edge.
        expect(solid.faces.length, ribbon.length + 2);
        expect(solid.vertices.length, ribbon.length * 2);
        prisms++;
      }
    }
    expect(prisms, greaterThan(0));
  });
}
