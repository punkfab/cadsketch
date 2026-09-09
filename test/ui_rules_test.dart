import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/beautify.dart';
import 'package:ai_sketcher/sketch/entities.dart';
import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/sketch/part.dart';
import 'package:ai_sketcher/sketch/plane.dart';

// ─────────────────────────────────────────────────────────────────────────────
// UI RULES — the regression registry.
//
// Each test states one user-facing rule the sketcher must keep obeying, named
// after the bug that broke it. They're deliberately compact and independent
// (model/part level, no widgets) so the whole registry runs in well under a
// second and reads as a spec. When a rule here fails, the behaviour a user
// reported broken has regressed. Deeper per-feature cases live in their own
// files (circle_on_side_face_test, boss_overhang_test, face_feature_plane_test,
// build_solid_holes_test, zoom_stroke_test, sketch_zoom_test, undo_test,
// assembly_mate_regression_test, …); this file is the one-glance index.
// ─────────────────────────────────────────────────────────────────────────────

List<Offset> circleStroke(Offset c, double r, {int n = 48}) => [
      for (var i = 0; i <= n; i++)
        c + Offset(r * math.cos(2 * math.pi * i / n), r * math.sin(2 * math.pi * i / n)),
    ];

const square = [Offset(0, 0), Offset(100, 0), Offset(100, 100), Offset(0, 100), Offset(0, 0)];

Part cylinderPart() => Part('Cyl')
  ..depth = 200
  ..decorations.add(CircleEntity(const Offset(0, 0), 50));

Offset centroid2d(List<Offset> pts) {
  var sx = 0.0, sy = 0.0;
  for (final p in pts) {
    sx += p.dx;
    sy += p.dy;
  }
  return Offset(sx / pts.length, sy / pts.length);
}

