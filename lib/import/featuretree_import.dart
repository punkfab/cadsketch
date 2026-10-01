import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../sketch/entities.dart';
import '../sketch/model.dart';
import '../sketch/part.dart';
import '../sketch/plane.dart';
import '../sketch/solid.dart';

// Bridge, the other way: featuretree (punkfab/featuretree) feature-IR ->
// CADSketch parts. The mirror of export/featuretree_ir.dart.
//
// The IR is read AS IT IS: nothing here needs a field the IR doesn't have, and
// nothing CADSketch-only is ever written back into an IR file. What the IR
// can't say (sketch constraints, driving dimensions) starts empty, apart from
// the horizontal / vertical constraints the app would infer from the drawn
// geometry anyway. What CADSketch can't show (fillets, revolves, draft,
// sideways cuts, ...) is SKIPPED AND NAMED in the result, never dropped
// silently. If the first solid itself can't be built, the import refuses.
//
// How an IR part lands:
//   * the first pad            -> the base body (a Part: profile + depth)
//   * a cut through the body   -> a hole in the base profile
//   * a pad on the top/bottom  -> a face feature (union) on the base
//   * a blind cut that opens   -> a face feature (difference) on the base
//     onto the top/bottom
// Placement follows featuretree's reference backend (b3d_emit.py): "top" and
// "bottom" are the running solid's highest and lowest Z, a pad grows +Z unless
// its sketch is on the bottom face, a blind pocket cuts into the material.
//
// The IR is Y-up; the canvas is Y-down. The base and top-face sketches flip Y
// (as DXF import does); a bottom-face sketch is seen from below, which is the
// same mirror, so its coordinates are used as written.
//
// Pure Dart (no widgets, no FFI, no web). Input is untrusted: sizes are capped
// and every number is checked. Loop self-intersection is NOT checked here (the
// Python validator needs shapely for that); a self-crossing loop imports as
// drawn.

/// Thrown when the IR is malformed or its first solid can't be shown. The
/// message is safe to show.
class IrImportException implements Exception {
  const IrImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One IR feature that was left out, and why.
class IrSkipped {
  const IrSkipped(this.feature, this.kind, this.reason);
  final String feature;
  final String kind;
  final String reason;
  @override
  String toString() => '$feature ($kind): $reason';
}

/// The outcome of reading one IR part.
class IrImport {
  IrImport(this.name);
  final String name;

  /// `parts[0]` is the base body; the rest are face features on it.
  final List<Part> parts = [];

  /// IR feature names (pads, pockets, cuts) that are represented in [parts].
  final List<String> imported = [];

  /// IR features that are NOT represented.
  final List<IrSkipped> skipped = [];

  /// Features that came in, but not exactly.
  final List<String> notes = [];

  /// One line for a snackbar / host message.
  String summary() {
    final b = StringBuffer(
        '$name: ${imported.length} feature${imported.length == 1 ? '' : 's'} imported');
    if (skipped.isNotEmpty) {
      b.write(', ${skipped.length} skipped '
          '(${skipped.map((s) => s.feature).take(6).join(', ')}'
          '${skipped.length > 6 ? ', …' : ''})');
    }
    return b.toString();
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'parts': [for (final p in parts) p.name],
        'imported': imported,
        'skipped': [
          for (final s in skipped)
            {'feature': s.feature, 'kind': s.kind, 'reason': s.reason}
        ],
        'notes': notes,
      };
}

const int _maxFeatures = 2000;
const int _maxVertices = 5000;
const int _maxLoops = 5000;

/// A bulge smaller than this is a straight line (the IR spec's rule).
const double _bulgeEps = 1e-4;
const double _zEps = 1e-6;

/// Reads IR text that holds one part spec `{"name", "features"}` or a list of
/// them.
List<IrImport> importFeatureIrDocument(Object? json) {
  if (json is Map) return [importFeatureIr(json)];
  if (json is List) {
    if (json.isEmpty) throw const IrImportException('the file has no parts');
    if (json.length > 50) throw const IrImportException('too many parts');
    return [for (final spec in json) importFeatureIr(spec)];
  }
  throw const IrImportException('not a feature tree: expected an object with "features"');
}

/// Reads one IR part spec.
IrImport importFeatureIr(Object? json) {
  if (json is! Map) {
    throw const IrImportException('not a feature tree: expected an object with "features"');
  }
  final features = json['features'];
  if (features is! List) {
    throw const IrImportException('not a feature tree: no "features" list');
  }
  if (features.length > _maxFeatures) {
    throw const IrImportException('too many features');
  }
  final name = (json['name'] ?? 'part').toString().trim();
  return _Reader(IrImport(name.isEmpty ? 'part' : name)).read(features);
}

// --- geometry in IR coordinates (mm, Y up) -----------------------------------

class _Loop {
  _Loop.poly(this.verts) : circle = null;
  _Loop.circle(double cx, double cy, double r)
      : circle = [cx, cy, r],
        verts = const [];

