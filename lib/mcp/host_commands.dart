import 'dart:convert';
import 'dart:ui' show Offset;

import '../export/mesh_export.dart';
import '../export/stl.dart';
import '../sketch/entities.dart';
import '../sketch/model.dart';
import '../sketch/part.dart';
import '../ui/sketch_canvas.dart';
import 'host_document.dart';
import 'part_spec.dart';

// The editing commands an AI host can run in the live editor. Each one goes
// through the controller's ordinary public API (the same calls a tap or drag
// makes), so it shows up on the undo stack and behaves like a hand edit. One
// command is one undo step.
//
// Everything the host addresses is in the model's own terms, the ones
// `get_sketch` reports: millimetres with Y up, a part by name, a vertex or edge
// by its index around the closed profile, a hole by its index in `holes`.
//
// Pure of web and widgets (it needs only the controller), so it runs in
// `flutter test`.

/// Thrown for a command the host got wrong. The message goes back to the model,
/// so it says what to do instead.
class HostCommandException implements Exception {
  const HostCommandException(this.message);
  final String message;
  @override
  String toString() => message;
}

const _constraintKinds = {
  'horizontal': ConstraintKind.horizontal,
  'vertical': ConstraintKind.vertical,
  'parallel': ConstraintKind.parallel,
  'perpendicular': ConstraintKind.perpendicular,
  'equal': ConstraintKind.equalLength,
};

/// Runs [op] with [args] and returns a JSON-able result. Throws
/// [HostCommandException] (or [PartSpecException]) for bad input.
Map<String, dynamic> runHostCommand(
    SketchController c, String op, Map<String, dynamic> args) {
  switch (op) {
    case 'get_sketch':
      return _document(c);

    case 'replace_parts':
      loadPartSpecs(c, partSpecsFromJson(args['parts']));
      return _document(c, did: 'Replaced the canvas.');

    case 'add_part':
      final spec = PartSpec.fromJson(args['part']);
      if (c.parts.any((p) => p.name == spec.name)) {
        throw HostCommandException(
            'A part named "${spec.name}" already exists. Pick another name.');
      }
      final hadOnlyPlaceholder = !c.hasWork;
      importPartSpec(c, spec);
      if (hadOnlyPlaceholder) {
        c.removePart(0);
        c.setActive(0);
      }
      c.requestFitView();
      return _part(c, c.active, did: 'Added part "${spec.name}".');

    case 'delete_part':
      final part = _resolvePart(c, args['part']);
      final name = part.name;
      c.removePart(c.parts.indexOf(part));
      return _document(c, did: 'Deleted part "$name".');

    case 'select_part':
      final part = _resolvePart(c, args['part'], required: true);
      _activate(c, part);
      return _part(c, part, did: 'Selected "${part.name}".');

    case 'set_depth':
      final part = _resolvePart(c, args['part']);
      final depth = _positive(args['depth'], 'depth');
      c.setPartDepth(c.parts.indexOf(part), depth);
      return _part(c, part, did: 'Set "${part.name}" to ${_fmt(depth)} mm thick.');

    case 'add_hole':
      final part = _resolvePart(c, args['part']);
      _activate(c, part);
      final centre = _point(args['center'], 'center');
      final radius = _positive(args['radius'], 'radius');
      c.addCircle(centre, radius);
      return _part(c, part,
          did: 'Added a hole, radius ${_fmt(radius)} mm.',
          warnIfHoleOutside: centre);

    case 'move_hole':
      final part = _resolvePart(c, args['part']);
      _activate(c, part);
      final di = _holeDecoration(part, args['hole']);
      if (args['center'] == null && args['radius'] == null) {
        throw const HostCommandException('Give a new center, a new radius, or both.');
      }
      c.beginSketchEdit();
      try {
        if (args['center'] != null) c.moveCircle(di, _point(args['center'], 'center'));
        if (args['radius'] != null) {
          c.setCircleRadius(di, _positive(args['radius'], 'radius'));
        }
      } finally {
        c.endSketchEdit();
      }
      return _part(c, part, did: 'Updated hole ${args['hole']}.');

    case 'remove_hole':
      final part = _resolvePart(c, args['part']);
      _activate(c, part);
      c.deleteDecoration(_holeDecoration(part, args['hole']));
      return _part(c, part, did: 'Removed hole ${args['hole']}.');

    case 'move_vertex':
      final part = _resolvePart(c, args['part']);
      _activate(c, part);
      final loop = _loop(part);
      final vi = _index(args['vertex'], loop.length, 'vertex');
      final to = _point(args['to'], 'to');
      c.beginSketchEdit();
      try {
        if (args['release_constraints'] == true) {
          c.releaseIncidentConstraints(loop[vi]);
        }
        c.movePoint(loop[vi], to);
      } finally {
        c.endSketchEdit();
      }
      return _part(c, part, did: 'Moved vertex $vi.');

    case 'set_dimension':
      final part = _resolvePart(c, args['part']);
      _activate(c, part);
      final loop = _loop(part);
      final ei = _index(args['edge'], loop.length, 'edge');
      final si = _edgeSegment(part, loop, ei);
      final length = args['length'];
      if (length == null) {
        c.setDrivingLength(si, null);
        return _part(c, part, did: 'Edge $ei is no longer dimension-driven.');
      }
      c.setDrivingLength(si, _positive(length, 'length'));
      return _part(c, part,
          did: 'Edge $ei is now driven to ${_fmt((length as num).toDouble())} mm.');

    case 'add_constraint':
      final part = _resolvePart(c, args['part']);
      _activate(c, part);
      final kind = _constraintKinds[args['kind']];
      if (kind == null) {
        throw HostCommandException(
            'kind must be one of: ${_constraintKinds.keys.join(', ')}.');
      }
      final edges = args['edges'];
      final needs = (kind == ConstraintKind.horizontal ||
              kind == ConstraintKind.vertical)
          ? 1
          : 2;
      if (edges is! List || edges.length != needs) {
        throw HostCommandException(
            '${args['kind']} needs exactly $needs edge index${needs == 1 ? '' : 'es'} in "edges".');
      }
      final loop = _loop(part);
      final segs = [
        for (final e in edges)
          _edgeSegment(part, loop, _index(e, loop.length, 'edge')),
      ];
      if (part.sketch.hasConstraint(kind, segs)) {
        return _part(c, part, did: 'That constraint is already there.');
      }
      c.beginSketchEdit();
      try {
        c.applyConstraints([SketchConstraint(kind, segs)]);
      } finally {
        c.endSketchEdit();
      }
      return _part(c, part, did: 'Added ${args['kind']} on edge(s) ${edges.join(', ')}.');

    case 'remove_constraint':
      final part = _resolvePart(c, args['part']);
      _activate(c, part);
      final ci =
          _index(args['constraint'], part.sketch.constraints.length, 'constraint');
      c.beginSketchEdit();
      try {
        c.removeConstraint(ci);
      } finally {
        c.endSketchEdit();
      }
      return _part(c, part, did: 'Removed constraint $ci.');

    case 'undo':
      if (!c.canUndo) throw const HostCommandException('Nothing to undo.');
      c.undo();
      return _document(c, did: 'Undid the last edit.');

    case 'redo':
      if (!c.canRedo) throw const HostCommandException('Nothing to redo.');
      c.redo();
      return _document(c, did: 'Redid the edit.');

    case 'fit_view':
      c.requestFitView();
      return {'did': 'Zoomed to fit.'};

    case 'export_stl':
      final part = _resolvePart(c, args['part']);
      final tris = partExportTriangles(part);
      if (tris.isEmpty) {
        throw HostCommandException(
            '"${part.name}" has nothing to export yet: its profile is not a closed shape.');
      }
      return {
        'did': 'Exported "${part.name}" (${tris.length} triangles).',
        'fileName': '${part.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')}.stl',
        'triangles': tris.length,
        'stlBase64': base64Encode(trianglesToStlBytes(tris)),
      };
  }
  throw HostCommandException('Unknown command "$op".');
}

