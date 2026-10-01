import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../sketch/entities.dart';
import '../sketch/model.dart';
import '../sketch/part.dart';

// Bridge: ai-sketcher -> featuretree (punkfab/featuretree) feature-IR.
//
// A neutral STEP/STL file loses the parametric feature tree — it imports as one
// frozen solid. featuretree's whole point is to KEEP the tree: a design is a
// small, named, ordered list of feature operations that re-author natively in
// FreeCAD / build123d. Its `step_recognize.py` even RECOVERS such a tree from a
// dumb B-rep by inference — because most files arrive with the tree already gone.
//
// ai-sketcher is on the happy side of that wall: it never loses the tree. A part
// already IS its parametric intent — a closed profile (lines + arcs), an extrude
// depth, circular holes, the plane it sits on. So we don't need to *recover*
// features from a solid; we *analyse the sketch and read the features straight
// off it*, emitting featuretree IR directly. That IR then renders — unchanged —
// to a watertight build123d solid AND an editable FreeCAD tree.
//
// This file is the analysis/inference layer: it walks a [Part] and infers the
// ordered feature list (profile -> pad, interior circles -> pocketed holes, arc
// edges preserved as DXF bulges) as JSON-able maps matching featuretree's
// `ir.py` schema (kind/name/... exactly), so the output drops into `gen.py` /
// `b3d_emit.py` with no reshaping. Pure Dart — no Flutter, no FFI — so it runs
// in a plain `dart test` and on every target the app ships to.

/// A featuretree feature-IR spec: `{"name": ..., "features": [ ... ]}`. Ready to
/// `jsonEncode` and hand to `featuretree/gen.py part.ir.json out.FCStd`.
typedef FeatureIr = Map<String, dynamic>;

/// Converts one ai-sketcher [part] into a featuretree part spec.
///
/// Inference:
///  * the sketch's single closed loop -> an outer `profile` sketch + a `pad`
///    (`body`) of the part's extrude depth. Arc edges are kept as DXF bulges,
///    not tessellated, so the emitted profile has true circular arcs.
///  * each full [CircleEntity] whose centre lies inside that profile -> its own
///    circle sketch + a through `pocket` (a drilled hole). Circles outside the
///    profile are ignored (stray construction marks).
///  * with no closed profile but circles present -> the largest circle is the
///    body (a padded cylinder) and circles inside it are through holes.
///
/// [scale] multiplies every length (ai-sketcher logical units -> mm; default
/// 1:1). Sketch Y is flipped (screen Y-down -> CAD Y-up) so the FreeCAD part is
/// oriented as drawn, and arc bulges are sign-flipped to match that reflection.
FeatureIr partToIr(Part part, {double scale = 1.0}) {
  final features = <Map<String, dynamic>>[];
  final s = part.sketch;

  final loop = s.closedLoop();
  final circles = part.decorations.whereType<CircleEntity>().toList();

  if (loop != null && loop.length >= 3) {
    final wire = _wireWithBulges(s, loop, scale);
    features.add(_sketch('profile', polys: [wire]));
    features.add(_pad('body', 'profile', _r(part.depth * scale)));

    // Interior circles become drilled through-holes, in draw order.
    final profileTess = s.closedProfile()!; // non-null when closedLoop is
    var hi = 0;
    for (final c in circles) {
      if (!_pointInPolygon(profileTess, c.center)) continue;
      final sk = 'hole${hi}_sketch';
      features.add(_sketch(sk, circles: [_circle(c, scale)]));
      features.add(_pocket('hole$hi', sk, through: true));
      hi++;
    }
  } else if (circles.isNotEmpty) {
    // No closed contour: the largest circle is the body (a cylinder), and any
    // other circle inside it is a through-hole (a washer, a spacer). This is
    // the same rule Part.profileWithHoles builds the solid by.
    final body = circles.reduce((a, b) => b.radius > a.radius ? b : a);
    features.add(_sketch('profile', circles: [_circle(body, scale)]));
    features.add(_pad('body', 'profile', _r(part.depth * scale)));
    var hi = 0;
    for (final c in circles) {
      if (identical(c, body)) continue;
      if ((c.center - body.center).distance >= body.radius) continue;
      final sk = 'hole${hi}_sketch';
      features.add(_sketch(sk, circles: [_circle(c, scale)]));
      features.add(_pocket('hole$hi', sk, through: true));
      hi++;
    }
  }

  return {'name': _slug(part.name), 'features': features};
}