  /// `[x, y, bulge]` per vertex; bulge (DXF sign) belongs to the edge leaving it.
  final List<List<double>> verts;
  final List<double>? circle;

  late final List<Offset> outline = _tessellate();
  late final double area = _area(outline);

  List<Offset> _tessellate() {
    final c = circle;
    if (c != null) {
      return [
        for (var k = 0; k < 48; k++)
          Offset(c[0] + c[2] * math.cos(2 * math.pi * k / 48),
              c[1] + c[2] * math.sin(2 * math.pi * k / 48)),
      ];
    }
    final pts = <Offset>[];
    for (var i = 0; i < verts.length; i++) {
      final v = verts[i], w = verts[(i + 1) % verts.length];
      final p0 = Offset(v[0], v[1]);
      pts.add(p0);
      if (v[2] == 0) continue;
      final arc = _arcOf(p0, Offset(w[0], w[1]), v[2]);
      final n = math.max(2, (arc.sweep.abs() / 0.2).ceil());
      final a0 = math.atan2(p0.dy - arc.center.dy, p0.dx - arc.center.dx);
      for (var k = 1; k < n; k++) {
        final a = a0 + arc.sweep * k / n;
        pts.add(arc.center + Offset(math.cos(a), math.sin(a)) * arc.radius);
      }
    }
    return pts;
  }
}

/// A region of material or of cut: an outer loop and the loops nested in it.
class _Region {
  _Region(this.outer, this.holes);
  final _Loop outer;
  final List<_Loop> holes;
}

/// The arc from [p0] to [p1] with DXF bulge [b] = tan(sweep / 4), CCW positive.
({Offset center, double radius, double sweep}) _arcOf(Offset p0, Offset p1, double b) {
  final chord = p1 - p0;
  final c = chord.distance;
  final theta = 4 * math.atan(b);
  final left = Offset(-chord.dy, chord.dx) / c;
  final center = p0 + chord / 2 + left * ((c / 2) / math.tan(theta / 2));
  return (center: center, radius: (p0 - center).distance, sweep: theta);
}

double _area(List<Offset> p) {
  var a = 0.0;
  for (var i = 0, j = p.length - 1; i < p.length; j = i++) {
    a += p[j].dx * p[i].dy - p[i].dx * p[j].dy;
  }
  return a.abs() / 2;
}

bool _inside(List<Offset> poly, Offset p) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.dy > p.dy) != (b.dy > p.dy) &&
        p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

// --- the reader --------------------------------------------------------------

class _Sketch {
  _Sketch(this.regions, this.z0, this.side, this.plane);
  final List<_Region> regions;
  final double z0;
  final String? side; // "top" | "bottom" for a face-attached sketch
  final String plane;
}

class _Reader {
  _Reader(this.out);
  final IrImport out;

  final _sketches = <String, _Sketch>{};
  final _names = <String>{};
  var _loops = 0;

  Part? _base;
  List<Offset> _baseOutline = const []; // IR coords
  double _zMin = 0, _zMax = 0;

  /// Z of every flat material surface facing up / down, so a cut that opens
  /// onto the base's top is recognised even after a boss has raised the part.
  final _tops = <double>[];
  final _bottoms = <double>[];

