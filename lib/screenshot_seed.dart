import 'dart:ui' show Offset;

import 'sketch/entities.dart';
import 'sketch/model.dart';
import 'sketch/part.dart';
import 'sketch/plane.dart';
import 'ui/sketch_canvas.dart';

/// Curated App Store / marketing states, built as real [Part]s (no solver, no
/// FFI) and injected into a [SketchController]. Each returns a fresh controller
/// so the app renders that scene through its actual widgets. The 3D scene
/// auto-frames via its camera, so every scene composes cleanly at any size.

/// A closed rectangle sketch (points + a segment ring), the building block for
/// every scene.
void _rect(ParametricSketch s, double w, double h, {Offset at = Offset.zero}) {
  final base = s.points.length;
  s.points.addAll([
    at,
    at + Offset(w, 0),
    at + Offset(w, h),
    at + Offset(0, h),
  ]);
  for (var i = 0; i < 4; i++) {
    s.segments.add(Segment(base + i, base + (i + 1) % 4));
  }
}

Part _plate() {
  final p = Part('Plate')..depth = 40;
  _rect(p.sketch, 90, 60);
  // A drilled hole reads as a real feature in the 2D sketch.
  p.decorations.add(CircleEntity(const Offset(45, 30), 11));
  return p;
}

Part _block() {
  final p = Part('Block')..depth = 34;
  _rect(p.sketch, 80, 54);
  return p;
}

/// A sketch-on-face feature on the top cap of [base], adding (union) or cutting
/// (difference) material — this exercises the face-feature model end to end.
Part _faceFeature(Part base, FeatureOp op) {
  final solid = base.buildSolid()!;
  const topFace = 1; // extrude layout: face 0 = bottom cap, face 1 = top cap
  final plane = SketchPlane.fromFace(solid, topFace);
  final p = Part(op == FeatureOp.union ? 'Boss' : 'Pocket')
    ..plane = plane
    ..operation = op
    ..depth = 16;
  // A small square centred on the face (plane origin = face centroid).
  _rect(p.sketch, 26, 26, at: const Offset(-13, -13));
  p.referenceLoop = [
    for (final vi in solid.faces[topFace]) plane.to2d(solid.vertices[vi])
  ];
  return p;
}

SketchController _seed(List<Part> parts, {int active = 0}) {
  final c = SketchController();
  c.parts
    ..clear()
    ..addAll(parts);
  c.activeIndex = active;
  return c;
}

/// Scene 1: a flat sketch and the solid it extrudes into — the core promise.
SketchController sketchToSolid() => _seed([_plate()]);

/// Scene 2: sketch on a face to ADD material (green boss). Active = the feature,
/// so the Union/Cut control row is visible.
SketchController faceUnion() =>
    _seed([_block(), _faceFeature(_block(), FeatureOp.union)], active: 1);

/// Scene 3: sketch on a face to CUT material (red pocket).
SketchController faceCut() =>
    _seed([_block(), _faceFeature(_block(), FeatureOp.difference)], active: 1);

/// The ordered scenes the screenshot harness captures. Keys become file names.
final Map<String, SketchController Function()> screenshotScenes = {
  '01-sketch-to-solid': sketchToSolid,
  '02-sketch-on-face-union': faceUnion,
  '03-sketch-on-face-cut': faceCut,
};