void main() {
  group('RULES · editing', () {
    test('RULE: dragging a vertex moves ONLY that vertex (the shape never collapses)', () {
      // Bug: "moving points collapses the shape instead of just moving the point."
      // Recognition auto-constrains a square (H/V/=); dragging a corner against
      // those made a constraint unsatisfiable and the solver distorted the rest.
      final m = ParametricSketch()..addPolyline(square);
      final before = List<Offset>.of(m.points);
      m.releaseIncidentConstraints(1); // what the canvas does when a grab becomes a drag
      m.dragPoint(1, const Offset(100, 60));
      expect((m.points[1] - const Offset(100, 60)).distance, lessThan(1e-6),
          reason: 'the dragged vertex lands where it was dragged');
      for (var i = 0; i < m.points.length; i++) {
        if (i == 1) continue;
        expect((m.points[i] - before[i]).distance, lessThan(1e-3),
            reason: 'vertex $i did not move');
      }
      for (final s in m.segments) {
        expect((m.points[s.b] - m.points[s.a]).distance, greaterThan(20),
            reason: 'no edge collapsed');
      }
    });

    test('RULE: H and V are never stacked on one edge (that = a zero-length edge)', () {
      final m = ParametricSketch()..addPolyline(const [Offset(0, 0), Offset(100, 0)]);
      expect(m.hasConstraint(ConstraintKind.horizontal, [0]), isTrue);
      // Dragging the end almost straight up must NOT also offer Vertical.
      final snap = m.snapDrag(1, const Offset(2, 150));
      expect(snap.candidates.any((c) => c.kind == ConstraintKind.vertical), isFalse);
    });

    test('RULE: a dimension label sits a fixed SCREEN distance from its line at any zoom', () {
      // Bug: "the dimensions are way far away from the lines they dimension"
      // (a 16 model-unit offset became 800px when zoomed in 50x).
      final m = ParametricSketch()..addPolyline(const [Offset(0, 0), Offset(100, 0)]);
      final mid = m.segMid(0);
      for (final zoom in [0.5, 1.0, 10.0, 50.0]) {
        final onScreen = (m.dimAnchor(0, zoom: zoom) - mid).distance * zoom;
        expect(onScreen, closeTo(16, 1e-6), reason: 'zoom $zoom');
      }
    });

    test('RULE: a tap-sized stroke is noise at 1x but a real stroke when zoomed in', () {
      // Bug: drawing while zoomed in "did nothing" — thresholds were model units.
      const tiny = [Offset(0, 0), Offset(4, 0)];
      expect(recognizeStroke(tiny, scale: 1), isA<DecorationResult>());
      expect(recognizeStroke(tiny, scale: 8), isA<PolylineResult>());
    });
  });

  group('RULES · recognition', () {
    test('RULE: a small circle is still a circle (thin cylinder side face)', () {
      // Bug: "I can draw a circle on the cap but not on the rectangular side".
      final res = recognizeStroke(circleStroke(const Offset(0, 0), 6), scale: 1);
      expect((res as DecorationResult).entity, isA<CircleEntity>());
    });

    test('RULE: polygons stay polygons (no false circles from the small-circle fix)', () {
      for (final sides in [3, 4, 5, 6]) {
        final poly = [
          for (var i = 0; i <= sides; i++)
            Offset(12 * math.cos(2 * math.pi * i / sides), 12 * math.sin(2 * math.pi * i / sides))
        ];
        expect(recognizeStroke(poly, scale: 1), isA<PolylineResult>(), reason: '$sides-gon');
      }
    });
  });

  group('RULES · sketch on face', () {
    test('RULE: a feature sketched on a face extrudes ON that face, not on XY', () {
      // Bug: a circle on a cylinder side "ended up off to the side".
      final base = cylinderPart();
      final body = base.buildSolid()!;
      final plane = SketchPlane.fromFace(body, 2);
      final ref = [for (final vi in body.faces[2]) plane.to2d(body.vertices[vi])];
      final feat = Part('Boss')
        ..plane = plane
        ..depth = 5
        ..referenceLoop = ref
        ..parent = base
        ..decorations.add(CircleEntity(centroid2d(ref), 3));
      final fc = body.faceCentroid(2);
      for (final v in feat.solidOnPlane()!.vertices) {
        expect((v - fc).length, lessThan(30), reason: 'boss is on the face');
      }
      expect(feat.buildSolid()!.centroid.length, lessThan(fc.length / 2),
          reason: 'buildSolid (XY) is NOT what the 3D view must use for a face feature');
    });

    test('RULE: a boss overhanging its face lofts down to the body (no gap)', () {
      // Bug: "if the sketch goes off the edge of the face we don't close the gap".
      final base = cylinderPart();
      final body = base.buildSolid()!;
      final plane = SketchPlane.fromFace(body, 2);
      final ref = [for (final vi in body.faces[2]) plane.to2d(body.vertices[vi])];
      final boss = Part('Boss')
        ..plane = plane
        ..depth = 20
        ..referenceLoop = ref
        ..parent = base
        ..decorations.add(CircleEntity(centroid2d(ref), 15)); // overhangs a ~9.8 facet
      final s = boss.solidOnPlane()!;
      final down = plane.normal * -1.0;
      for (final vi in s.faces[0]) {
        expect(body.rayHit(s.vertices[vi], down) ?? 0, lessThan(1e-3),
            reason: 'nothing beneath the base');
      }
    });
  });

  group('RULES · solids', () {
    test('RULE: an unclosed inner scribble cannot erase the outer profile', () {
      // Bug: "the outer part profile disappears when an inner hole is created".
      final m = ParametricSketch()..addPolyline(square);
      m.addPolyline(const [Offset(30, 30), Offset(60, 30), Offset(60, 60)]); // open chain
      expect(m.allClosedLoops().length, 1);
    });

    test('RULE: a circle-only sketch is a cylinder', () {
      expect(cylinderPart().buildSolid(), isNotNull);
    });
  });
}
