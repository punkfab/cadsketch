import 'dart:typed_data';

import '../sketch/solid.dart';
import '../sketch/transform3.dart';

// Binary STL export. Pure Dart (no Flutter, no FFI) so it runs on every platform
// and is unit-testable; a platform facade delivers the bytes to the user.

/// Fan-triangulates a solid's faces into triangles (3D point triples), each
/// optionally transformed.
List<List<Vec3>> solidTriangles(Solid s, {Transform3? transform}) {
  final tris = <List<Vec3>>[];
  Vec3 place(int vi) =>
      transform == null ? s.vertices[vi] : transform.apply(s.vertices[vi]);
  for (final face in s.faces) {
    for (var i = 1; i + 1 < face.length; i++) {
      tris.add([place(face[0]), place(face[i]), place(face[i + 1])]);
    }
  }
  return tris;
}

/// Binary STL bytes from raw triangles (used by the holed-extrude mesh, which
/// isn't a [Solid]). Each facet's normal is computed from its winding.
Uint8List trianglesToStlBytes(List<List<Vec3>> tris) {
  final bytes = ByteData(84 + tris.length * 50);
  bytes.setUint32(80, tris.length, Endian.little);
  var off = 84;
  void f32(double v) {
    bytes.setFloat32(off, v, Endian.little);
    off += 4;
  }

  for (final t in tris) {
    final n = cross(t[1] - t[0], t[2] - t[0]).normalized;
    f32(n.x);
    f32(n.y);
    f32(n.z);
    for (final v in t) {
      f32(v.x);
      f32(v.y);
      f32(v.z);
    }
    off += 2; // attribute byte count
  }
  return bytes.buffer.asUint8List();
}

/// Binary STL for [solids], each optionally placed by [transforms] (assembly).
Uint8List solidsToStlBytes(List<Solid> solids, {List<Transform3>? transforms}) {
  final tris = <List<Vec3>>[];
  for (var si = 0; si < solids.length; si++) {
    final xf =
        (transforms != null && si < transforms.length) ? transforms[si] : null;
    tris.addAll(solidTriangles(solids[si], transform: xf));
  }
  return trianglesToStlBytes(tris);
}

/// Convenience for a single solid.
Uint8List solidToStlBytes(Solid solid) => solidsToStlBytes([solid]);
