import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../export/featuretree_ir.dart';
import '../sketch/dxf.dart';
import '../sketch/part.dart';

// The part format an AI host (ChatGPT, Claude, any MCP Apps host) reads and
// writes. One shape in both directions, so a model can take what it was shown,
// change a number, and send it back:
//
//   { "name": "bracket", "depth": 5,
//     "profile": [[0,0],[40,0],[40,20],[0,20]],   // mm, Y up, closed implicitly
//     "holes":   [[8,10,2.1],[32,10,2.1]] }        // [cx, cy, r]
//
// A profile vertex may carry a third number, the DXF bulge tan(theta/4) of the
// arc leaving that vertex (positive = counter-clockwise). A round body uses
// "circle": [cx, cy, r] instead of a profile.
//
// It is deliberately the same notation as the featuretree IR (polys / circles;
// only the bulge sign differs, featuretree's being the reverse of DXF), and reading a Part back out reuses [partToIr], so the model sees exactly the
// features the FreeCAD / build123d export would produce.
//
// Pure Dart (no Flutter widgets, no FFI, no web): runs in `flutter test` and on
// every target the app ships to.

/// Thrown when a spec from the host is malformed. The message is safe to show.
class PartSpecException implements Exception {
  const PartSpecException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PartSpec {
  PartSpec({
    required this.name,
    required this.depth,
    this.profile = const [],
    this.circle,
    this.holes = const [],
  });

  final String name;
  final double depth;

  /// Outer profile vertices, `[x, y]` or `[x, y, bulge]`, mm, Y up.
  final List<List<double>> profile;

  /// A round body `[cx, cy, r]`, used instead of [profile].
  final List<double>? circle;

  /// Through holes `[cx, cy, r]`.
  final List<List<double>> holes;

  static const int _maxVertices = 2000;
  static const int _maxHoles = 500;

  /// Parses and validates one part. Everything from the host is untrusted.
  factory PartSpec.fromJson(Object? json) {
    if (json is! Map) throw const PartSpecException('part must be an object');
    final name = (json['name'] ?? 'Part').toString().trim();
    final depth = _num(json['depth'] ?? json['depth_mm'] ?? 10, 'depth');
    if (depth <= 0 || depth > 1e5) {
      throw const PartSpecException('depth must be between 0 and 100000 mm');
    }

    final profile = <List<double>>[];
    final rawProfile = json['profile'];
    if (rawProfile is List) {
      if (rawProfile.length > _maxVertices) {
        throw const PartSpecException('profile has too many vertices');
      }
      for (final v in rawProfile) {
        if (v is! List || v.length < 2 || v.length > 3) {
          throw const PartSpecException(
              'each profile vertex must be [x, y] or [x, y, bulge]');
        }
        profile.add([for (final c in v) _num(c, 'profile coordinate')]);
      }
    }

    List<double>? circle;
    final rawCircle = json['circle'];
    if (rawCircle is List) circle = _circle(rawCircle, 'circle');

    final holes = <List<double>>[];
    final rawHoles = json['holes'];
    if (rawHoles is List) {
      if (rawHoles.length > _maxHoles) {
        throw const PartSpecException('too many holes');
      }
      for (final h in rawHoles) {
        if (h is! List) throw const PartSpecException('each hole must be [cx, cy, r]');
        holes.add(_circle(h, 'hole'));
      }
    }

    if (profile.isNotEmpty && profile.length < 3) {
      throw const PartSpecException('profile needs at least 3 vertices');
    }
    if (profile.isEmpty && circle == null) {
      throw const PartSpecException('part needs a profile or a circle');
    }
    return PartSpec(
      name: name.isEmpty ? 'Part' : name,
      depth: depth,
      profile: profile,
      circle: profile.isEmpty ? circle : null,
      holes: holes,
    );
  }

  /// The geometry as a DXF-style drawing (Y up), ready for the controller's
  /// existing `importDxf`, which is the same faithful path a .dxf file takes.
  /// Arc edges are tessellated here, exactly as that importer does for ARCs.
  DxfDrawing toDrawing() {
    final d = DxfDrawing();
    if (profile.isNotEmpty) {
      d.polylines.add(DxfPolyline(tessellatedProfile(), true));
    } else if (circle != null) {
      d.circles.add(DxfCircle(Offset(circle![0], circle![1]), circle![2]));
    }
    for (final h in holes) {
      d.circles.add(DxfCircle(Offset(h[0], h[1]), h[2]));
    }
    return d;
  }

  /// Profile vertices with every bulged edge expanded into short chords.
  List<Offset> tessellatedProfile({double stepDegrees = 10}) {
    final pts = <Offset>[];
    for (var i = 0; i < profile.length; i++) {
      final v = profile[i];
      final w = profile[(i + 1) % profile.length];
      final p0 = Offset(v[0], v[1]);
      final p1 = Offset(w[0], w[1]);
      pts.add(p0);
      final bulge = v.length > 2 ? v[2] : 0.0;
      if (bulge.abs() < 1e-9) continue;
      final chord = p1 - p0;
      final c = chord.distance;
      if (c < 1e-9) continue;
      final theta = 4 * math.atan(bulge); // signed sweep, CCW positive (Y up)
      // Centre sits on the chord's perpendicular bisector: to the left of the
      // direction of travel for a CCW minor arc. d/tan(theta/2) carries the
      // sign for CW arcs and for major arcs on its own.
      final mid = p0 + chord / 2;
      final left = Offset(-chord.dy, chord.dx) / c;
      final centre = mid + left * ((c / 2) / math.tan(theta / 2));
      final r = (p0 - centre).distance;
      final a0 = math.atan2(p0.dy - centre.dy, p0.dx - centre.dx);
      final n = math.max(2, (theta.abs() / (stepDegrees * math.pi / 180)).ceil());
      for (var k = 1; k < n; k++) {
        final a = a0 + theta * k / n;
        pts.add(Offset(centre.dx + r * math.cos(a), centre.dy + r * math.sin(a)));
      }
    }
    return pts;
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'depth': depth,
        if (profile.isNotEmpty) 'profile': profile,
        if (circle != null) 'circle': circle,
        'holes': holes,
      };

  static double _num(Object? v, String what) {
    if (v is num && v.isFinite && v.abs() <= 1e6) return v.toDouble();
    throw PartSpecException('$what must be a finite number');
  }

  static List<double> _circle(List raw, String what) {
    if (raw.length != 3) throw PartSpecException('$what must be [cx, cy, r]');
    final c = [for (final v in raw) _num(v, what)];
    if (c[2] <= 0) throw PartSpecException('$what radius must be positive');
    return c;
  }
}

/// Parses the `parts` array of a host message.
List<PartSpec> partSpecsFromJson(Object? json) {
  if (json is! List) throw const PartSpecException('parts must be an array');
  if (json.length > 50) throw const PartSpecException('too many parts');
  return [for (final p in json) PartSpec.fromJson(p)];
}

/// One part as the model sees it. Geometry comes from [partToIr], the same
/// inference the featuretree export uses, so only real features are reported:
/// a closed profile, its extrude depth, and the circles that are actually holes.
Map<String, dynamic> partToSpecJson(Part part) {
  final ir = partToIr(part);
  final features = (ir['features'] as List).cast<Map<String, dynamic>>();

  List<dynamic>? profile;
  List<dynamic>? circle;
  final holes = <dynamic>[];
  for (final f in features) {
    if (f['kind'] != 'sketch') continue;
    final name = f['name'] as String;
    final polys = f['polys'] as List;
    final circles = f['circles'] as List;
    if (name == 'profile') {
      // The host format uses the DXF bulge sign; the IR's is the reverse.
      if (polys.isNotEmpty) {
        profile = [
          for (final v in polys.first as List)
            (v as List).length > 2 ? [v[0], v[1], -(v[2] as num)] : v,
        ];
      }
      if (polys.isEmpty && circles.isNotEmpty) circle = circles.first as List;
    } else if (circles.isNotEmpty) {
      holes.add(circles.first);
    }
  }

  final s = part.sketch;
  final kinds = <String, int>{};
  for (final c in s.constraints) {
    kinds[c.kind.name] = (kinds[c.kind.name] ?? 0) + 1;
  }
  final dimensioned =
      s.segments.where((seg) => seg.drivingLength != null).length;

  return {
    'name': part.name,
    'depth': _round(part.depth),
    'closed': profile != null || circle != null,
    'profile': ?profile,
    'circle': ?circle,
    'holes': holes,
    // What the solver knows, so a model can comment on design intent.
    'segments': s.segments.length,
    'constraints': kinds,
    'dimensionedSegments': dimensioned,
    if (part.parent != null) 'featureOf': part.parent!.name,
    if (part.parent != null) 'operation': part.operation.name,
    if (part.importedSolid != null) 'importedMesh': true,
  };
}

/// The whole document as model-visible context: a structured form plus a short
/// plain-text summary (some hosts only pass text through to the model).
({Map<String, dynamic> structured, String text}) documentToModelContext(
  List<Part> parts,
  int activeIndex,
  Map<String, double> parameters,
) {
  final specs = [for (final p in parts) partToSpecJson(p)];
  final structured = <String, dynamic>{
    'app': 'CADSketch',
    'units': 'mm',
    'axes': 'x right, y up',
    'activePart': parts.isEmpty ? null : parts[activeIndex].name,
    'parts': specs,
    if (parameters.isNotEmpty)
      'parameters': {
        for (final e in parameters.entries) e.key: _round(e.value),
      },
  };

  final lines = <String>[
    'CADSketch canvas: ${specs.length} part${specs.length == 1 ? '' : 's'} (mm, Y up).',
  ];
  for (final s in specs) {
    lines.add('- ${_describe(s)}');
  }
  return (structured: structured, text: lines.join('\n'));
}

String _describe(Map<String, dynamic> s) {
  final b = StringBuffer('${s['name']}: ');
  final profile = s['profile'] as List?;
  final circle = s['circle'] as List?;
  if (profile != null) {
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final v in profile) {
      final x = (v[0] as num).toDouble(), y = (v[1] as num).toDouble();
      minX = math.min(minX, x);
      maxX = math.max(maxX, x);
      minY = math.min(minY, y);
      maxY = math.max(maxY, y);
    }
    b.write('closed profile, ${profile.length} vertices, '
        '${_round(maxX - minX)} x ${_round(maxY - minY)} mm');
  } else if (circle != null) {
    b.write('round body, diameter ${_round((circle[2] as num) * 2.0)} mm');
  } else if (s['importedMesh'] == true) {
    b.write('imported mesh');
  } else if ((s['segments'] as int) > 0) {
    b.write('OPEN sketch (${s['segments']} segments, profile not closed, '
        'so it cannot be extruded yet)');
  } else {
    b.write('empty');
  }
  if (s['closed'] == true) b.write(', extruded ${s['depth']} mm');
  final holes = s['holes'] as List;
  if (holes.isNotEmpty) {
    b.write(', ${holes.length} hole${holes.length == 1 ? '' : 's'}');
  }
  final constraints = s['constraints'] as Map;
  if (constraints.isNotEmpty) {
    b.write(', constraints: '
        '${constraints.entries.map((e) => '${e.key} x${e.value}').join(', ')}');
  }
  if ((s['dimensionedSegments'] as int) > 0) {
    b.write(', ${s['dimensionedSegments']} driving dimension(s)');
  }
  if (s['featureOf'] != null) {
    b.write(' [${s['operation']} feature on a face of ${s['featureOf']}]');
  }
  return b.toString();
}

num _round(double v) {
  final r = (v * 1000).round() / 1000;
  return r == r.roundToDouble() ? r.round() : r;
}
