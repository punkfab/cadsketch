// Mesh import facade. The real importer (mesh_import_io.dart) reads files via
// dart:io; the web build can't, so it gets a stub. The rest of the app imports
// only this file.
export 'mesh_import_io.dart' if (dart.library.js_interop) 'mesh_import_web.dart';
