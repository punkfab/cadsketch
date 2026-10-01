import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Web: open a file picker for a .dxf and read the chosen file's text. Returns
/// null if the user cancels. [path] is ignored (there's no filesystem path on
/// the web). Must be called from a user gesture (a button tap) so the browser
/// allows the picker to open.
Future<({String name, String text})?> readDxf(
    {String? path, List<String> extensions = const ['dxf']}) {
  final input = web.document.createElement('input') as web.HTMLInputElement
    ..type = 'file'
    ..accept = extensions.map((e) => '.$e').join(',');
  final completer = Completer<({String name, String text})?>();

  input.onchange = (web.Event _) {
    final files = input.files;
    if (files == null || files.length == 0) {
      completer.complete(null);
      return;
    }
    final file = files.item(0)!;
    final reader = web.FileReader();
    reader.onload = (web.Event _) {
      final result = reader.result;
      if (result != null && result.isA<JSString>()) {
        completer.complete((name: file.name, text: (result as JSString).toDart));
      } else {
        completer.complete(null);
      }
    }.toJS;
    reader.onerror = (web.Event _) {
      completer.complete(null);
    }.toJS;
    reader.readAsText(file);
  }.toJS;

  // If the picker is dismissed without a selection, no event fires; that's fine
  // — the Future simply never completes for that discarded input, and a fresh
  // input is created next time.
  input.click();
  return completer.future;
}