// --- results ----------------------------------------------------------------

Map<String, dynamic> _document(SketchController c, {String? did}) {
  final ctx = modelContextOf(c);
  return {
    'did': ?did,
    'summary': ctx.text,
    'activePart': ctx.structured['activePart'],
    'parts': [for (final p in c.parts) partDetailJson(p)],
  };
}

Map<String, dynamic> _part(SketchController c, Part part,
    {required String did, Offset? warnIfHoleOutside}) {
  final detail = partDetailJson(part);
  String? warning;
  if (warnIfHoleOutside != null) {
    final profile = part.sketch.closedProfile();
    if (profile != null && !_inside(profile, warnIfHoleOutside)) {
      warning =
          'That hole is outside the profile, so it does not cut the part. Move it inside or remove it.';
    }
  }
  return {'did': did, 'warning': ?warning, 'part': detail};
}

/// A part with everything a host needs to address it: the spec, plus each
/// edge's length and driving dimension, and the constraints by index.
Map<String, dynamic> partDetailJson(Part part) {
  final json = partToSpecJson(part);
  final s = part.sketch;
  final loop = s.closedLoop();
  if (loop == null) return json;

  final segToEdge = <int, int>{};
  final edges = <Map<String, dynamic>>[];
  for (var i = 0; i < loop.length; i++) {
    final si = _segmentBetween(s, loop[i], loop[(i + 1) % loop.length]);
    if (si == null) continue;
    segToEdge[si] = i;
    final seg = s.segments[si];
    edges.add({
      'edge': i,
      'from': i,
      'to': (i + 1) % loop.length,
      'length': _round(s.measuredLength(si)),
      if (seg.isArc) 'arc': true,
      if (seg.drivingLength != null) 'driving': _round(seg.drivingLength!),
      'param': ?seg.lengthParam,
    });
  }
  json['edges'] = edges;
  json['constraintList'] = [
    for (var i = 0; i < s.constraints.length; i++)
      {
        'constraint': i,
        'kind': _constraintKinds.entries
                .where((e) => e.value == s.constraints[i].kind)
                .map((e) => e.key)
                .firstOrNull ??
            s.constraints[i].kind.name,
        'edges': [
          for (final si in s.constraints[i].segments) segToEdge[si] ?? -1,
        ],
      },
  ];
  // The profile the model addresses is the loop, vertex by vertex. An arc edge
  // keeps its bulge here (the spec profile may have tessellated nothing).
  return json;
}

