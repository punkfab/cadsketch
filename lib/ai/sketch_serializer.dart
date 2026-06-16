import '../sketch/entities.dart';
import '../sketch/model.dart';
import '../sketch/part.dart';

// Turns a Part's parametric sketch into a compact JSON-able map for the AI
// assistant (M5). Kept frontend-agnostic and deliberately small: coordinates
// rounded to whole pixels, only the fields the model needs to reason about
// constraints and design rules. This is the contract the AI "sees".

Map<String, dynamic> sketchToJson(
  Part part,
  Map<String, double> parameters,
) {
  final m = part.sketch;
  return {
    'part': part.name,
    'depth': _r(part.depth),
    'points': [
      for (final p in m.points) [_r(p.dx), _r(p.dy)],
    ],
    'segments': [
      for (var i = 0; i < m.segments.length; i++) _segment(m, i),
    ],
    'constraints': [
      for (final c in m.constraints)
        {'kind': c.kind.name, 'segments': c.segments},
    ],
    'circles': [
      for (final e in part.decorations)
        if (e is CircleEntity)
          {
            'center': [_r(e.center.dx), _r(e.center.dy)],
            'radius': _r(e.radius),
            if (e.radiusParam != null) 'param': e.radiusParam,
          },
    ],
    'parameters': {
      for (final entry in parameters.entries) entry.key: _r(entry.value),
    },
  };
}

Map<String, dynamic> _segment(ParametricSketch m, int i) {
  final s = m.segments[i];
  final json = <String, dynamic>{
    'a': s.a,
    'b': s.b,
    'kind': s.isArc ? 'arc' : 'line',
    'length': _r(m.measuredLength(i)),
  };
  if (s.drivingLength != null) json['drivingLength'] = _r(s.drivingLength!);
  if (s.lengthParam != null) json['lengthParam'] = s.lengthParam;
  final arc = s.arc;
  if (arc != null) {
    json['arc'] = {
      'center': [_r(arc.center.dx), _r(arc.center.dy)],
      'radius': _r(arc.radius),
      'sweep': double.parse(arc.sweep.toStringAsFixed(3)),
    };
  }
  return json;
}

double _r(double v) => double.parse(v.toStringAsFixed(1));
