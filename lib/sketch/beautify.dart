import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../ffi/sketch_kernel_ffi.dart';
import 'entities.dart';

// Beautification = classify a raw stroke, then snap it to a clean primitive.
//
// The CLASSIFICATION thresholds live here in Dart on purpose: they're the
// tune-by-feel knobs you'll adjust constantly while finding the right feel, and
// hot reload makes that instant. The stable numeric FITS (least squares line,
// Kåsa circle) live in the C++ kernel, because that's durable math the iOS
// build reuses verbatim.
//
// Pipeline: line test first (a straight stroke also fits a huge circle, so line
// wins ties), then circle/arc, else keep the raw stroke.

/// Max allowed perpendicular deviation from the endpoint chord, as a fraction
/// of the chord length, for a stroke to count as "a line". Tune to taste.
const double kLineStraightnessTolerance = 0.06;

/// Strokes shorter than this (logical px) are treated as taps/noise.
const double kMinStrokeLength = 12.0;

/// Max RMS radial residual / radius for a stroke to count as "circular".
const double kCircleResidualTolerance = 0.10;

/// Plausible radius bounds (logical px) — rejects near-degenerate fits.
const double kMinRadius = 5.0;
const double kMaxRadius = 100000.0;

/// Below this swept angle (radians) a "circular" stroke is too shallow to be a
/// meaningful arc — the line test should own it; otherwise we keep it raw.
const double kMinArcSweep = 0.6; // ~34°

/// At/above this swept angle we treat the stroke as a closed full circle.
const double kCircleClosureSweep = 5.4; // ~309°

SketchEntity beautifyStroke(List<Offset> points) {
  if (points.length < 2) return RawStroke(points);

  final chord = (points.last - points.first).distance;
  final pathLen = _pathLength(points);
  if (pathLen < kMinStrokeLength) return RawStroke(points);

  // 1) Line — only meaningful when the stroke actually spans some distance.
  if (chord >= kMinStrokeLength && _isLine(points, chord)) {
    final fit = SketchKernel.instance.fitLine(points);
    if (fit != null) return LineEntity(fit.a, fit.b);
  }

  // 2) Circle / arc.
  if (points.length >= 3) {
    final c = SketchKernel.instance.fitCircle(points);
    if (c != null &&
        c.radius >= kMinRadius &&
        c.radius <= kMaxRadius &&
        c.rms / c.radius <= kCircleResidualTolerance) {
      final sweep = _sweptAngle(points, c.center);
      final mag = sweep.abs();
      if (mag >= kCircleClosureSweep) {
        return CircleEntity(c.center, c.radius);
      }
      if (mag >= kMinArcSweep) {
        final start = _angleTo(c.center, points.first);
        return ArcEntity(c.center, c.radius, start, sweep);
      }
    }
  }

  return RawStroke(points);
}

double _pathLength(List<Offset> pts) {
  var len = 0.0;
  for (var i = 1; i < pts.length; i++) {
    len += (pts[i] - pts[i - 1]).distance;
  }
  return len;
}

/// A stroke is a line if every point stays close to the straight chord between
/// its endpoints (max perpendicular distance / chord length below tolerance).
bool _isLine(List<Offset> points, double chord) {
  final a = points.first;
  final b = points.last;
  final abx = b.dx - a.dx;
  final aby = b.dy - a.dy;
  var maxDev = 0.0;
  for (final p in points) {
    final dev = ((p.dx - a.dx) * aby - (p.dy - a.dy) * abx).abs() / chord;
    if (dev > maxDev) maxDev = dev;
  }
  return maxDev / chord <= kLineStraightnessTolerance;
}

double _angleTo(Offset center, Offset p) =>
    math.atan2(p.dy - center.dy, p.dx - center.dx);

/// Signed total angle swept around [center] walking the stroke, accumulating
/// per-step deltas wrapped to (-pi, pi]. Sign gives CW/CCW; magnitude gives arc
/// extent (and detects closure when it approaches 2*pi).
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
