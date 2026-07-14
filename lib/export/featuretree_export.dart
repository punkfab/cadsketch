// featuretree export facade. The real writer (…_io.dart) serializes the IR to a
// file via dart:io; the web build can't write files, so it gets a stub. The rest
// of the app imports only this file.
export 'featuretree_export_io.dart'
    if (dart.library.js_interop) 'featuretree_export_web.dart';
