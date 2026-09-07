import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/export/stl.dart';
import 'package:ai_sketcher/export/stl_export.dart';
import 'package:ai_sketcher/sketch/solid.dart';

// On the Dart VM the export facade resolves to the io implementation, which
// writes the STL to a file. (Web download is exercised in the browser.)

void main() {
  test('exportStl writes the STL bytes to a file', () async {
    final box = extrudeProfile(const [
      Offset(0, 0),
      Offset(1, 0),
      Offset(1, 1),
      Offset(0, 1),
    ], 1);
    final bytes = solidToStlBytes(box);

    final path = await exportStl('unit_box_test', bytes);
    final file = File(path);
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });

    expect(path, endsWith('.stl'));
    expect(file.existsSync(), isTrue);
    expect(file.readAsBytesSync(), bytes);
  });
}
