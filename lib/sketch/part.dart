import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'entities.dart';
import 'model.dart';
import 'plane.dart';
import 'solid.dart';

/// Segments used to tessellate a circle into an extrudable profile (cylinder).
const int _kCircleFacets = 48;

/// How a sketch-on-face feature relates to the body it sits on. The harness has
/// no B-rep booleans yet (deferred to OCCT on native), so this doesn't compute a
/// fused/cut solid — it makes the *intent* explicit: which way the extrude goes
/// and how the feature reads (green boss vs red pocket), and it's exactly the
/// signal the featuretree bridge needs (union -> pad, difference -> pocket).
enum FeatureOp {
  /// Add material: extrude outward along the face normal.
  union,

  /// Remove material: extrude inward, into the parent body.
  difference,
}

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

  /// The face normal, oriented OUTWARD (away from the solid's centroid). A
  /// fasten mate opposes the two normals to bring faces flush, so both must
  /// point out of their solids. Extruded caps share a profile winding, so the
  /// raw Newell normal can point inward — this corrects it.
  Vec3 normal(Solid s) {
    final n = s.faceNormal(faceIndex);
    final d = s.faceCentroid(faceIndex) - s.centroid; // outward direction
    final facingOut = n.x * d.x + n.y * d.y + n.z * d.z >= 0;
    return facingOut ? n : n * -1.0;
  }
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

  /// Extrude depth (magnitude) used when building the solid. Always positive;
  /// the *direction* comes from [operation]/[flipDirection] via [dirSign].
  double depth = 100;

  /// For a face sketch, whether this feature adds or removes material. Defaults
  /// to union (a boss extruding outward) so a new face sketch never silently
  /// dives into the part. Ignored for the base master sketch (extrudes +normal).
  FeatureOp operation = FeatureOp.union;

  /// Reverses the extrude direction that [operation] implies, for the rare case
  /// where a union should go inward or a difference outward.
  bool flipDirection = false;

  /// The sign applied to [depth] when extruding: union goes +normal (out),
  /// difference goes -normal (in), and [flipDirection] negates that.
  double get dirSign =>
      (operation == FeatureOp.difference) != flipDirection ? -1.0 : 1.0;

  /// True once a direction other than "add material, outward" is in play — i.e.
  /// this feature reads as a cut. Drives the red/green rendering.
  bool get isSubtractive => dirSign < 0;

  /// When > 0, the part's surface marks (RawStroke decorations — text, freehand)
  /// are thickened into ribbons and extruded along the plane normal by this much,
  /// raising them into 3D (emboss). 0 keeps them as flat marks on the datum.
  double embossDepth = 0;

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

  /// The part's origin datum in the plane's 2D coordinates: the bounding-box
  /// centre of the sketch geometry (points + circles). This is the reference
  /// frame's origin — rendered as an axis triad in 3D and a crosshair in 2D so
  /// it's obvious where a part's origin is. Null when there's no geometry yet.
  Offset? originLocal() {
    double? minX, minY, maxX, maxY;
    void ext(double x, double y) {
      minX = (minX == null) ? x : math.min(minX!, x);
      minY = (minY == null) ? y : math.min(minY!, y);
      maxX = (maxX == null) ? x : math.max(maxX!, x);
      maxY = (maxY == null) ? y : math.max(maxY!, y);
    }

    for (final p in sketch.points) {
      ext(p.dx, p.dy);
    }
    for (final e in decorations) {
      if (e is CircleEntity) {
        ext(e.center.dx - e.radius, e.center.dy - e.radius);
        ext(e.center.dx + e.radius, e.center.dy + e.radius);
      }
    }
    if (minX == null) return null;
    return Offset((minX! + maxX!) / 2, (minY! + maxY!) / 2);
  }

  /// A deep copy of this part under [newName] — used to reuse a part more than
  /// once in an assembly. Sketch, decorations, mate connectors, and every
  /// parameter are duplicated; an imported mesh solid is shared (it's not
  /// mutated after import).
  Part clone(String newName) {
    final p = Part(newName)
      ..plane = plane
      ..depth = depth
      ..embossDepth = embossDepth
      ..operation = operation
      ..flipDirection = flipDirection
      ..referenceLoop =
          referenceLoop == null ? null : List<Offset>.from(referenceLoop!)
      ..importedSolid = importedSolid;
    final cs = sketch.clone();
    p.sketch.points.addAll(cs.points);
    p.sketch.segments.addAll(cs.segments);
    p.sketch.constraints.addAll(cs.constraints);
    p.regionDepths.addAll(regionDepths);
    for (final e in decorations) {
      p.decorations.add(_cloneEntity(e));
    }
    for (final c in connectors) {
      p.connectors.add(MateConnector(c.faceIndex));
    }
    return p;
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

/// Deep copy of a decoration entity (mutable fields — stroke points, circle
/// radius/param — are duplicated so an edit to the copy doesn't touch the
/// original).
SketchEntity _cloneEntity(SketchEntity e) => switch (e) {
      RawStroke(:final points) => RawStroke(List<Offset>.from(points)),
      LineEntity(:final a, :final b) => LineEntity(a, b),
      CircleEntity(:final center, :final radius, :final radiusParam) =>
        CircleEntity(center, radius, radiusParam: radiusParam),
      ArcEntity(:final center, :final radius, :final startAngle, :final sweepAngle) =>
        ArcEntity(center, radius, startAngle, sweepAngle),
    };
