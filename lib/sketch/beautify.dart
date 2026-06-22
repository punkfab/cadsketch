import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../ffi/sketch_kernel.dart';
import 'entities.dart';

// Stroke recognition. A single stroke becomes one of:
//   - a curve  (circle / arc)            -> DecorationResult
//   - a polyline (one or more segments)  -> PolylineResult  (fed to the model)
//   - a raw scribble                     -> DecorationResult
//
// Key insight (measured): circle-fit residual alone CANNOT separate a freehand
// oval from a polygon — a square's residual sits between an oval's and a
// pentagon's. The real discriminator is CORNER SHARPNESS: a polygon has at
// least one big turn (square 90°, hexagon 60°); a smoothed circle/oval/arc
// never turns more than ~360/N° at any vertex. So we lightly smooth (kill
// stroke noise), simplify with RDP, and branch on the MAX turn angle:
//   max turn small  -> smooth -> fit a circle/arc (oval snaps to circle)
//   max turn large  -> polyline (the corners are the vertices)
//
// Thresholds are tune-by-feel Dart constants (hot reload). Stable fits (line,
// circle) live in the C++ kernel.

/// Strokes shorter than this (logical px) are treated as taps/noise.
const double kMinStrokeLength = 12.0;

/// RDP tolerance as a fraction of the stroke's bounding diagonal (scale-
/// relative, so a circle yields a consistent vertex count at any size).
const double kRelativeRdpEpsilon = 0.02;
const double kMinRdpEpsilon = 1.5;

/// Max turn angle (radians) over all simplified vertices, above which the
/// stroke is treated as having a corner (polygon) rather than being a smooth
/// curve. Sits between a smoothed circle's largest turn and a hexagon's 60°.
const double kCornerThreshold = 0.9; // ~51°

/// Curve branch only sees smooth strokes, so this can be generous — it just
/// rejects non-circular smooth squiggles. Ovals up to ~70x45 snap to a circle.
const double kCircleResidualTolerance = 0.22;
const double kMinRadius = 5.0;
const double kMaxRadius = 100000.0;
const double kMinArcSweep = 0.6; // ~34°
const double kCircleClosureSweep = 5.4; // ~309°

sealed class StrokeResult {
  const StrokeResult();
}

/// A non-parametric entity (circle, arc, raw stroke) — kept as decoration.
class DecorationResult extends StrokeResult {
  const DecorationResult(this.entity);
  final SketchEntity entity;
}

/// An ordered vertex chain; consecutive vertices form line segments. Length 2
/// is a single line; 3+ is a multi-segment polyline.
class PolylineResult extends StrokeResult {
  const PolylineResult(this.vertices);
  final List<Offset> vertices;
}

/// An open circular arc that joins a contour (its endpoints merge with adjacent
/// geometry and it participates in the solver via point-on-circle).
class ArcResult extends StrokeResult {
  const ArcResult(this.start, this.end, this.center, this.radius, this.sweep);
  final Offset start;
  final Offset end;
  final Offset center;
  final double radius;
  final double sweep; // signed, start -> end
}

StrokeResult recognizeStroke(List<Offset> points) {
  if (points.length < 2 || _pathLength(points) < kMinStrokeLength) {
    return DecorationResult(RawStroke(points));
  }

  final eps = math.max(kMinRdpEpsilon, kRelativeRdpEpsilon * _diagonal(points));
  // Smoothed simplification drives the curve-vs-corner decision (noise-robust);
  // the raw simplification supplies sharper vertices for the polyline output.
  final smoothVerts = _rdp(_smooth(points), eps);

  if (_maxTurn(smoothVerts) < kCornerThreshold && points.length >= 3) {
    final c = SketchKernel.instance.fitCircle(points);
    if (c != null &&
        c.radius >= kMinRadius &&
        c.radius <= kMaxRadius &&
        c.rms / c.radius <= kCircleResidualTolerance) {
      final sweep = _sweptAngle(points, c.center);
      final mag = sweep.abs();
      if (mag >= kCircleClosureSweep) {
        return DecorationResult(CircleEntity(c.center, c.radius));
      }
      if (mag >= kMinArcSweep) {
        // Open arc -> a model entity that can join a line+arc contour.
        return ArcResult(points.first, points.last, c.center, c.radius, sweep);
      }
    }
    // Smooth but not circular (or near-straight) — fall through to polyline.
  }

  return _asPolyline(points, _rdp(points, eps));
}

