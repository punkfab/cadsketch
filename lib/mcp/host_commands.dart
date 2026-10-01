import 'dart:convert';
import 'dart:ui' show Offset;

import '../export/mesh_export.dart';
import '../export/stl.dart';
import '../sketch/entities.dart';
import '../sketch/model.dart';
import '../sketch/part.dart';
import '../sketch/plane.dart';
import '../sketch/solid.dart';
import '../sketch/transform3.dart';
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

    case 'list_faces':
      return _listFaces(c, args['part']);

    case 'sketch_on_face':
      return _sketchOnFace(c, args);

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
      final centre = _point(args['center'], 'center', part);
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
        if (args['center'] != null) c.moveCircle(di, _point(args['center'], 'center', part));
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
      final to = _point(args['to'], 'to', part);
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

// --- faces --------------------------------------------------------------------
//
// A host addresses a face of a BODY in the body's own terms, not by the solid's
// face index (which shifts when a hole is drilled): "top", "bottom", or the
// side along profile edge i. Each has a 2D frame the host sketches in:
//
//   top, bottom   the body's own XY, so a boss at [20, 10] sits over the
//                 profile's [20, 10]
//   side          origin at the middle of the face; x runs along the face,
//                 y runs up the body's thickness

class _Face {
  _Face(this.label, this.plane, this.outline, this.width, this.height);
  final String label;
  final SketchPlane plane;
  final List<Offset> outline; // in the plane's own 2D coordinates
  final double width, height;
}

Part _body(SketchController c, Object? ref) {
  // With no part named, the body in play: the active part, or the body the
  // active feature sits on (a feature just added is the active part).
  final part = ref == null ? c.active.root : _resolvePart(c, ref);
  if (part.referenceLoop != null) {
    throw HostCommandException(
        '"${part.name}" is itself a feature on "${part.root.name}". Sketch on a face of the body, "${part.root.name}".');
  }
  if (part.importedSolid != null || part.profileWithHoles() == null) {
    throw HostCommandException(
        '"${part.name}" has no closed profile yet, so it has no faces to sketch on.');
  }
  return part;
}

_Face _face(Part body, Object? ref) {
  final outer = body.profileWithHoles()!.outer; // sketch coords (Y down)
  if (ref == 'top') {
    return _Face(
        'top',
        SketchPlane(Vec3(0, 0, body.depth), const Vec3(1, 0, 0), const Vec3(0, 1, 0)),
        outer,
        0,
        0);
  }
  if (ref == 'bottom') {
    // v reversed so the normal u × v points down, out of the body.
    return _Face(
        'bottom',
        const SketchPlane(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, -1, 0)),
        [for (final p in outer) Offset(p.dx, -p.dy)],
        0,
        0);
  }
  final edge = ref is Map ? ref['edge'] : null;
  if (edge == null) {
    throw const HostCommandException(
        'face must be "top", "bottom", or {"edge": i} for the side along profile edge i (see list_faces).');
  }
  final loop = _loop(body);
  final i = _index(edge, loop.length, 'edge');
  final s = body.sketch;
  final si = _edgeSegment(body, loop, i);
  if (s.segments[si].isArc) {
    throw HostCommandException(
        'Edge $i is an arc, so its side is curved. Sketch on a flat side (see list_faces).');
  }
  final a = s.points[loop[i]], b = s.points[loop[(i + 1) % loop.length]];
  final along = (b - a) / (b - a).distance;
  // The side's outward normal: perpendicular to the edge, away from the inside.
  var n = Offset(along.dy, -along.dx);
  final mid = (a + b) / 2;
  if (_inside(outer, mid + n * 1e-3)) n = -n;
  final normal = Vec3(n.dx, n.dy, 0);
  // v points DOWN the thickness so the Y-down sketch reads Y-up, like every
  // other sketch; u = v × n makes u × v the outward normal.
  const v = Vec3(0, 0, -1);
  final u = cross(v, normal);
  final w = (b - a).distance, h = body.depth;
  return _Face(
      'edge $i',
      SketchPlane(Vec3(mid.dx, mid.dy, h / 2), u, v),
      [
        Offset(-w / 2, -h / 2),
        Offset(w / 2, -h / 2),
        Offset(w / 2, h / 2),
        Offset(-w / 2, h / 2),
      ],
      w,
      h);
}

/// A world vector in host terms (Y up: the canvas's Y is the mirror).
List<num> _cad(Vec3 w) => [_round(w.x), _round(-w.y + 0.0), _round(w.z)];

