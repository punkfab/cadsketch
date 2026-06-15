import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../ffi/sketch_kernel_ffi.dart';
import 'entities.dart';

// Stroke recognition. A single stroke becomes one of:
//   - a curve  (circle / arc)            -> DecorationResult
//   - a polyline (one or more segments)  -> PolylineResult  (fed to the model)
//   - a raw scribble                     -> DecorationResult
//
// Multi-line detection: a stroke that isn't a single primitive is simplified
// with Ramer–Douglas–Peucker; the retained vertices are the corners, and each
// consecutive pair is a segment. So a whole rectangle or L drawn in one stroke
// is recognized as connected segments (the model merges the shared corners).
//
// Thresholds are tune-by-feel Dart constants (hot reload). Stable fits (line,
// circle) live in the C++ kernel.

/// Strokes shorter than this (logical px) are treated as taps/noise.
const double kMinStrokeLength = 12.0;

/// Max RMS radial residual / radius for a stroke to count as "circular".
const double kCircleResidualTolerance = 0.10;
const double kMinRadius = 5.0;
const double kMaxRadius = 100000.0;
const double kMinArcSweep = 0.6; // ~34°
const double kCircleClosureSweep = 5.4; // ~309°

/// RDP simplification tolerance (logical px): how far the stroke may stray from
/// a straight segment before a corner is introduced. Lower = more corners.
const double kPolylineTolerance = 4.0;

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

StrokeResult recognizeStroke(List<Offset> points) {
  if (points.length < 2 || _pathLength(points) < kMinStrokeLength) {
    return DecorationResult(RawStroke(points));
  }

  // 1) Curve test first — must run before RDP, which would shatter an arc into
  //    a many-sided polygon.
  if (points.length >= 3) {
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
        final start = _angleTo(c.center, points.first);
        return DecorationResult(ArcEntity(c.center, c.radius, start, sweep));
      }
    }
  }

  // 2) Polyline (covers the single-line case as a 2-vertex chain).
  final verts = _rdp(points, kPolylineTolerance);
  if (verts.length == 2) {
    // One clean segment — use the kernel's total-least-squares fit for nicer
    // endpoints than the raw stroke ends.
    final fit = SketchKernel.instance.fitLine(points);
    return PolylineResult(fit != null ? [fit.a, fit.b] : verts);
  }
  return PolylineResult(verts);
}

double _pathLength(List<Offset> pts) {
  var len = 0.0;
  for (var i = 1; i < pts.length; i++) {
    len += (pts[i] - pts[i - 1]).distance;
  }
  return len;
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