/// Builds a polyline result, refining the single-segment case with the kernel's
/// total-least-squares line fit for cleaner endpoints.
StrokeResult _asPolyline(List<Offset> points, List<Offset> verts) {
  if (verts.length == 2) {
    final fit = SketchKernel.instance.fitLine(points);
    return PolylineResult(fit != null ? [fit.a, fit.b] : verts);
  }
  return PolylineResult(verts);
}

/// Calibration helper: simplified vertex count and largest turn (degrees).
@visibleForTesting
({int verts, double maxTurnDeg}) debugCornerStats(List<Offset> points) {
  final eps = math.max(kMinRdpEpsilon, kRelativeRdpEpsilon * _diagonal(points));
  final v = _rdp(_smooth(points), eps);
  return (verts: v.length, maxTurnDeg: _maxTurn(v) * 180 / math.pi);
}

/// 3-point weighted moving average (endpoints fixed), to suppress stroke noise
/// before corner analysis.
List<Offset> _smooth(List<Offset> pts, {int passes = 2}) {
  var cur = pts;
  for (var k = 0; k < passes && cur.length >= 3; k++) {
    final out = <Offset>[cur.first];
    for (var i = 1; i < cur.length - 1; i++) {
      out.add((cur[i - 1] + cur[i] * 2.0 + cur[i + 1]) * 0.25);
    }
    out.add(cur.last);
    cur = out;
  }
  return cur;
}

/// Largest unsigned turn angle (radians) over interior vertices.
double _maxTurn(List<Offset> verts) {
  var maxT = 0.0;
  for (var i = 1; i < verts.length - 1; i++) {
    final a = verts[i] - verts[i - 1];
    final b = verts[i + 1] - verts[i];
    final cross = a.dx * b.dy - a.dy * b.dx;
    final dot = a.dx * b.dx + a.dy * b.dy;
    final turn = math.atan2(cross.abs(), dot); // unsigned, [0, pi]
    if (turn > maxT) maxT = turn;
  }
  return maxT;
}

double _pathLength(List<Offset> pts) {
  var len = 0.0;
  for (var i = 1; i < pts.length; i++) {
    len += (pts[i] - pts[i - 1]).distance;
  }
  return len;
}

double _diagonal(List<Offset> pts) {
  var minX = pts.first.dx, maxX = pts.first.dx;
  var minY = pts.first.dy, maxY = pts.first.dy;
  for (final p in pts) {
    minX = math.min(minX, p.dx);
    maxX = math.max(maxX, p.dx);
    minY = math.min(minY, p.dy);
    maxY = math.max(maxY, p.dy);
  }
  return Offset(maxX - minX, maxY - minY).distance;
}

/// Ramer–Douglas–Peucker polyline simplification.
List<Offset> _rdp(List<Offset> pts, double epsilon) {
  if (pts.length < 3) return List.of(pts);
  var maxDist = 0.0;
  var index = 0;
  for (var i = 1; i < pts.length - 1; i++) {
    final d = _perpDistance(pts[i], pts.first, pts.last);
    if (d > maxDist) {
      maxDist = d;
      index = i;
    }
  }
  if (maxDist > epsilon) {
    final left = _rdp(pts.sublist(0, index + 1), epsilon);
    final right = _rdp(pts.sublist(index), epsilon);
    return [...left.sublist(0, left.length - 1), ...right];
  }
  return [pts.first, pts.last];
}

/// Perpendicular distance from p to the segment a-b (or to a if a==b).
double _perpDistance(Offset p, Offset a, Offset b) {
  final dx = b.dx - a.dx;
  final dy = b.dy - a.dy;
  final len = math.sqrt(dx * dx + dy * dy);
  if (len < 1e-9) return (p - a).distance;
  return ((p.dx - a.dx) * dy - (p.dy - a.dy) * dx).abs() / len;
}

double _angleTo(Offset center, Offset p) =>
    math.atan2(p.dy - center.dy, p.dx - center.dx);

double _sweptAngle(List<Offset> points, Offset center) {
  var total = 0.0;
  var prev = _angleTo(center, points.first);
  for (var i = 1; i < points.length; i++) {
    final a = _angleTo(center, points[i]);
    var d = a - prev;
    while (d > math.pi) {
      d -= 2 * math.pi;
    }
    while (d <= -math.pi) {
      d += 2 * math.pi;
    }
    total += d;
    prev = a;
  }
  return total;
}
