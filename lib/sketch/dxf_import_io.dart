import 'dart:io';

import 'dxf.dart';

/// Desktop: read the DXF at [path] from disk. Returns null if no path is given
/// (the caller cancelled the path prompt).
Future<({String name, String text})?> readDxf({String? path}) async {
  final p = path?.trim();
  if (p == null || p.isEmpty) return null;
  final file = File(p);
  if (!file.existsSync()) {
    throw DxfException('File not found: $p');
  }
  return (name: p.split(Platform.pathSeparator).last, text: await file.readAsString());
}
