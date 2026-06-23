import 'model.dart';
import 'plane.dart';
import 'regions.dart';
import 'solid.dart';

// Top-down region-partition decomposition: a master sketch with internal
// dividers is split into one part per enclosed region, extruded in place. The
// shared edge between adjacent regions becomes a coincident side face on each —
// an auto-captured mating surface (a connector pair + fasten mate), no manual
// step. Parts start coincident ("in place"); an explode factor offsets them
// radially so the decomposition is legible.
//
// This is a PURE function of the live sketch (+ plane + depth). Nothing derived
// is stored, so editing the master sketch or a shared parameter and rebuilding
// reflows every part — associativity without a dependency engine.

class DecomposedPart {
  DecomposedPart(this.name, this.solid, this.center);
  final String name;
  final Solid solid; // in-place, master/world coordinates
  final Vec3 center; // solid centroid, for explode direction
}

/// An auto-captured mate: the shared face [faceA] on [partA] meets [faceB] on
/// [partB] (coincident, opposed normals). Faces index into the parts' solids.
class DerivedMate {
  DerivedMate(this.partA, this.faceA, this.partB, this.faceB);
  final int partA, faceA, partB, faceB;
}

class Decomposition {
  Decomposition(this.parts, this.mates, this.center, this.radius);
  final List<DecomposedPart> parts;
  final List<DerivedMate> mates;
  final Vec3 center; // assembly centroid (camera target)
  final double radius; // assembly bounding radius (auto-fit + explode scale)

  bool get isEmpty => parts.isEmpty;

  /// Explode displacement for [part] at factor [t] (0 = assembled): radial from
  /// the assembly center, scaled by the overall size so parts clear each other.
  Vec3 explodeOffset(int part, double t) {
    if (t <= 0) return const Vec3(0, 0, 0);
    final dir = parts[part].center - center;
    final d = dir.length;
    final unit = d < 1e-6 ? const Vec3(0, 0, 1) : dir * (1 / d);
    return unit * (t * radius * 1.4);
  }
}

/// Decomposes [sketch] into in-place extruded region parts with auto-mates.
/// [names] optionally overrides the default "Part N" labels per region index.
/// [depthOverrides] gives a per-region extrude depth (region index -> depth),
/// falling back to [depth] — this is how an in-context part edit (drill in,
/// change its thickness) stays associative: the divider faces still coincide
/// regardless of depth, so the auto-mates survive.
Decomposition decompose(
  ParametricSketch sketch, {
  required double depth,
  SketchPlane plane = SketchPlane.xy,
  Map<int, String>? names,
  Map<int, double>? depthOverrides,
}) {
  final set = findRegions(sketch);
  if (set.regions.isEmpty) {
    return Decomposition(const [], const [], const Vec3(0, 0, 0), 1);
  }

  final parts = <DecomposedPart>[];
  for (var i = 0; i < set.regions.length; i++) {
    final d = depthOverrides?[i] ?? depth;
    final solid = extrudeOnPlane(set.regions[i].profile, plane, d);
    parts.add(DecomposedPart(
        names?[i] ?? 'Part ${i + 1}', solid, solid.centroid));
  }

  // Auto-mates: each shared divider edge -> the side face it became on each
  // adjacent region's prism (side face index = 2 + the edge's profile index).
  final mates = <DerivedMate>[];
  for (final a in set.adjacencies) {
    final fa = _sideFace(set.regions[a.regionA], a.pa, a.pb);
    final fb = _sideFace(set.regions[a.regionB], a.pa, a.pb);
    if (fa != null && fb != null) {
      mates.add(DerivedMate(a.regionA, fa, a.regionB, fb));
    }
  }

  // Assembly bounds (over all in-place solids) for camera fit + explode scale.
  var c = const Vec3(0, 0, 0);
  for (final p in parts) {
    c = c + p.center;
  }
  c = c * (1.0 / parts.length);
  var r = 1.0;
  for (final p in parts) {
    for (final v in p.solid.vertices) {
      final d = (v - c).length;
      if (d > r) r = d;
    }
  }
  return Decomposition(parts, mates, c, r);
}

/// Side-face index of the prism for the profile edge whose endpoints are the
/// (point-index) pair [pa]/[pb]. Side faces are 2 + profile-edge-index (see
/// [extrudeOnPlane]). Returns null if the edge isn't a straight profile edge
/// (e.g. it was tessellated as an arc) — those don't form a flat mate face.
int? _sideFace(Region region, int pa, int pb) {
  final src = region.profileSource;
  final n = src.length;
  for (var i = 0; i < n; i++) {
    final a = src[i];
    final b = src[(i + 1) % n];
    if ((a == pa && b == pb) || (a == pb && b == pa)) return 2 + i;
  }
  return null;
}
