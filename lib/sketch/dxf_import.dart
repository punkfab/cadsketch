// DXF file-access facade. Parsing (dxf.dart) is pure and shared; only getting
// the file bytes differs per platform: desktop reads a path from disk, web opens
// a file picker. The UI calls [readDxf] and parses the returned text.
export 'dxf_import_io.dart' if (dart.library.js_interop) 'dxf_import_web.dart';