// --- addressing ---------------------------------------------------------------

Part _resolvePart(SketchController c, Object? ref, {bool required = false}) {
  if (ref == null) {
    if (required) {
      throw const HostCommandException('Say which part, by name.');
    }
    return c.active;
  }
  if (ref is int && ref >= 0 && ref < c.parts.length) return c.parts[ref];
  final name = ref.toString();
  final matches = c.parts.where((p) => p.name == name).toList();
  if (matches.length == 1) return matches.single;
  final names = c.parts.map((p) => '"${p.name}"').join(', ');
  throw HostCommandException(matches.isEmpty
      ? 'No part named "$name". Parts: $names.'
      : 'More than one part is named "$name"; give its index instead.');
}

void _activate(SketchController c, Part part) {
  final i = c.parts.indexOf(part);
  if (i >= 0 && i != c.activeIndex) c.setActive(i);
}

List<int> _loop(Part part) {
  final loop = part.sketch.closedLoop();
  if (loop == null) {
    throw HostCommandException(
        '"${part.name}" does not have a closed profile, so its vertices and edges cannot be addressed. Use replace_parts or add_part to draw a closed shape.');
  }
  return loop;
}

int _edgeSegment(Part part, List<int> loop, int edge) {
  final si = _segmentBetween(
      part.sketch, loop[edge], loop[(edge + 1) % loop.length]);
  if (si == null) throw HostCommandException('Edge $edge has no segment.');
  return si;
}

int? _segmentBetween(ParametricSketch s, int a, int b) {
  for (var i = 0; i < s.segments.length; i++) {
    final seg = s.segments[i];
    if ((seg.a == a && seg.b == b) || (seg.a == b && seg.b == a)) return i;
  }
  return null;
}

/// Decoration index of the [hole]-th reported hole, by the same rule `partToIr`
/// reports them: with a profile, the circles inside it in draw order; with no
/// profile, the circles inside the largest one (which is the round body).
int _holeDecoration(Part part, Object? hole) {
  final profile = part.sketch.closedProfile();
  final indices = <int>[];
  if (profile != null) {
    for (var i = 0; i < part.decorations.length; i++) {
      final e = part.decorations[i];
      if (e is CircleEntity && _inside(profile, e.center)) indices.add(i);
    }
  } else {
    CircleEntity? body;
    for (final e in part.decorations) {
      if (e is CircleEntity && (body == null || e.radius > body.radius)) body = e;
    }
    for (var i = 0; i < part.decorations.length; i++) {
      final e = part.decorations[i];
      if (e is CircleEntity &&
          !identical(e, body) &&
          (e.center - body!.center).distance < body.radius) {
        indices.add(i);
      }
    }
  }
  return indices[_index(hole, indices.length, 'hole')];
}

bool _inside(List<Offset> poly, Offset pt) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.dy > pt.dy) != (b.dy > pt.dy) &&
        pt.dx < (b.dx - a.dx) * (pt.dy - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

// --- argument parsing ---------------------------------------------------------

int _index(Object? v, int count, String what) {
  if (v is num && v == v.roundToDouble() && v >= 0 && v < count) return v.toInt();
  throw HostCommandException(count == 0
      ? 'There is no $what to address.'
      : '$what must be an index from 0 to ${count - 1} (see get_sketch).');
}

double _positive(Object? v, String what) {
  if (v is num && v.isFinite && v > 0 && v <= 1e5) return v.toDouble();
  throw HostCommandException('$what must be a positive number of millimetres.');
}

/// A model point `[x, y]` (mm, Y up) as a sketch offset (Y down).
Offset _point(Object? v, String what) {
  if (v is List &&
      v.length == 2 &&
      v.every((n) => n is num && n.isFinite && n.abs() <= 1e6)) {
    return Offset((v[0] as num).toDouble(), -(v[1] as num).toDouble());
  }
  throw HostCommandException('$what must be [x, y] in millimetres.');
}

num _round(double v) {
  final r = (v * 1000).round() / 1000;
  return r == r.roundToDouble() ? r.round() : r;
}

String _fmt(double v) => _round(v).toString();