  IrImport read(List features) {
    for (final raw in features) {
      if (raw is! Map) throw const IrImportException('each feature must be an object');
      final kind = (raw['kind'] ?? '').toString();
      final name = (raw['name'] ?? '').toString();
      if (name.isEmpty) throw IrImportException('a $kind feature has no name');
      if (!_names.add(name)) throw IrImportException('$name: duplicate feature name');
      switch (kind) {
        case 'sketch':
          _sketch(name, raw);
        case 'pad':
          _pad(name, raw);
        case 'pocket':
          _pocket(name, raw);
        case 'prism_cut':
          _prismCut(name, raw);
        case 'fillet':
          _skip(name, kind, "rounded edges aren't shown in CADSketch");
        case 'revolve':
          _skip(name, kind, "CADSketch extrudes; it has no revolve");
        case 'polar_pocket':
          _skip(name, kind, "a ring of sideways bores can't be shown");
        default:
          _skip(name, kind, 'unknown feature kind');
      }
    }
    if (_base == null) {
      throw IrImportException(out.skipped.isEmpty
          ? '${out.name} has no pad to make a body from'
          : "${out.name} can't be shown: ${out.skipped.first}");
    }
    return out;
  }

  void _skip(String name, String kind, String reason) {
    // No body yet and the feature that would have made one is unsupported:
    // there is nothing to show the rest on.
    if (_base == null && (kind == 'pad' || kind == 'revolve')) {
      throw IrImportException("${out.name} can't be shown: its first solid "
          '"$name" is a $kind CADSketch has no equivalent for ($reason)');
    }
    out.skipped.add(IrSkipped(name, kind, reason));
  }

  // -- sketch -----------------------------------------------------------------

  void _sketch(String name, Map f) {
    final regions = <_Region>[];
    for (final c in _list(f['circles'])) {
      final v = _numbers(c, 3, 3, '$name: circle');
      if (v[2] <= 0) throw IrImportException('$name: circle radius must be positive');
      regions.add(_Region(_Loop.circle(v[0], v[1], v[2]), const []));
    }
    for (final r in _list(f['rects'])) {
      final v = _numbers(r, 4, 4, '$name: rect');
      if (v[0] <= 0 || v[1] <= 0) throw IrImportException('$name: rect size must be positive');
      final hw = v[0] / 2, hh = v[1] / 2;
      regions.add(_Region(
          _Loop.poly([
            [v[2] - hw, v[3] - hh, 0],
            [v[2] + hw, v[3] - hh, 0],
            [v[2] + hw, v[3] + hh, 0],
            [v[2] - hw, v[3] + hh, 0],
          ]),
          const []));
    }
    regions.addAll(_polyRegions(name, _list(f['polys'])));
    _loops += regions.fold<int>(0, (n, r) => n + 1 + r.holes.length);
    if (_loops > _maxLoops) throw const IrImportException('too many loops');

    final on = f['on'];
    String? side;
    var z0 = 0.0;
    if (on is Map) {
      side = (on['side'] ?? 'top').toString() == 'bottom' ? 'bottom' : 'top';
      // As b3d_emit: the face of the solid as it stands when the sketch is made.
      z0 = side == 'top' ? _zMax : _zMin;
    }
    _sketches[name] =
        _Sketch(regions, z0, side, on is Map ? 'XY' : (f['plane'] ?? 'XY').toString());
  }

  /// Polys as regions, by featuretree's nesting rule: a poly inside another is
  /// a hole in it, an island inside a hole is material again.
  List<_Region> _polyRegions(String where, List polys) {
    final loops = [for (final p in polys) _polyLoop(where, p)];
    final order = [for (var i = 0; i < loops.length; i++) i]
      ..sort((a, b) => loops[b].area.compareTo(loops[a].area));
    final parent = <int, int?>{}, depth = <int, int>{};
    for (var n = 0; n < order.length; n++) {
      final i = order[n];
      int? best;
      for (final j in order.take(n)) {
        if (loops[j].area > loops[i].area &&
            _inside(loops[j].outline, loops[i].outline.first) &&
            (best == null || loops[j].area < loops[best].area)) {
          best = j;
        }
      }
      parent[i] = best;
      depth[i] = best == null ? 0 : depth[best]! + 1;
    }
    return [
      for (var i = 0; i < loops.length; i++)
        if (depth[i]!.isEven)
          _Region(loops[i], [
            for (var j = 0; j < loops.length; j++)
              if (parent[j] == i) loops[j]
          ]),
    ];
  }

