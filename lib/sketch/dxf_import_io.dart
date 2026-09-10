import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

/// Reads a DXF: from [path] when given (desktop CLI / tests), otherwise via
/// the native document picker (#11 — the old "type a path" prompt was a dead
/// end on iOS, where there's no path a user can type). Returns null if the
/// picker was cancelled.
Future<({String name, String text})?> readDxf({String? path}) async {
  var p = path?.trim();
  if (p == null || p.isEmpty) {
    final res = await FilePicker.pickFiles(
        type: FileType.custom, allowedExtensions: ['dxf'], withData: true);
    if (res == null || res.files.isEmpty) return null;
    final f = res.files.single;
    final bytes = f.bytes;
    if (bytes != null) {
      return (name: f.name, text: utf8.decode(bytes, allowMalformed: true));
    }
    p = f.path;
    if (p == null) return null;
  }
  final file = File(p);
  if (!file.existsSync()) throw ArgumentError('File not found: $p');
  return (
    name: p.split(Platform.pathSeparator).last,
    text: await file.readAsString()
  );
}
