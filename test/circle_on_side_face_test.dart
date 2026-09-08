import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/beautify.dart';
import 'package:ai_sketcher/sketch/entities.dart';
import 'package:ai_sketcher/sketch/part.dart';
import 'package:ai_sketcher/sketch/plane.dart';
import 'package:ai_sketcher/sketch/solid.dart';

// Regression: "I can draw a circle on the round cap of a cylinder, but not on
// the thin rectangular side face." On a cap you draw a big circle (radius ~25);
// on a thin side face you draw a SMALL one. Recognition's corner-vs-curve step
// used an absolute RDP epsilon floor (~1.5 model units), which on a small circle
// is a large fraction of the radius — RDP collapsed it to a coarse polygon whose
// turns exceeded the corner threshold, so it misread as a polyline and no circle
// persisted. The corner epsilon is now size-relative, so a clean circle reads as
// a circle at any size. (A circle still must be >= ~5px on screen — draw it, or
// zoom in — but it no longer silently turns into a polygon.)

List<Offset> circleStroke(Offset center, double r, {int n = 48}) => [
      for (var i = 0; i <= n; i++)
        center +
            Offset(r * math.cos(2 * math.pi * i / n),
                r * math.sin(2 * math.pi * i / n)),
    ];

Offset centroid2d(List<Offset> pts) {
  var sx = 0.0, sy = 0.0;
  for (final p in pts) {
    sx += p.dx;
    sy += p.dy;
  }
  return Offset(sx / pts.length, sy / pts.length);
}

// A cylinder: radius 50, depth 200. Faces 0/1 are the round caps (32-gon),
// faces 2.. are the thin side quads (chord width ~9.8).
Solid cylinder() {
  const seg = 32;
  final profile = [
    for (var i = 0; i < seg; i++)
      Offset(50 * math.cos(2 * math.pi * i / seg),
          50 * math.sin(2 * math.pi * i / seg)),
  ];
  return extrudeProfile(profile, 200);
}

StrokeResult drawCircleOnFace(Solid solid, int f, double radius,
    {double scale = 1}) {
  final plane = SketchPlane.fromFace(solid, f);
  final ref = [for (final vi in solid.faces[f]) plane.to2d(solid.vertices[vi])];
  return recognizeStroke(circleStroke(centroid2d(ref), radius), scale: scale);
}

void main() {
  test('cap face: a circle recognizes as a circle', () {
    final res = drawCircleOnFace(cylinder(), 1, 20);
    expect((res as DecorationResult).entity, isA<CircleEntity>());
  });

  test('SIDE face: a small circle (r=6) recognizes as a circle at 1x', () {
    // Pre-fix this misread as a PolylineResult (a coarse polygon) and vanished.
    final res = drawCircleOnFace(cylinder(), 2, 6);
    expect(res, isA<DecorationResult>(),
        reason: 'a clean small circle on a thin side face must read as a circle');
    expect((res as DecorationResult).entity, isA<CircleEntity>());
  });

  test('SIDE face: an even smaller circle recognizes once zoomed in', () {
    // A circle below ~5px on screen is noise at 1x; a modest zoom recovers it.
    expect(drawCircleOnFace(cylinder(), 2, 2.5, scale: 1), isA<PolylineResult>());
    final zoomed = drawCircleOnFace(cylinder(), 2, 2.5, scale: 3);
    expect((zoomed as DecorationResult).entity, isA<CircleEntity>());
  });

  test('SIDE face: a recognized circle extrudes ON the side face', () {
    final cyl = cylinder();
    const side = 2;
    final plane = SketchPlane.fromFace(cyl, side);
    final ref = [for (final vi in cyl.faces[side]) plane.to2d(cyl.vertices[vi])];
    final feat = Part('Boss')
      ..plane = plane
      ..depth = 30
      ..referenceLoop = ref
      ..decorations.add(CircleEntity(centroid2d(ref), 8));
    final s = feat.solidOnPlane();
    expect(s, isNotNull, reason: 'the side-face boss should produce a solid');
    final faceCentroid = cyl.faceCentroid(side);
    for (final v in s!.vertices) {
      expect((v - faceCentroid).length, lessThan(60),
          reason: 'boss sits on the side face, not off at the XY origin');
    }
  });
}