  _Loop _polyLoop(String where, Object? raw) {
    if (raw is! List) throw IrImportException('$where: a poly must be a list of vertices');
    if (raw.length > _maxVertices) throw IrImportException('$where: poly has too many vertices');
    var v = <List<double>>[
      for (final p in raw)
        () {
          final n = _numbers(p, 2, 3, '$where: poly vertex');
          // Held here in the DXF sign (positive = counter-clockwise).
          // featuretree builds the opposite arc for a positive bulge (its
          // sagitta is to the LEFT of the edge), so the IR's sign is negated.
          final bulge = n.length > 2 && n[2].abs() >= _bulgeEps ? -n[2] : 0.0;
          return [n[0], n[1], bulge];
        }(),
    ];
    // A duplicate closing vertex is dropped (as featuretree's poly_vertices).
    if (v.length > 1 &&
        (v.first[0] - v.last[0]).abs() < 1e-7 &&
        (v.first[1] - v.last[1]).abs() < 1e-7) {
      v.removeLast();
    }
    final arcs = v.any((p) => p[2] != 0);
    if (v.length < (arcs ? 2 : 3)) {
      throw IrImportException('$where: a poly needs at least 3 vertices (2 if arcs)');
    }
    for (var i = 0; i < v.length; i++) {
      final w = v[(i + 1) % v.length];
      if ((v[i][0] - w[0]).abs() < 1e-9 && (v[i][1] - w[1]).abs() < 1e-9) {
        throw IrImportException('$where: a poly has a zero-length segment');
      }
    }
    // A loop of arcs that all lie on one circle IS a circle (the STEP
    // recogniser writes a bore as two half-circle arcs). It comes in as one, so
    // it has a radius to dimension and goes back out as a circle.
    final circle = _asCircle(v);
    if (circle != null) return circle;
    // Two arcs close a loop in the IR; the sketch model needs three vertices
    // to see one, so each arc is split at its middle.
    if (v.length < 3) v = _splitArcs(v);
    return _Loop.poly(v);
  }

  _Loop? _asCircle(List<List<double>> v) {
    if (v.any((p) => p[2] == 0)) return null;
    Offset? center;
    var radius = 0.0, sweep = 0.0;
    for (var i = 0; i < v.length; i++) {
      final w = v[(i + 1) % v.length];
      final arc = _arcOf(Offset(v[i][0], v[i][1]), Offset(w[0], w[1]), v[i][2]);
      final tolerance = 1e-6 * (arc.radius + 1);
      if (center == null) {
        center = arc.center;
        radius = arc.radius;
      } else if ((arc.center - center).distance > tolerance ||
          (arc.radius - radius).abs() > tolerance) {
        return null;
      }
      sweep += arc.sweep;
    }
    if ((sweep.abs() - 2 * math.pi).abs() > 1e-6) return null;
    return _Loop.circle(center!.dx, center.dy, radius);
  }

  List<List<double>> _splitArcs(List<List<double>> v) {
    final out = <List<double>>[];
    for (var i = 0; i < v.length; i++) {
      final p = v[i], q = v[(i + 1) % v.length];
      if (p[2] == 0) {
        out.add(p);
        continue;
      }
      final p0 = Offset(p[0], p[1]);
      final arc = _arcOf(p0, Offset(q[0], q[1]), p[2]);
      final a = math.atan2(p0.dy - arc.center.dy, p0.dx - arc.center.dx) + arc.sweep / 2;
      final mid = arc.center + Offset(math.cos(a), math.sin(a)) * arc.radius;
      final half = math.tan(arc.sweep / 8);
      out
        ..add([p[0], p[1], half])
        ..add([mid.dx, mid.dy, half]);
    }
    return out;
  }

