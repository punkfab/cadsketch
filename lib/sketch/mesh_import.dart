import 'dart:io';
import 'dart:typed_data';

import 'solid.dart';

// Pure-Dart mesh import (STL binary/ASCII, OBJ) -> Solid. This is the harness
// path for "use external geometry as a part" without OCCT. True STEP/B-rep
// import comes via OpenCASCADE in the native build, behind this same Solid.
//
// Convert STEP -> STL/OBJ with FreeCAD or an online converter meanwhile.

class MeshImportException implements Exception {
  MeshImportException(this.message);
  final String message;
  @override
  String toString() => 'MeshImportException: $message';
}

/// Reads a mesh file (.stl or .obj) and returns a Solid (vertices/edges/faces).
Solid importMeshFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw MeshImportException('File not found: $path');
  }
  final lower = path.toLowerCase();
  if (lower.endsWith('.obj')) {
    return _parseObj(file.readAsStringSync());
  }
  if (lower.endsWith('.stl')) {
    final bytes = file.readAsBytesSync();
    return _looksBinaryStl(bytes)
        ? _parseBinaryStl(bytes)
        : _parseAsciiStl(String.fromCharCodes(bytes));
  }
  throw MeshImportException('Unsupported format (use .stl or .obj): $path');
}

/// Binary STL is exactly 84 + 50*triangleCount bytes.
bool _looksBinaryStl(Uint8List bytes) {
  if (bytes.length < 84) return false;
  final count = ByteData.sublistView(bytes).getUint32(80, Endian.little);
  return bytes.length == 84 + count * 50;
}

Solid _parseBinaryStl(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  final count = bd.getUint32(80, Endian.little);
  final b = _SolidBuilder();
  var off = 84;
  Vec3 readVec() {
    final v = Vec3(bd.getFloat32(off, Endian.little),
        bd.getFloat32(off + 4, Endian.little), bd.getFloat32(off + 8, Endian.little));
    off += 12;
    return v;
  }

  for (var i = 0; i < count; i++) {
    off += 12; // skip normal
    final a = readVec(), c = readVec(), d = readVec();
    b.addFace([a, c, d]);
    off += 2; // attribute byte count
  }
  return b.build();
}

Solid _parseAsciiStl(String text) {
  final b = _SolidBuilder();
  final verts = <Vec3>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('vertex')) {
      final p = line.split(RegExp(r'\s+'));
      verts.add(Vec3(double.parse(p[1]), double.parse(p[2]), double.parse(p[3])));
      if (verts.length == 3) {
        b.addFace(List.of(verts));
        verts.clear();
      }
    }
  }
  return b.build();
}

Solid _parseObj(String text) {
  final b = _SolidBuilder();
  final verts = <Vec3>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('v ')) {
      final p = line.split(RegExp(r'\s+'));
      verts.add(Vec3(double.parse(p[1]), double.parse(p[2]), double.parse(p[3])));
    } else if (line.startsWith('f ')) {
      final p = line.split(RegExp(r'\s+'));
      final ring = <Vec3>[];
      for (var i = 1; i < p.length; i++) {
        // tokens like "12", "12/3", "12/3/4", "12//4" -> take the vertex index
        final idx = int.parse(p[i].split('/').first);
        ring.add(verts[idx > 0 ? idx - 1 : verts.length + idx]); // 1-based / negative
      }
      if (ring.length >= 3) b.addFace(ring);
    }
  }
  return b.build();
}

/// Builds a Solid from faces, deduplicating coincident vertices and edges.
class _SolidBuilder {
  final List<Vec3> _verts = [];
  final Map<String, int> _index = {};
  final List<List<int>> _faces = [];
  final Set<String> _edgeKeys = {};
  final List<List<int>> _edges = [];

  int _vertex(Vec3 v) {
    final key = '${v.x.toStringAsFixed(4)},${v.y.toStringAsFixed(4)},${v.z.toStringAsFixed(4)}';
    return _index.putIfAbsent(key, () {
      _verts.add(v);
      return _verts.length - 1;
    });
  }

  void _edge(int a, int b) {
    if (a == b) return;
    final key = a < b ? '${a}_$b' : '${b}_$a';
    if (_edgeKeys.add(key)) _edges.add([a, b]);
  }

  void addFace(List<Vec3> ring) {
    final ids = [for (final v in ring) _vertex(v)];
    _faces.add(ids);
    for (var i = 0; i < ids.length; i++) {
      _edge(ids[i], ids[(i + 1) % ids.length]);
    }
  }

  Solid build() {
    if (_verts.length < 3 || _faces.isEmpty) {
      throw MeshImportException('No usable geometry found in file');
    }
    return Solid(_verts, _edges, _faces);
  }
}
