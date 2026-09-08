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
  MateConnector(this.faceIndex, {this.anchor});

  /// The face index at creation time. Kept as a fallback, but face indices are
  /// NOT stable across sketch edits — drilling a hole switches [Part.buildSolid]
  /// to a longer face list — so [anchor] is the durable reference.
  final int faceIndex;

  /// The face centroid captured when this connector was created, in the part's
  /// local solid space. The outer boundary doesn't move when a hole is added
  /// (holes only append faces), so re-resolving by nearest centroid keeps the
  /// mate point on the same face across edits. Null for legacy connectors.
  final Vec3? anchor;

  /// The face this connector currently maps to: nearest centroid to [anchor],
  /// so it survives face re-indexing (e.g. after a hole is drilled). Falls back
  /// to the raw [faceIndex] when there's no anchor.
  int resolvedFace(Solid s) {
    if (s.faces.isEmpty) return 0;
    final a = anchor;
    if (a == null) return faceIndex.clamp(0, s.faces.length - 1);
    return s.faceNearest(a);
  }

  Vec3 origin(Solid s) => s.faceCentroid(resolvedFace(s));

  /// The face normal, oriented OUTWARD (away from the solid's centroid). A
  /// fasten mate opposes the two normals to bring faces flush, so both must
  /// point out of their solids. Extruded caps share a profile winding, so the
  /// raw Newell normal can point inward — this corrects it.
  Vec3 normal(Solid s) {
    final f = resolvedFace(s);
    final n = s.faceNormal(f);
    final d = s.faceCentroid(f) - s.centroid; // outward direction
    final facingOut = n.x * d.x + n.y * d.y + n.z * d.z >= 0;
    return facingOut ? n : n * -1.0;
  }
}

/// An opaque deep-copy of a part's editable 2D content, used for undo/redo.
/// Produced by [Part.captureState] and consumed by [Part.restoreState].
class SketchState {
  SketchState._(this._sketch, this._decorations, this._connectors);
  final ParametricSketch _sketch;
  final List<SketchEntity> _decorations;
  final List<MateConnector> _connectors;
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

  /// The body this part is a feature ON — sketched on one of its faces. Used for
  /// in-context display: the 3D view shows a face feature together with its
  /// parent body so the containing part doesn't disappear when the feature
  /// becomes active. Null for base bodies. (An object ref, not an index, so it
  /// stays valid as parts are reordered.)
  Part? parent;

  /// The root body of this part's feature family: itself for a base body, else
  /// the base body it (transitively) sits on. Parts sharing a root are shown
  /// together in the 3D view.
  Part get root => parent?.root ?? this;

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

  /// The part's outer profile plus interior holes (a sketched inner loop or a
  /// circle decoration inside the outer boundary). The largest closed loop is
  /// the outer. Null if there's no profile (empty, or circle-only handled by
  /// [buildSolid]). Shared by [buildSolid] and STL export so the 3D view and the
  /// exported mesh agree on holes.
  ({List<Offset> outer, List<List<Offset>> holes})? profileWithHoles() {
    // Every closed region that could bound the extrude — a sketched loop OR a
    // circle decoration — is a candidate. The largest by area is the outer
    // boundary; any other whose centroid lies inside it is an interior hole.
    // (Treating circles as outer candidates too fixes e.g. a sketched triangle
    // hole inside a circle: the circle is the boundary, not the triangle.)
    final candidates = <List<Offset>>[
      ...sketch.allProfiles(),
      for (final e in decorations)
        if (e is CircleEntity) _tessellate(e),
    ]..sort((a, b) => _absArea(b).compareTo(_absArea(a)));
    if (candidates.isEmpty || candidates.first.length < 3) return null;
    final outer = candidates.first;
    final holes = <List<Offset>>[
      for (var i = 1; i < candidates.length; i++)
        if (_pointInPoly(outer, _centroid(candidates[i]))) candidates[i],
    ];
    return (outer: outer, holes: holes);
  }

  /// True when the part has at least one interior hole.
  bool get hasHoles => (profileWithHoles()?.holes.isNotEmpty) ?? false;

  /// Builds the part's solid: an imported mesh if present, otherwise the extruded
  /// profile (with any interior holes drilled through) or a circle (cylinder).
  Solid? buildSolid() {
    if (importedSolid != null) return importedSolid;
    final pw = profileWithHoles();
    if (pw != null) {
      return pw.holes.isEmpty
          ? extrudeProfile(pw.outer, depth)
          : extrudeWithHolesSolid(pw.outer, pw.holes, depth);
    }
    final circle = _lastCircle();
    if (circle != null) {
      return extrudeProfile(_tessellate(circle), depth);
    }
    return null;
  }

  /// This part's profile extruded ON ITS PLANE, with [dirSign] giving boss/pocket
  /// direction — so a face feature sits on the parent face. [buildSolid] ignores
  /// the plane (extrudes on XY), which is wrong for anything sketched on a face
  /// (a circle on a cylinder side ended up floating beside it). Holes are ignored
  /// for the wireframe. Null if there's no closed profile yet.
  Solid? solidOnPlane() {
    final pw = profileWithHoles();
    if (pw == null) return null;
    return extrudeOnPlane(pw.outer, plane, depth * dirSign);
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
    // Deliberately NOT copying mate connectors: a duplicate starts with no mate
    // points (copying them reads as phantom pins the user didn't place). Mates
    // are placed per-instance in the assembly anyway.
    return p;
  }

  /// A deep snapshot of this part's editable 2D content — sketch geometry,
  /// decorations, and mate connectors — for undo/redo.
  SketchState captureState() => SketchState._(
        sketch.clone(),
        [for (final e in decorations) _cloneEntity(e)],
        [for (final c in connectors) MateConnector(c.faceIndex, anchor: c.anchor)],
      );

  /// Restores a snapshot from [captureState], installing fresh copies so the
  /// snapshot stays pristine (a later redo restores the same state again).
  void restoreState(SketchState s) {
    final sk = s._sketch.clone();
    sketch.points
      ..clear()
      ..addAll(sk.points);
    sketch.segments
      ..clear()
      ..addAll(sk.segments);
    sketch.constraints
      ..clear()
      ..addAll(sk.constraints);
    decorations
      ..clear()
      ..addAll([for (final e in s._decorations) _cloneEntity(e)]);
    connectors
      ..clear()
      ..addAll([
        for (final c in s._connectors) MateConnector(c.faceIndex, anchor: c.anchor)
      ]);
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

double _absArea(List<Offset> p) {
  var a = 0.0;
  for (var i = 0, j = p.length - 1; i < p.length; j = i++) {
    a += (p[j].dx - p[i].dx) * (p[j].dy + p[i].dy);
  }
  return a.abs() / 2;
}

Offset _centroid(List<Offset> p) {
  var x = 0.0, y = 0.0;
  for (final o in p) {
    x += o.dx;
    y += o.dy;
  }
  return Offset(x / p.length, y / p.length);
}

bool _pointInPoly(List<Offset> poly, Offset p) {
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
