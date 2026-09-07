import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Web delivery: hand the browser a Blob and click a download link. Returns the
/// downloaded file name.
Future<String> exportStl(String name, Uint8List bytes) async {
  final fileName = '$name.stl';
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'model/stl'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = fileName;
  anchor.click();
  web.URL.revokeObjectURL(url);
  return fileName;
}