Map<String, dynamic> _listFaces(SketchController c, Object? ref) {
  final body = _body(c, ref);
  final faces = <Map<String, dynamic>>[
    {
      'face': 'top',
      'at': 'z = ${_fmt(body.depth)}',
      'coordinates': "the part's own x, y",
    },
    {
      'face': 'bottom',
      'at': 'z = 0',
      'coordinates': "the part's own x, y",
    },
  ];
  final loop = body.sketch.closedLoop();
  if (loop != null) {
    for (var i = 0; i < loop.length; i++) {
      final si = _edgeSegment(body, loop, i);
      if (body.sketch.segments[si].isArc) continue;
      final f = _face(body, {'edge': i});
      faces.add({
        'face': {'edge': i},
        'center': _cad(f.plane.origin),
        'normal': _cad(f.plane.normal),
        'width': _round(f.width),
        'height': _round(f.height),
        'coordinates':
            'origin at the face centre; x along ${_cad(f.plane.u)} from ${_fmt(-f.width / 2)} to ${_fmt(f.width / 2)}, y up the thickness from ${_fmt(-f.height / 2)} to ${_fmt(f.height / 2)}',
      });
    }
  }
  return {
    'did': 'Faces of "${body.name}" you can sketch on.',
    'part': {'name': body.name, 'depth': _round(body.depth), 'faces': faces},
  };
}

Map<String, dynamic> _sketchOnFace(SketchController c, Map<String, dynamic> args) {
  final body = _body(c, args['part']);
  final face = _face(body, args['face']);
  final operation = switch (args['operation']) {
    'boss' || 'union' => FeatureOp.union,
    'cut' || 'pocket' || 'difference' => FeatureOp.difference,
    _ => throw const HostCommandException(
        'operation must be "boss" (add material) or "cut" (remove it).'),
  };
  // The shape is a part spec without a name of its own choosing: a profile,
  // a rect, or a circle, in the face's coordinates.
  final rect = args['rect'];
  Object? profile = args['profile'];
  if (rect is List && rect.length == 4 && rect.every((n) => n is num)) {
    final w = (rect[0] as num) / 2, h = (rect[1] as num) / 2;
    final cx = rect[2] as num, cy = rect[3] as num;
    profile = [
      [cx - w, cy - h],
      [cx + w, cy - h],
      [cx + w, cy + h],
      [cx - w, cy + h],
    ];
  } else if (rect != null) {
    throw const HostCommandException('rect must be [width, height, cx, cy].');
  }
  final base = (args['name'] ?? (operation == FeatureOp.union ? 'boss' : 'cut'))
      .toString()
      .trim();
  var name = base.isEmpty ? 'feature' : base;
  for (var n = 2; c.parts.any((p) => p.name == name); n++) {
    name = '$base $n';
  }
  final spec = PartSpec.fromJson({
    'name': name,
    'depth': args['depth'],
    'profile': ?profile,
    'circle': args['circle'],
  });

  final part = Part(name)
    ..plane = face.plane
    ..parent = body
    ..operation = operation
    ..depth = spec.depth
    ..referenceLoop = face.outline;
  final flip = sketchFlipsY(part);
  Offset m(Offset p) => Offset(p.dx, flip ? -p.dy : p.dy);
  if (spec.profile.isNotEmpty) {
    final pts = [for (final p in spec.tessellatedProfile()) m(p)];
    part.sketch.addImportedLines([
      for (var i = 0; i < pts.length; i++) (pts[i], pts[(i + 1) % pts.length]),
    ]);
    // Axis-aligned edges keep their direction when a dimension is driven.
    final s = part.sketch;
    for (var i = 0; i < s.segments.length; i++) {
      final d = s.points[s.segments[i].b] - s.points[s.segments[i].a];
      final tolerance = 1e-9 * (d.distance + 1);
      if (d.dy.abs() <= tolerance) {
        s.constraints.add(SketchConstraint(ConstraintKind.horizontal, [i]));
      } else if (d.dx.abs() <= tolerance) {
        s.constraints.add(SketchConstraint(ConstraintKind.vertical, [i]));
      }
    }
  } else {
    final circle = spec.circle!;
    part.decorations.add(CircleEntity(m(Offset(circle[0], circle[1])), circle[2]));
  }
  c.importParts([part]);

  // Does it actually touch the face? A shape wholly off it is almost always a
  // coordinate mistake, and nothing in the picture would say so.
  final outline = part.profileWithHoles()?.outer ?? const <Offset>[];
  String? warning;
  if (outline.isNotEmpty) {
    final centre = outline.reduce((a, b) => a + b) / outline.length.toDouble();
    if (!_inside(face.outline, centre)) {
      warning =
          'The shape is centred off the ${face.label} face of "${body.name}". Check the coordinates against list_faces.';
    }
  }
  return {
    'did':
        '${operation == FeatureOp.union ? 'Added a boss' : 'Cut a pocket'} "$name", ${_fmt(spec.depth)} mm, on the ${face.label} face of "${body.name}".',
    'warning': ?warning,
    'part': partDetailJson(part),
  };
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

/// A model point `[x, y]` (mm, Y up) as an offset in [part]'s sketch (Y down,
/// except on a bottom face: see [sketchFlipsY]).
Offset _point(Object? v, String what, Part part) {
  if (v is List &&
      v.length == 2 &&
      v.every((n) => n is num && n.isFinite && n.abs() <= 1e6)) {
    final y = (v[1] as num).toDouble();
    return Offset((v[0] as num).toDouble(), sketchFlipsY(part) ? -y : y);
  }
  throw HostCommandException('$what must be [x, y] in millimetres.');
}

num _round(double v) {
  final r = (v * 1000).round() / 1000;
  return r == r.roundToDouble() ? r.round() : r;
}

String _fmt(double v) => _round(v).toString();
