import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/mesh_import.dart';
import 'package:ai_sketcher/ui/sketch_canvas.dart';

// Tetrahedron: 4 vertices, 4 triangular faces, 6 edges.
const _a = [0.0, 0.0, 0.0];
const _b = [10.0, 0.0, 0.0];
const _c = [0.0, 10.0, 0.0];
const _d = [0.0, 0.0, 10.0];
const _tris = [
  [_a, _b, _c],
  [_a, _b, _d],
  [_a, _c, _d],
  [_b, _c, _d],
];

File _tmp(String name) =>
    File('${Directory.systemTemp.path}/aisk_$name');

void main() {
  test('ASCII STL imports to a deduplicated Solid', () {
    final sb = StringBuffer('solid t\n');
    for (final t in _tris) {
      sb.writeln(' facet normal 0 0 0\n  outer loop');
      for (final v in t) {
        sb.writeln('   vertex ${v[0]} ${v[1]} ${v[2]}');
      }
      sb.writeln('  endloop\n endfacet');
    }
    sb.writeln('endsolid t');
    final f = _tmp('ascii.stl')..writeAsStringSync(sb.toString());

    final s = importMeshFile(f.path);
    expect(s.vertices.length, 4); // deduped across shared triangle corners
    expect(s.faces.length, 4);
    expect(s.edges.length, 6);
    f.deleteSync();
  });

  test('binary STL imports', () {
    final bd = ByteData(84 + 50 * _tris.length);
    bd.setUint32(80, _tris.length, Endian.little);
    var off = 84;
    for (final t in _tris) {
      off += 12; // normal (zero)
      for (final v in t) {
        bd.setFloat32(off, v[0], Endian.little);
        bd.setFloat32(off + 4, v[1], Endian.little);
        bd.setFloat32(off + 8, v[2], Endian.little);
        off += 12;
      }
      off += 2; // attribute
    }
    final f = _tmp('bin.stl')..writeAsBytesSync(bd.buffer.asUint8List());

    final s = importMeshFile(f.path);
    expect(s.vertices.length, 4);
    expect(s.faces.length, 4);
    f.deleteSync();
  });

  test('OBJ imports (1-based faces, v/vt/vn tokens)', () {
    const obj = '''
v 0 0 0
v 10 0 0
v 0 10 0
v 0 0 10
f 1 2 3
f 1//1 2//1 4//1
f 1 3 4
f 2 3 4
''';
    final f = _tmp('m.obj')..writeAsStringSync(obj);
    final s = importMeshFile(f.path);
    expect(s.vertices.length, 4);
    expect(s.faces.length, 4);
    f.deleteSync();
  });

  test('imported mesh becomes an active part with that geometry', () {
    final f = _tmp('p.obj')
      ..writeAsStringSync('v 0 0 0\nv 10 0 0\nv 0 10 0\nf 1 2 3\n');
    final c = SketchController();
    final before = c.parts.length;
    c.importSolid('p.obj', importMeshFile(f.path));
    expect(c.parts.length, before + 1);
    expect(c.active.buildSolid(), isNotNull);
    expect(c.active.buildSolid()!.vertices.length, 3);
    f.deleteSync();
  });

  test('bad file throws MeshImportException', () {
    expect(() => importMeshFile('/no/such/file.stl'),
        throwsA(isA<MeshImportException>()));
  });
}
