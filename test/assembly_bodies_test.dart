import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/sketch/plane.dart';
import 'package:ai_sketcher/sketch/solid.dart';
import 'package:ai_sketcher/ui/assembly_view.dart';
import 'package:ai_sketcher/ui/sketch_canvas.dart';

// The assembly shows one body per BASE part. A face feature is merged into its
// parent (extruded on its own plane so it sits on the parent face), not shown as
// a separate parked body.

void _square(ParametricSketch s, double w) {
  final b = s.points.length;
  s.points.addAll([Offset(0, 0), Offset(w, 0), Offset(w, w), Offset(0, w)]);
  for (var i = 0; i < 4; i++) {
    s.segments.add(Segment(b + i, b + (i + 1) % 4));
  }
}

({Vec3 lo, Vec3 hi}) _bbox(List<Vec3> vs) {
  var lo = vs.first, hi = vs.first;
  for (final v in vs) {
    lo = Vec3(
        v.x < lo.x ? v.x : lo.x, v.y < lo.y ? v.y : lo.y, v.z < lo.z ? v.z : lo.z);
    hi = Vec3(
        v.x > hi.x ? v.x : hi.x, v.y > hi.y ? v.y : hi.y, v.z > hi.z ? v.z : hi.z);
  }
  return (lo: lo, hi: hi);
}

void main() {
  test('two independent base bodies -> two assembly bodies', () {
    final c = SketchController();
    _square(c.model, 40);
    c.addPart();
    _square(c.model, 30);
    final bodies = assemblyBodies(c.parts, c.mates);
    expect(bodies.length, 2);
  });

  test('a base + a face feature -> ONE assembly body, feature merged in', () {
    final c = SketchController();
    _square(c.model, 40); // base, part 0, depth 100 -> box 40x40x100
    final base = c.parts[0];
    final baseBox = assemblyBodies(c.parts, c.mates).single;
    final baseSpan = _bbox(baseBox.verts);

    // A boss on the base's top face (z = depth). Its plane sits on that face.
    final baseSolid = base.buildSolid()!;
    final topFace = 1; // extrudeProfile: face 1 = top cap
    final plane = SketchPlane.fromFace(baseSolid, topFace);
    final reference = [
      for (final vi in baseSolid.faces[topFace])
        plane.to2d(baseSolid.vertices[vi])
    ];
    c.addPlaneSketch(plane, name: 'Boss', reference: reference, parent: base);
    _square(c.model, 10); // the boss profile
    c.active.depth = 20;

    final bodies = assemblyBodies(c.parts, c.mates);
    expect(bodies.length, 1, reason: 'the feature is merged, not a 2nd body');

    // The merged body now extends beyond the bare base box in +Z (the boss sits
    // on the top face and sticks out), i.e. the feature is attached, not parked
    // far away on some other axis.
    final merged = _bbox(bodies.single.verts);
    expect(merged.hi.z, greaterThan(baseSpan.hi.z + 1),
        reason: 'the boss adds height on the top face');
    // And it did not get parked far off in X like a separate part would.
    expect(merged.hi.x, lessThan(baseSpan.hi.x + 1));
  });
}