  // -- pad --------------------------------------------------------------------

  void _pad(String name, Map f) {
    final sk = _sketchOf(name, 'pad', f);
    if (sk == null) return;
    final length = _number(f['length'], '$name: length');
    if (length <= 0) throw IrImportException('$name: pad length must be positive');
    if (sk.plane != 'XY') return _skip(name, 'pad', 'its sketch is on the ${sk.plane} plane');
    if (f['symmetric'] == true) return _skip(name, 'pad', "a symmetric pad isn't supported");
    if (_taper(f)) return _skip(name, 'pad', "drafted (tapered) walls aren't shown");
    if (sk.regions.isEmpty) return _skip(name, 'pad', 'its sketch is empty');

    final down = sk.side == 'bottom';
    var regions = sk.regions;
    if (_base == null) {
      // The largest region is the body; any other becomes a boss beside it.
      regions = [...regions]..sort((a, b) => b.outer.area.compareTo(a.outer.area));
      final body = regions.removeAt(0);
      final part = Part(out.name)..depth = length;
      _addLoop(part, body.outer, flipY: true);
      for (final h in body.holes) {
        _addLoop(part, h, flipY: true);
      }
      _inferAxisConstraints(part);
      _base = part;
      _baseOutline = body.outer.outline;
      _zMin = 0;
      _zMax = length;
      _tops.add(length);
      _bottoms.add(0);
      out.parts.add(part);
    }
    for (var i = 0; i < regions.length; i++) {
      _feature(
        regions.length == 1 ? name : '$name ${i + 1}',
        regions[i],
        z: sk.z0,
        up: !down,
        op: FeatureOp.union,
        depth: length,
      );
    }
    if (down) {
      _zMin = math.min(_zMin, sk.z0 - length);
      _bottoms.add(sk.z0 - length);
    } else {
      _zMax = math.max(_zMax, sk.z0 + length);
      _tops.add(sk.z0 + length);
    }
    out.imported.add(name);
  }

  // -- cuts -------------------------------------------------------------------

  void _pocket(String name, Map f) {
    final sk = _sketchOf(name, 'pocket', f);
    if (sk == null) return;
    if (_base == null) return _skip(name, 'pocket', 'there is no body to cut yet');
    if (sk.plane != 'XY') return _skip(name, 'pocket', 'its sketch is on the ${sk.plane} plane');
    if (_taper(f)) return _skip(name, 'pocket', "drafted (tapered) walls aren't shown");
    if (sk.regions.isEmpty) return _skip(name, 'pocket', 'its sketch is empty');
    if (f['through'] != false) {
      _cut(name, 'pocket', sk.regions, double.negativeInfinity, double.infinity);
      return;
    }
    final length = _number(f['length'], '$name: length');
    if (length <= 0) throw IrImportException('$name: blind pocket needs a positive length');
    // As b3d_emit: into the material from the sketch's face.
    final fromTop = sk.z0 >= _zMax - _zEps;
    _cut(name, 'pocket', sk.regions, fromTop ? sk.z0 - length : sk.z0,
        fromTop ? sk.z0 : sk.z0 + length);
  }

