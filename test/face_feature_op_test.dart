import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/decomposition.dart';
import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/sketch/part.dart';
import 'package:ai_sketcher/sketch/plane.dart';

// A face feature's direction is explicit: union extrudes +normal (out, adds
// material), difference extrudes -normal (in, cuts), and flipDirection negates
// either. The harness has no booleans yet, so this proves the *direction* — the
// signal the rendering colour-codes and the featuretree bridge maps to pad/pocket.

/// A unit square as a hand-built closed sketch (no solver/FFI).
ParametricSketch _square() {
  final s = ParametricSketch();
  s.points.addAll(const [Offset(0, 0), Offset(10, 0), Offset(10, 10), Offset(0, 10)]);
  for (var i = 0; i < 4; i++) {
    s.segments.add(Segment(i, (i + 1) % 4));
  }
  return s;
}

/// The signed Z-extent of a decomposition's first region solid on the XY plane.
({double lo, double hi}) _zExtent(Decomposition d) {
  final zs = d.parts.first.solid.vertices.map((v) => v.z);
  return (lo: zs.reduce((a, b) => a < b ? a : b), hi: zs.reduce((a, b) => a > b ? a : b));
}

void main() {
  test('union is the default and reads as additive (dirSign +1)', () {
    final p = Part('boss')..operation = FeatureOp.union;
    expect(p.dirSign, 1.0);
    expect(p.isSubtractive, isFalse);
  });

  test('difference flips the sign and reads as subtractive', () {
    final p = Part('slot')..operation = FeatureOp.difference;
    expect(p.dirSign, -1.0);
    expect(p.isSubtractive, isTrue);
  });

  test('flipDirection negates either operation', () {
    final u = Part('u')
      ..operation = FeatureOp.union
      ..flipDirection = true;
    final d = Part('d')
      ..operation = FeatureOp.difference
      ..flipDirection = true;
    expect(u.dirSign, -1.0); // union, flipped -> inward
    expect(u.isSubtractive, isTrue);
    expect(d.dirSign, 1.0); // difference, flipped -> outward
    expect(d.isSubtractive, isFalse);
  });

  test('union extrudes outward (+normal), difference inward (-normal)', () {
    final union = decompose(_square(), depth: 10, plane: SketchPlane.xy, dirSign: 1);
    final diff = decompose(_square(), depth: 10, plane: SketchPlane.xy, dirSign: -1);

    final u = _zExtent(union);
    expect(u.lo, closeTo(0, 1e-9));
    expect(u.hi, closeTo(10, 1e-9)); // grows to +Z

    final v = _zExtent(diff);
    expect(v.lo, closeTo(-10, 1e-9)); // grows to -Z (into the body)
    expect(v.hi, closeTo(0, 1e-9));
  });

  test('dirSign default of decompose leaves base extrudes unchanged', () {
    final base = decompose(_square(), depth: 10, plane: SketchPlane.xy);
    final e = _zExtent(base);
    expect(e.lo, closeTo(0, 1e-9));
    expect(e.hi, closeTo(10, 1e-9));
  });
}
