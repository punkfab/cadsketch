import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../sketch/entities.dart';
import '../sketch/model.dart';
import '../sketch/part.dart';
import '../sketch/solid.dart';

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
  Offset toIr(Offset p) => Offset(p.dx * scale, -p.dy * scale);

  final circles = part.decorations.whereType<CircleEntity>().toList();
  // Every closed loop, largest first: the largest is the outline, a loop inside
  // it is a hole (the rule Part.profileWithHoles builds the solid by).
  final loops = _loopsByArea(s);

  if (loops.isNotEmpty) {
    final outer = loops.first;
    features.add(_sketch('profile', polys: [
      _wire(s, outer.loop, toIr, mirrored: true),
      for (final l in loops.skip(1))
        if (_pointInPolygon(outer.outline, l.outline.first))
          _wire(s, l.loop, toIr, mirrored: true),
    ]));
    features.add(_pad('body', 'profile', _r(part.depth * scale)));

    // Interior circles become drilled through-holes, in draw order.
    var hi = 0;
    for (final c in circles) {
      if (!_pointInPolygon(outer.outline, c.center)) continue;
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

/// A whole body: the base [root] plus every face feature sketched on it, in
/// [parts] order. `dropped` names the features the IR has no way to say.
///
///  * a boss on the top / bottom of the running solid -> face sketch + `pad`
///  * a cut from the top / bottom                     -> face sketch + `pocket`
///  * any other cut (mid-level, or into a side face)  -> `prism_cut`
///  * a boss anywhere else has no IR equivalent and is dropped.
///
/// "Top" and "bottom" are the solid's highest and lowest Z as it stands when
/// the feature is applied — featuretree's rule for a face-attached sketch.
({FeatureIr ir, List<String> dropped}) bodyToIr(Part root, Iterable<Part> parts,
    {double scale = 1.0}) {
  final ir = partToIr(root, scale: scale);
  final features = (ir['features'] as List).cast<Map<String, dynamic>>();
  final dropped = <String>[];
  if (features.isEmpty) return (ir: ir, dropped: dropped);

  final used = {for (final f in features) f['name'] as String};
  String unique(String base) {
    var name = base, n = 2;
    while (!used.add(name)) {
      name = '${base}_${n++}';
    }
    return name;
  }

  // World is the canvas frame (Y down); the IR is Y up.
  List<double> cad(Vec3 w) => [w.x * scale, -w.y * scale, w.z * scale];
  const eps = 1e-6;
  var zMin = 0.0, zMax = root.depth * scale;

  for (final p in parts) {
    if (identical(p, root) || p.referenceLoop == null || !identical(p.root, root)) continue;
    final loops = _loopsByArea(p.sketch);
    final circles = p.decorations.whereType<CircleEntity>().toList()
      ..sort((a, b) => b.radius.compareTo(a.radius));
    if (loops.isEmpty && circles.isEmpty) continue; // nothing drawn yet

    final plane = p.plane;
    final depth = p.depth * scale;
    final cut = p.isSubtractive;
    // The way the material goes (or is taken), and the sketch's frame, in IR
    // space. y = n × x is the frame featuretree gives a placed profile; `s`
    // says whether the sketch's own v runs along it or against it.
    final dir = cad(plane.normal * p.dirSign).map((c) => c / scale).toList();
    final x = cad(plane.u).map((c) => c / scale).toList();
    final v = cad(plane.v).map((c) => c / scale).toList();
    final y = [
      dir[1] * x[2] - dir[2] * x[1],
      dir[2] * x[0] - dir[0] * x[2],
      dir[0] * x[1] - dir[1] * x[0],
    ];
    final s = (v[0] * y[0] + v[1] * y[1] + v[2] * y[2]) < 0 ? -1.0 : 1.0;
    final origin = cad(plane.origin);
    final z = origin[2];
    final axial = dir[2].abs() > 1 - 1e-6;
    final name = unique(_slug(p.name));

    // Outline + the loops inside it, in the frame given by [to].
    List<List<List<num>>> polys(Offset Function(Offset) to, bool mirrored) {
      if (loops.isEmpty) return const [];
      final outer = loops.first;
      return [
        _wire(p.sketch, outer.loop, to, mirrored: mirrored),
        for (final l in loops.skip(1))
          if (_pointInPolygon(outer.outline, l.outline.first))
            _wire(p.sketch, l.loop, to, mirrored: mirrored),
      ];
    }

    // On the top or bottom face of the running solid: global XY coordinates.
    final onTop = axial && (z - zMax).abs() <= eps && dir[2] * (cut ? -1 : 1) > 0;
    final onBottom = axial && (z - zMin).abs() <= eps && dir[2] * (cut ? -1 : 1) < 0;
    if (onTop || onBottom) {
      Offset global(Offset q) {
        final w = cad(plane.to3d(q));
        return Offset(w[0], w[1]);
      }

      // Seen in global XY the sketch is mirrored when its normal points -Z in
      // IR space; IR space is itself the mirror of the world.
      final mirrored = plane.normal.z > 0;
      final sk = unique('${name}_sketch');
      features.add(_sketch(
        sk,
        on: {'face_of': 'body', 'side': onTop ? 'top' : 'bottom'},
        polys: polys(global, mirrored),
        circles: [
          if (loops.isEmpty)
            () {
              final c = global(circles.first.center);
              return <num>[_r(c.dx), _r(c.dy), _r(circles.first.radius * scale)];
            }(),
        ],
      ));
      if (cut) {
        final through = depth >= (zMax - zMin) - eps;
        features.add(_pocket(name, sk,
            through: through, length: through ? null : _r(depth)));
      } else {
        features.add(_pad(name, sk, _r(depth)));
        if (onTop) zMax += depth;
        if (onBottom) zMin -= depth;
      }
      continue;
    }

    if (!cut) {
      dropped.add('${p.name}: a boss that is not on the top or bottom of the '
          'body has no feature-tree equivalent');
      continue;
    }

    // Anything else that removes material: a placed cut.
    Offset local(Offset q) => Offset(q.dx * scale, s * q.dy * scale);
    features.add({
      'kind': 'prism_cut',
      'name': name,
      'origin': [for (final c in origin) _r(c)],
      'normal': [for (final c in dir) _r(c)],
      'xdir': [for (final c in x) _r(c)],
      'depth': _r(depth),
      'polys': loops.isNotEmpty
          ? polys(local, s < 0)
          : [
              () {
                // A circle as two half-circle arcs (bulge 1).
                final c = local(circles.first.center);
                final r = circles.first.radius * scale;
                return <List<num>>[
                  [_r(c.dx - r), _r(c.dy), 1],
                  [_r(c.dx + r), _r(c.dy), 1],
                ];
              }()
            ],
    });
  }
  return (ir: ir, dropped: dropped);
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
/// the edge leaving that vertex, in featuretree's sign (see below).
/// [to] maps a sketch point into the target 2D frame; [mirrored] says that map
/// is a reflection (screen Y-down -> CAD Y-up), which reverses arc sense.
List<List<num>> _wire(ParametricSketch s, List<int> loop, Offset Function(Offset) to,
    {required bool mirrored}) {
  final wire = <List<num>>[];
  for (var i = 0; i < loop.length; i++) {
    final ai = loop[i];
    final bi = loop[(i + 1) % loop.length];
    final p = to(s.points[ai]);
    final seg = _segmentBetween(s, ai, bi);
    if (seg != null && seg.isArc) {
      // Directed sweep along the loop (negate if the segment runs b->a here).
      final forward = seg.a == ai;
      final sweep = forward ? seg.arc!.sweep : -seg.arc!.sweep;
      // featuretree builds a positive bulge on the LEFT of the edge (a
      // clockwise arc), the opposite of the DXF sign its docs name. Every
      // backend agrees with that, so that is the IR: the DXF bulge, negated.
      final bulge = -math.tan((mirrored ? -sweep : sweep) / 4);
      wire.add([_r(p.dx), _r(p.dy), _r(bulge)]);
    } else {
      wire.add([_r(p.dx), _r(p.dy)]);
    }
  }
  return wire;
}

/// Every closed loop of [s] with its tessellated outline, largest area first.
List<({List<int> loop, List<Offset> outline})> _loopsByArea(ParametricSketch s) {
  final loops = s.allClosedLoops();
  final outlines = s.allProfiles();
  final all = [
    for (var i = 0; i < loops.length; i++)
      if (outlines[i].length >= 3) (loop: loops[i], outline: outlines[i]),
  ];
  double area(List<Offset> p) {
    var a = 0.0;
    for (var i = 0, j = p.length - 1; i < p.length; j = i++) {
      a += p[j].dx * p[i].dy - p[i].dx * p[j].dy;
    }
    return a.abs();
  }

  return all..sort((a, b) => area(b.outline).compareTo(area(a.outline)));
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
