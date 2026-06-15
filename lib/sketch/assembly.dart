import 'part.dart';
import 'solid.dart';
import 'transform3.dart';

// Assembly = parts + mates. A "fasten" mate makes two connectors coincident
// with opposed normals (faces meet flush). We solve placement in closed form:
// part 0 is grounded; each other part is positioned by a mate to an
// already-placed part. This is the harness path — a full 6-DOF nonlinear mate
// solver (and over-constrained assemblies) is deferred to the native build.

/// A fasten mate between connector [connectorA] on [partA] and [connectorB] on
/// [partB] (indices into the parts list and each part's connector list).
class Mate {
  Mate(this.partA, this.connectorA, this.partB, this.connectorB);
  final int partA;
  final int connectorA;
  final int partB;
  final int connectorB;
}

/// Computes each part's world transform. Part 0 is grounded at identity; parts
/// reachable through mates are placed against already-placed parts; any leftover
/// parts are offset along X so they stay visible.
Map<int, Transform3> solveAssembly(List<Part> parts, List<Mate> mates) {
  final transforms = <int, Transform3>{0: Transform3.identity};

  bool valid(int part, int connector) =>
      part >= 0 &&
      part < parts.length &&
      connector >= 0 &&
      connector < parts[part].connectors.length &&
      parts[part].buildSolid() != null;

  var changed = true;
  while (changed) {
    changed = false;
    for (final mate in mates) {
      if (!valid(mate.partA, mate.connectorA) ||
          !valid(mate.partB, mate.connectorB)) {
        continue; // orphaned mate (part cleared/edited) — skip safely
      }
      final aPlaced = transforms.containsKey(mate.partA);
      final bPlaced = transforms.containsKey(mate.partB);
      if (aPlaced && !bPlaced) {
        transforms[mate.partB] = _place(
            parts, transforms[mate.partA]!, mate.partA, mate.connectorA, mate.partB, mate.connectorB);
        changed = true;
      } else if (bPlaced && !aPlaced) {
        transforms[mate.partA] = _place(
            parts, transforms[mate.partB]!, mate.partB, mate.connectorB, mate.partA, mate.connectorA);
        changed = true;
      }
    }
  }

  // Park any unplaced parts side by side so they remain visible.
  var offset = 1;
  for (var i = 0; i < parts.length; i++) {
    if (!transforms.containsKey(i)) {
      final s = parts[i].buildSolid();
      final span = s == null ? 200.0 : s.boundingRadius * 2.5;
      transforms[i] = Transform3.translation(Vec3(offset * span, 0, 0));
      offset++;
    }
  }
  return transforms;
}

/// Places [movePart] so its connector frame meets the fixed connector frame on
/// [fixedPart] (already at [fixedXform]) with coincident origins and opposed
/// normals.
Transform3 _place(List<Part> parts, Transform3 fixedXform, int fixedPart,
    int fixedConnector, int movePart, int moveConnector) {
  final fixedSolid = parts[fixedPart].buildSolid()!;
  final fc = parts[fixedPart].connectors[fixedConnector];
  final worldOrigin = fixedXform.apply(fc.origin(fixedSolid));
  final worldNormal = fixedXform.rot.apply(fc.normal(fixedSolid)).normalized;

  final moveSolid = parts[movePart].buildSolid()!;
  final mc = parts[movePart].connectors[moveConnector];
  final localOrigin = mc.origin(moveSolid);
  final localNormal = mc.normal(moveSolid);

  // Rotate so the moving normal opposes the fixed normal (faces meet).
  final rot = rotationFromTo(localNormal, worldNormal * -1);
  // Translate so the moving origin lands on the fixed origin.
  final t = worldOrigin - rot.apply(localOrigin);
  return Transform3(rot, t);
}
