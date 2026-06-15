import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'entities.dart';
import 'model.dart';
import 'solid.dart';

/// Segments used to tessellate a circle into an extrudable profile (cylinder).
const int _kCircleFacets = 48;

// A Part is one unit of the assembly: a 2D parametric profile, an extrude
// depth, the solid that produces, and any mate connectors placed on its faces.
// Multiple parts live on the canvas at once (M4 assembly UX); the controller
// tracks which one is active for editing.

/// A mate connector references a face of the part's solid. Its origin/normal
/// are computed live from the solid, so they track depth/dimension edits.
class MateConnector {
  MateConnector(this.faceIndex);
  final int faceIndex;

  Vec3 origin(Solid s) => s.faceCentroid(faceIndex);
  Vec3 normal(Solid s) => s.faceNormal(faceIndex);
}

class Part {
  Part(this.name);
  final String name;

  final ParametricSketch sketch = ParametricSketch();

  /// Non-parametric strokes (circles, arcs, scribbles) shown for context.
  final List<SketchEntity> decorations = [];

  /// Extrude depth used when building the solid.
  double depth = 100;

  final List<MateConnector> connectors = [];

  /// Builds the extruded solid from a closed profile, or null if there isn't
  /// one. A polygon loop extrudes to a prism; a circle extrudes to a cylinder
  /// (tessellated into a profile).
  Solid? buildSolid() {
    final loop = sketch.closedLoop();
    if (loop != null) {
      final profile = <Offset>[for (final i in loop) sketch.points[i]];
      return extrudeProfile(profile, depth);
    }
    final circle = _lastCircle();
    if (circle != null) {
      return extrudeProfile(_tessellate(circle), depth);
    }
    return null;
  }

  CircleEntity? _lastCircle() {
    for (final e in decorations.reversed) {
      if (e is CircleEntity) return e;
    }
    return null;
  }

  List<Offset> _tessellate(CircleEntity c) => [
        for (var i = 0; i < _kCircleFacets; i++)
          c.center +
              Offset(math.cos(2 * math.pi * i / _kCircleFacets),
                      math.sin(2 * math.pi * i / _kCircleFacets)) *
                  c.radius,
      ];
}
