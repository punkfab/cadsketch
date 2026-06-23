import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/decomposition.dart';
import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/sketch/regions.dart';

// Phase 1 region-partition core: a master sketch's planar graph splits into one
// bounded region per enclosed area, and adjacent regions report their shared
// divider edge (the future mating surface). Built directly (no solve) so the
// test needs no kernel.

/// A 100x100 square split by a vertical divider at x=50 into a left and right
/// region. Points: 0..3 outer corners, 4/5 divider ends.
ParametricSketch _splitSquare() {
  final m = ParametricSketch();
  m.points.addAll(const [
    Offset(0, 0), // 0
    Offset(100, 0), // 1
    Offset(100, 100), // 2
    Offset(0, 100), // 3
    Offset(50, 0), // 4 divider bottom
    Offset(50, 100), // 5 divider top
  ]);
  m.segments.addAll([
    Segment(0, 4), Segment(4, 1), // bottom
    Segment(1, 2), // right
    Segment(2, 5), Segment(5, 3), // top
    Segment(3, 0), // left
    Segment(4, 5), // divider
  ]);
  return m;
}

ParametricSketch _plainSquare() {
  final m = ParametricSketch();
  m.points.addAll(const [
    Offset(0, 0),
    Offset(100, 0),
    Offset(100, 100),
    Offset(0, 100),
  ]);
  m.segments.addAll([Segment(0, 1), Segment(1, 2), Segment(2, 3), Segment(3, 0)]);
  return m;
}

void main() {
  group('findRegions', () {
    test('plain square is a single region with no adjacencies', () {
      final set = findRegions(_plainSquare());
      expect(set.regions.length, 1);
      expect(set.adjacencies, isEmpty);
      expect(set.isPartitioned, isFalse);
    });

    test('split square yields two regions sharing the divider edge', () {
      final set = findRegions(_splitSquare());
      expect(set.regions.length, 2);
      expect(set.isPartitioned, isTrue);
      expect(set.adjacencies.length, 1);
      final a = set.adjacencies.single;
      expect({a.pa, a.pb}, {4, 5}); // the divider endpoints
    });

    test('each region is a closed quad profile', () {
      final set = findRegions(_splitSquare());
      for (final r in set.regions) {
        expect(r.profile.length, 4);
        expect(r.loop.length, 4);
      }
    });
  });

  group('decompose', () {
    test('split square -> two extruded parts and one auto-mate', () {
      final d = decompose(_splitSquare(), depth: 50);
      expect(d.parts.length, 2);
      expect(d.mates.length, 1);
      final m = d.mates.single;
      // Mate faces are valid side-face indices on each part's solid.
      expect(m.faceA, inInclusiveRange(2, d.parts[m.partA].solid.faces.length - 1));
      expect(m.faceB, inInclusiveRange(2, d.parts[m.partB].solid.faces.length - 1));
    });

    test('explode offset grows with factor and is zero when assembled', () {
      final d = decompose(_splitSquare(), depth: 50);
      expect(d.explodeOffset(0, 0).length, 0);
      expect(d.explodeOffset(0, 1).length, greaterThan(0));
    });

    test('empty sketch decomposes to nothing', () {
      expect(decompose(ParametricSketch(), depth: 50).isEmpty, isTrue);
    });

    test('per-region depth override changes only that part height', () {
      final d = decompose(_splitSquare(), depth: 50, depthOverrides: {0: 120});
      double height(int p) {
        final zs = d.parts[p].solid.vertices.map((v) => v.z);
        return zs.reduce((a, b) => a > b ? a : b) -
            zs.reduce((a, b) => a < b ? a : b);
      }

      expect(height(0), closeTo(120, 1e-6));
      expect(height(1), closeTo(50, 1e-6));
    });
  });
}
