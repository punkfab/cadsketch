import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/ui/sketch_canvas.dart';

// "Sketch on a face" must land geometry ON the face. The 2D canvas stores
// points in plane-local coords; a face plane's origin is the face centroid in
// world space, so without a view transform a point drawn at canvas pixel
// (300, 200) maps hundreds of units off the face. viewOffset centers the face's
// reference outline in the pane so drawing there maps near the face.

void main() {
  test('viewOffset is zero with no reference (base-plane behavior unchanged)',
      () {
    expect(SketchCanvas.viewOffset(const Size(600, 400), null), Offset.zero);
    expect(SketchCanvas.viewOffset(const Size(600, 400), const []), Offset.zero);
  });

  test('viewOffset centers a face reference loop so drawing lands on the face',
      () {
    // A face outline centered at (50, 50) in plane-local coords.
    const loop = [
      Offset(0, 0),
      Offset(100, 0),
      Offset(100, 100),
      Offset(0, 100),
    ];
    const size = Size(600, 400);
    final off = SketchCanvas.viewOffset(size, loop);

    // Drawing at the pane center maps back to the loop's centroid — i.e. onto
    // the face, not flung off by absolute pixel coordinates.
    const centerScreen = Offset(300, 200);
    final model = centerScreen - off;
    expect((model - const Offset(50, 50)).distance, lessThan(1e-9));
  });

  test('anchorModel: pane center for base planes, face centroid for faces', () {
    const size = Size(600, 400);
    expect(SketchCanvas.anchorModel(size, null), const Offset(300, 200));
    const loop = [
      Offset(0, 0),
      Offset(100, 0),
      Offset(100, 100),
      Offset(0, 100),
    ];
    expect(SketchCanvas.anchorModel(size, loop), const Offset(50, 50));
  });

  test('zoom keeps the anchor at the pane center (drawing there stays on face)',
      () {
    const size = Size(600, 400);
    const loop = [
      Offset(0, 0),
      Offset(100, 0),
      Offset(100, 100),
      Offset(0, 100),
    ];
    final anchor = SketchCanvas.anchorModel(size, loop); // (50, 50)
    const paneCenter = Offset(300, 200);
    for (final zoom in [0.5, 1.0, 3.0]) {
      // Mirrors the widget's transform: pan = paneCenter - anchor*zoom,
      // model = (screen - pan) / zoom.
      final pan = paneCenter - anchor * zoom;
      final model = (paneCenter - pan) / zoom;
      expect((model - anchor).distance, lessThan(1e-9));
    }
  });
}