  void _prismCut(String name, Map f) {
    if (_base == null) return _skip(name, 'prism_cut', 'there is no body to cut yet');
    if (_taper(f)) return _skip(name, 'prism_cut', "drafted (tapered) walls aren't shown");
    final o = _numbers(f['origin'], 3, 3, '$name: origin');
    final n = _unit(_numbers(f['normal'], 3, 3, '$name: normal'), '$name: normal');
    final x = _unit(_numbers(f['xdir'], 3, 3, '$name: xdir'), '$name: xdir');
    final depth = _number(f['depth'], '$name: depth');
    if (depth <= 0) throw IrImportException('$name: depth must be positive');
    if ((n[0] * x[0] + n[1] * x[1] + n[2] * x[2]).abs() > 1e-6) {
      throw IrImportException('$name: normal and xdir must be orthogonal');
    }
    if (n[2].abs() < 1 - 1e-6) {
      return _skip(name, 'prism_cut', "it cuts sideways; CADSketch shows cuts along the extrude axis");
    }
    // The cut's own 2D frame, laid into global XY: y = n × x (build123d's
    // Plane). Looking along -Z that frame is mirrored, which flips arc sense.
    final y = [n[1] * x[2] - n[2] * x[1], n[2] * x[0] - n[0] * x[2]];
    final mirrored = n[2] < 0;
    List<List<double>> place(List<List<double>> verts) => [
          for (final v in verts)
            [
              o[0] + v[0] * x[0] + v[1] * y[0],
              o[1] + v[0] * x[1] + v[1] * y[1],
              mirrored ? -v[2] : v[2],
            ]
        ];
    _Loop placed(_Loop l) {
      final c = l.circle;
      if (c == null) return _Loop.poly(place(l.verts));
      final at = place([
        [c[0], c[1], 0]
      ]).single;
      return _Loop.circle(at[0], at[1], c[2]);
    }

    final regions = [
      for (final r in _polyRegions(name, _list(f['polys'])))
        _Region(placed(r.outer), [for (final h in r.holes) placed(h)]),
    ];
    if (regions.isEmpty) return _skip(name, 'prism_cut', 'it has no profile');
    final z1 = o[2] + n[2] * depth;
    _cut(name, 'prism_cut', regions, math.min(o[2], z1), math.max(o[2], z1));
  }

  /// A cut of [regions] over the Z interval [lo, hi].
  void _cut(String name, String kind, List<_Region> regions, double lo, double hi) {
    final base = _base!;
    final through = lo <= _zMin + _zEps && hi >= _zMax - _zEps;
    final top = _opensOnto(hi, _tops, above: true);
    final bottom = _opensOnto(lo, _bottoms, above: false);
    if (!through && top == null && bottom == null) {
      return _skip(name, kind, "it's an internal cavity (it opens onto neither the top nor the bottom)");
    }
    var any = false;
    for (var i = 0; i < regions.length; i++) {
      final r = regions[i];
      final label = regions.length == 1 ? name : '$name ${i + 1}';
      if (through) {
        // A hole in the base profile. It has to sit inside the outline: the
        // profile can't express a notch that crosses its own boundary.
        if (!r.outer.outline.every((p) => _inside(_baseOutline, p))) {
          out.skipped.add(IrSkipped(label, kind, 'the cut crosses the outline of the body'));
          continue;
        }
        _addLoop(base, r.outer, flipY: true);
        if (r.holes.isNotEmpty) {
          out.notes.add('$label: the island inside this cut was removed with it');
        }
      } else if (top != null) {
        _feature(label, r, z: top, up: true, op: FeatureOp.difference, depth: top - lo);
      } else {
        _feature(label, r, z: bottom!, up: false, op: FeatureOp.difference, depth: hi - bottom);
      }
      any = true;
    }
    if (through && any) _inferAxisConstraints(base);
    if (any) out.imported.add(name);
  }

  /// The surface level a cut reaching [z] opens onto, if any.
  double? _opensOnto(double z, List<double> levels, {required bool above}) {
    if (above ? z >= _zMax - _zEps : z <= _zMin + _zEps) return above ? _zMax : _zMin;
    for (final level in levels) {
      if ((z - level).abs() <= _zEps) return level;
    }
    return null;
  }

  // -- building parts ---------------------------------------------------------

