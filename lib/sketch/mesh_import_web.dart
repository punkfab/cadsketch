import 'solid.dart';

/// Web stub for mesh import. The real importer (mesh_import_io.dart) reads a
/// file from disk via dart:io, which the web platform doesn't provide. The
/// desktop harness handles imports; on web this throws a clear message.
class MeshImportException implements Exception {
  MeshImportException(this.message);
  final String message;
  @override
  String toString() => 'MeshImportException: $message';
}

Solid importMeshFile(String path) => throw MeshImportException(
    'Mesh import runs in the desktop harness only (it reads from disk).');
