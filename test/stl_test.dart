import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/export/stl.dart';
import 'package:ai_sketcher/sketch/solid.dart';
import 'package:ai_sketcher/sketch/transform3.dart';

void main() {
  test('binary STL of a box has the right header, count, and size', () {
    final box = extrudeProfile(const [
      Offset(0, 0),
      Offset(10, 0),
      Offset(10, 10),
      Offset(0, 10),
    ], 10);

    final bytes = solidToStlBytes(box);
    // 2 caps (2 tris each) + 4 side quads (2 each) = 12 triangles.
    const tris = 12;
    expect(bytes.length, 84 + tris * 50);

    final bd = ByteData.sublistView(bytes);
    expect(bd.getUint32(80, Endian.little), tris);

    // First facet normal is a unit vector.
    final nx = bd.getFloat32(84, Endian.little);
    final ny = bd.getFloat32(88, Endian.little);
    final nz = bd.getFloat32(92, Endian.little);
    expect((nx * nx + ny * ny + nz * nz), closeTo(1.0, 1e-4));
  });

  test('transforms place each solid (assembly export)', () {
    final a = extrudeProfile(const [Offset(0, 0), Offset(1, 0), Offset(1, 1), Offset(0, 1)], 1);
    final shifted = solidsToStlBytes([a],
        transforms: [Transform3.translation(const Vec3(100, 0, 0))]);
    final bd = ByteData.sublistView(shifted);
    // Scan all vertex X coords; every one should be shifted by +100.
    var minX = double.infinity;
    final n = bd.getUint32(80, Endian.little);
    for (var t = 0; t < n; t++) {
      final base = 84 + t * 50 + 12; // skip normal (12 bytes)
      for (var v = 0; v < 3; v++) {
        final x = bd.getFloat32(base + v * 12, Endian.little);
        if (x < minX) minX = x;
      }
    }
    expect(minX, closeTo(100, 1e-4));
  });
}