  /// A face feature on the base: [region] at height [z], on a plane whose
  /// normal points up (+Z) or down, adding or removing [depth] of material.
  void _feature(String name, _Region region,
      {required double z, required bool up, required FeatureOp op, required double depth}) {
    final base = _base!;
    // Up: sketch (x, y) is world (x, y), the base's own frame. Down: v is
    // reversed so the normal u × v points -Z (out of the body).
    final plane = SketchPlane(
        Vec3(0, 0, z), const Vec3(1, 0, 0), Vec3(0, up ? 1 : -1, 0));
    final part = Part(name)
      ..plane = plane
      ..parent = base
      ..operation = op
      ..depth = depth
      ..referenceLoop = [
        for (final p in _baseOutline) Offset(p.dx, up ? -p.dy : p.dy)
      ];
    _addLoop(part, region.outer, flipY: up);
    for (final h in region.holes) {
      _addLoop(part, h, flipY: up);
    }
    if (region.holes.isNotEmpty) {
      out.notes.add('$name: the island inside it is in the sketch but not shown in 3D');
    }
    _inferAxisConstraints(part);
    out.parts.add(part);
  }

  /// Adds [loop] to [part]'s sketch: a circle as a circle, a poly as line and
  /// arc segments (true arcs, so they export back as arcs).
  void _addLoop(Part part, _Loop loop, {required bool flipY}) {
    final s = flipY ? -1.0 : 1.0;
    Offset m(Offset p) => Offset(p.dx, s * p.dy + 0.0);
    final c = loop.circle;
    if (c != null) {
      part.decorations.add(CircleEntity(m(Offset(c[0], c[1])), c[2]));
      return;
    }
    final sketch = part.sketch;
    final first = sketch.points.length;
    final n = loop.verts.length;
    for (final v in loop.verts) {
      sketch.points.add(m(Offset(v[0], v[1])));
    }
    for (var i = 0; i < n; i++) {
      final v = loop.verts[i], w = loop.verts[(i + 1) % n];
      final seg = Segment(first + i, first + (i + 1) % n);
      if (v[2] != 0) {
        final arc = _arcOf(Offset(v[0], v[1]), Offset(w[0], w[1]), v[2]);
        // Mirroring Y reverses the turning sense.
        seg.arc = ArcData(m(arc.center), arc.radius, s * arc.sweep);
      }
      sketch.segments.add(seg);
    }
  }

  /// The IR carries no constraints. Edges drawn exactly horizontal or vertical
  /// get that constraint, as the app infers for a hand-drawn rectangle, so a
  /// driven dimension resizes the shape instead of skewing it. No solve: the
  /// geometry already satisfies them.
  void _inferAxisConstraints(Part part) {
    final s = part.sketch;
    for (var i = 0; i < s.segments.length; i++) {
      final seg = s.segments[i];
      if (seg.isArc) continue;
      final d = s.points[seg.b] - s.points[seg.a];
      final tolerance = 1e-9 * (d.distance + 1);
      final kind = d.dy.abs() <= tolerance
          ? ConstraintKind.horizontal
          : d.dx.abs() <= tolerance
              ? ConstraintKind.vertical
              : null;
      if (kind != null && !s.hasConstraint(kind, [i])) {
        s.constraints.add(SketchConstraint(kind, [i]));
      }
    }
  }

  // -- parsing helpers --------------------------------------------------------

  _Sketch? _sketchOf(String name, String kind, Map f) {
    final ref = (f['sketch'] ?? '').toString();
    final sk = _sketches[ref];
    if (sk == null) {
      throw IrImportException("$name: sketch '$ref' is not an earlier sketch");
    }
    return sk;
  }

  bool _taper(Map f) {
    final t = f['taper'];
    return t is num && t != 0;
  }

  List _list(Object? v) {
    if (v == null) return const [];
    if (v is List) return v;
    throw const IrImportException('expected a list');
  }

  double _number(Object? v, String what) {
    if (v is num && v.isFinite && v.abs() <= 1e6) return v.toDouble();
    throw IrImportException('$what must be a finite number');
  }

  List<double> _numbers(Object? v, int min, int max, String what) {
    if (v is! List || v.length < min || v.length > max) {
      throw IrImportException(
          '$what must be ${min == max ? '$min' : '$min to $max'} numbers');
    }
    return [for (final c in v) _number(c, what)];
  }

  List<double> _unit(List<double> v, String what) {
    final len = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len < 1e-9) throw IrImportException('$what must be non-zero');
    return [v[0] / len, v[1] / len, v[2] / len];
  }
}