// --- IR builders (shapes match featuretree/ir.py exactly) -------------------

Map<String, dynamic> _sketch(
  String name, {
  String plane = 'XY',
  List<List<num>> circles = const [],
  List<List<num>> rects = const [],
  List<List<List<num>>> polys = const [],
  Map<String, dynamic>? on,
}) =>
    {
      'kind': 'sketch',
      'name': name,
      'plane': plane,
      'on': on,
      'circles': circles,
      'rects': rects,
      'polys': polys,
    };

Map<String, dynamic> _pad(String name, String sketch, num length,
        {bool symmetric = false}) =>
    {
      'kind': 'pad',
      'name': name,
      'sketch': sketch,
      'length': length,
      'symmetric': symmetric,
    };

Map<String, dynamic> _pocket(String name, String sketch,
        {bool through = true, num? length}) =>
    {
      'kind': 'pocket',
      'name': name,
      'sketch': sketch,
      'through': through,
      'length': length,
    };

// --- geometry ---------------------------------------------------------------

/// The ordered profile wire for [loop], each vertex `[x, y]` or `[x, y, bulge]`
/// where an edge is a circular arc. Bulge is the DXF factor `tan(theta/4)` for
/// the edge leaving that vertex (what featuretree's `_poly_face` expects).
List<List<num>> _wireWithBulges(ParametricSketch s, List<int> loop, double scale) {
  final wire = <List<num>>[];
  for (var i = 0; i < loop.length; i++) {
    final ai = loop[i];
    final bi = loop[(i + 1) % loop.length];
    final p = s.points[ai];
    final seg = _segmentBetween(s, ai, bi);
    if (seg != null && seg.isArc) {
      // Directed sweep along the loop (negate if the segment runs b->a here).
      final forward = seg.a == ai;
      final sweep = forward ? seg.arc!.sweep : -seg.arc!.sweep;
      // Y is flipped below, a reflection that reverses arc orientation, so the
      // bulge sign flips too.
      final bulge = -math.tan(sweep / 4);
      wire.add([_r(p.dx * scale), _r(-p.dy * scale), _r(bulge)]);
    } else {
      wire.add([_r(p.dx * scale), _r(-p.dy * scale)]);
    }
  }
  return wire;
}

List<num> _circle(CircleEntity c, double scale) =>
    [_r(c.center.dx * scale), _r(-c.center.dy * scale), _r(c.radius * scale)];

Segment? _segmentBetween(ParametricSketch s, int a, int b) {
  for (final seg in s.segments) {
    if ((seg.a == a && seg.b == b) || (seg.a == b && seg.b == a)) return seg;
  }
  return null;
}

/// Even-odd ray cast. [poly] and [pt] are both in raw sketch coords (the Y flip
/// applied later is uniform, so it doesn't change inside/outside).
bool _pointInPolygon(List<Offset> poly, Offset pt) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final pi = poly[i], pj = poly[j];
    final crosses = (pi.dy > pt.dy) != (pj.dy > pt.dy);
    if (crosses &&
        pt.dx < (pj.dx - pi.dx) * (pt.dy - pi.dy) / (pj.dy - pi.dy) + pi.dx) {
      inside = !inside;
    }
  }
  return inside;
}

// --- helpers ----------------------------------------------------------------

/// Round to 6 decimals to keep float noise out of the emitted JSON.
num _r(double v) {
  final rounded = (v * 1e6).round() / 1e6;
  return rounded == rounded.roundToDouble() ? rounded.round() : rounded;
}

/// A safe FreeCAD Label / feature name from a part name.
String _slug(String name) {
  final s = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  final trimmed = s.replaceAll(RegExp(r'^_+|_+$'), '');
  return trimmed.isEmpty ? 'part' : trimmed;
}
