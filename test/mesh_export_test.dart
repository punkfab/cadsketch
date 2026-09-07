import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/export/mesh_export.dart';
import 'package:ai_sketcher/sketch/entities.dart';
import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/sketch/part.dart';
import 'package:ai_sketcher/sketch/solid.dart';

Part _plate(double w, double h, double depth) {
  final p = Part('plate')..depth = depth;
  final s = p.sketch;
  s.points.addAll([Offset(0, 0), Offset(w, 0), Offset(w, h), Offset(0, h)]);
  for (var i = 0; i < 4; i++) {
    s.segments.add(Segment(i, (i + 1) % 4));
  }
  return p;
}

/// Every undirected edge must be shared by exactly two triangles (watertight
/// 2-manifold) — the requirement for a valid STL a slicer will accept.
void _expectWatertight(List<List<Vec3>> tris) {
  String v(Vec3 p) =>
      '${p.x.toStringAsFixed(3)},${p.y.toStringAsFixed(3)},${p.z.toStringAsFixed(3)}';
  String edge(Vec3 a, Vec3 b) {
    final ka = v(a), kb = v(b);
    return ka.compareTo(kb) <= 0 ? '$ka|$kb' : '$kb|$ka';
  }

  final counts = <String, int>{};
  for (final t in tris) {
    for (final e in [edge(t[0], t[1]), edge(t[1], t[2]), edge(t[2], t[0])]) {
      counts.update(e, (n) => n + 1, ifAbsent: () => 1);
    }
  }
  final bad = counts.entries.where((e) => e.value != 2).map((e) => e.value).toList();
  expect(bad, isEmpty, reason: 'non-manifold edges with counts $bad');
}

void main() {
  test('a plate with a drilled hole exports a watertight mesh', () {
    final p = _plate(40, 30, 10)..decorations.add(CircleEntity(const Offset(20, 15), 6));
    final tris = partExportTriangles(p);
    expect(tris, isNotEmpty);
    _expectWatertight(tris);
  });

  test('a plate with two holes exports a watertight mesh', () {
    final p = _plate(40, 20, 8)
      ..decorations.add(CircleEntity(const Offset(12, 10), 4))
      ..decorations.add(CircleEntity(const Offset(28, 10), 4));
    _expectWatertight(partExportTriangles(p));
  });

  test('a plain plate (no holes) is still watertight', () {
    _expectWatertight(partExportTriangles(_plate(10, 10, 5)));
  });

  test('a circle outside the profile is not treated as a hole', () {
    final p = _plate(10, 10, 5)..decorations.add(CircleEntity(const Offset(50, 50), 2));
    // No hole -> just the box (12 triangles).
    expect(partExportTriangles(p).length, 12);
  });
}
