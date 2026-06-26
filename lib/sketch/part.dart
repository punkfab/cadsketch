import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'entities.dart';
import 'model.dart';
import 'plane.dart';
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

  /// The plane this part's sketch lives on (its 2D coords map into the shared
  /// 3D scene through this frame). Defaults to base XY; set to a body face's
  /// frame for in-context "sketch on a face" / multi-plane construction.
  SketchPlane plane = SketchPlane.xy;

  /// For a "sketch on a face" part: the parent face's outline in this plane's
  /// local 2D coords. Drawn as a guide and used to center the 2D canvas on the
  /// face, so drawn geometry lands on the face (not flung off by absolute
  /// canvas pixel coordinates). Null for base-plane sketches.
  List<Offset>? referenceLoop;

  /// Non-parametric strokes (circles, arcs, scribbles) shown for context.
  final List<SketchEntity> decorations = [];

  /// Extrude depth used when building the solid.
  double depth = 100;

  /// Per-region extrude-depth overrides for this part's region-partition
  /// decomposition (region index -> depth). Set when drilling into a region;
  /// geometry still rebuilds from the sketch, so this stays associative.
  final Map<int, double> regionDepths = {};

  final List<MateConnector> connectors = [];

  /// An imported mesh (STL/OBJ). When set, this is the part's geometry directly
  /// (no sketch/extrude). True STEP import arrives via OCCT in the native build,
  /// flowing into this same field.
  Solid? importedSolid;

  /// Builds the part's solid: an imported mesh if present, otherwise the
  /// extruded closed profile (prism) or a circle (cylinder).
  Solid? buildSolid() {
    if (importedSolid != null) return importedSolid;
    // Closed contour (lines and/or arcs, arcs tessellated).
    final profile = sketch.closedProfile();
    if (profile != null && profile.length >= 3) {
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
