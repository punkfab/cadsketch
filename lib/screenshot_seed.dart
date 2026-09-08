import 'package:flutter/material.dart';

import 'main.dart' show SketchHome;
import 'sketch/assembly.dart';
import 'sketch/entities.dart';
import 'sketch/model.dart';
import 'sketch/part.dart';
import 'sketch/plane.dart';
import 'ui/assembly_view.dart';
import 'ui/sketch_canvas.dart';

/// Curated App Store / marketing states, built as real [Part]s (no solver, no
/// FFI) and rendered through the app's actual widgets. Each scene builds the
/// whole `home:` widget so we can show the part view (SketchHome, with the parts
/// tree, 2D sketch and 3D pane) or the Assembly view, in wireframe or shaded.

/// One marketing scene: the widget to render, and whether to switch the 3D view
/// to shaded (the harness taps the shaded toggle before capturing).
class ShotScene {
  ShotScene(this.build, {this.shaded = false});
  final Widget Function() build;
  final bool shaded;
}

/// A closed rectangle sketch (points + a segment ring), the building block.
void _rect(ParametricSketch s, double w, double h, {Offset at = Offset.zero}) {
  final base = s.points.length;
  s.points.addAll([at, at + Offset(w, 0), at + Offset(w, h), at + Offset(0, h)]);
  for (var i = 0; i < 4; i++) {
    s.segments.add(Segment(base + i, base + (i + 1) % 4));
  }
}

/// A plate with a drilled hole — extrudes to a holed solid (great shaded).
Part _plate() {
  final p = Part('Plate')..depth = 130;
  _rect(p.sketch, 320, 220);
  p.decorations.add(CircleEntity(const Offset(210, 110), 46));
  return p;
}

Part _block([String name = 'Block']) {
  final p = Part(name)..depth = 150;
  _rect(p.sketch, 220, 150);
  return p;
}

/// A dimensioned + constrained plate: H/V glyphs and two driving dimensions show
/// (the painter reads constraints + drivingLength directly, no solve needed).
Part _dimensionedPlate() {
  final p = Part('Plate')..depth = 120;
  _rect(p.sketch, 340, 220);
  p.sketch.constraints
    ..add(SketchConstraint(ConstraintKind.horizontal, [0]))
    ..add(SketchConstraint(ConstraintKind.vertical, [1]))
    ..add(SketchConstraint(ConstraintKind.horizontal, [2]))
    ..add(SketchConstraint(ConstraintKind.vertical, [3]));
  p.sketch.segments[0].drivingLength = 340; // width
  p.sketch.segments[1].drivingLength = 220; // height
  p.decorations.add(CircleEntity(const Offset(250, 110), 40));
  return p;
}

/// A sketch-on-face feature on the top cap of [base] (union boss / diff pocket),
/// with its parent link set so the 3D view shows it in context on the body.
Part _faceFeature(Part base, FeatureOp op) {
  final solid = base.buildSolid()!;
  const topFace = 1; // extrude layout: 0 = bottom cap, 1 = top cap
  final plane = SketchPlane.fromFace(solid, topFace);
  final p = Part(op == FeatureOp.union ? 'Boss' : 'Pocket')
    ..plane = plane
    ..operation = op
    ..depth = 60
    ..parent = base
    ..referenceLoop = [
      for (final vi in solid.faces[topFace]) plane.to2d(solid.vertices[vi])
    ];
  _rect(p.sketch, 90, 90, at: const Offset(-45, -45)); // centred on the face
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

/// Two blocks fastened face-to-face — the assembly story.
SketchController _assembly() {
  final a = _block('Base')..depth = 90;
  final b = _block('Cap')
    ..depth = 60
    ..sketch.clear();
  _rect(b.sketch, 150, 150);
  final sa = a.buildSolid()!, sb = b.buildSolid()!;
  a.connectors.add(MateConnector(3, anchor: sa.faceCentroid(3))); // right face
  b.connectors.add(MateConnector(5, anchor: sb.faceCentroid(5))); // left face
  final c = SketchController();
  c.parts
    ..clear()
    ..addAll([a, b]);
  c.mates.add(Mate(0, 0, 1, 0));
  return c;
}

/// The ordered scenes the harness captures. Keys become file names.
final Map<String, ShotScene> screenshotScenes = {
  // Shaded solid + parts tree + live 2D sketch: the core promise.
  '01-part': ShotScene(
      () => SketchHome(controller: _seed([_plate()])),
      shaded: true),
  // A green boss sketched on a face, shown in context on its body.
  '02-boss': ShotScene(() {
    final base = _block();
    return SketchHome(
        controller: _seed([base, _faceFeature(base, FeatureOp.union)], active: 1));
  }, shaded: true),
  // Parametric 2D: constraints (H/V) and driving dimensions.
  '03-sketch': ShotScene(
      () => SketchHome(controller: _seed([_dimensionedPlate()]))),
  // Multi-part assembly, fastened flush.
  '04-assembly': ShotScene(
      () => AssemblyView(controller: _assembly()), shaded: true),
};
