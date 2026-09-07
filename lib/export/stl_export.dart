// Delivers STL bytes to the user, per platform: a browser download on web, a
// written file on desktop. (iPad share via a plugin is a follow-up.)
export 'stl_export_io.dart' if (dart.library.js_interop) 'stl_export_web.dart';
