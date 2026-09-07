import 'dart:io';
import 'dart:typed_data';

/// Desktop/dev delivery: write the STL to `$AI_SKETCHER_STL_OUT` (or a temp
/// dir) and return the path. Returns the written file path.
Future<String> exportStl(String name, Uint8List bytes) async {
  final dir = Directory(Platform.environment['AI_SKETCHER_STL_OUT'] ??
      '${Directory.systemTemp.path}/cadsketch_stl')
    ..createSync(recursive: true);
  final file = File('${dir.path}/$name.stl');
  await file.writeAsBytes(bytes);
  return file.path;
}
