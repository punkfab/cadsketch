import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Delivers the STL, per platform. Returns a user-facing "where it went".
///
/// Mobile (#10): the sandbox tmp dir is unreachable from the Files app and
/// purgeable by iOS, so the file goes to the app's Documents folder — visible
/// at Files → On My iPad → CADSketch (the file-sharing plist keys) — and the
/// share sheet opens so it can be AirDropped / saved / sent to a slicer.
///
/// Desktop/dev: write to `$AI_SKETCHER_STL_OUT` (or a temp dir) and return the
/// path.
Future<String> exportStl(String name, Uint8List bytes) async {
  if (Platform.isIOS || Platform.isAndroid) {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$name.stl');
    await file.writeAsBytes(bytes);
    await Share.shareXFiles([XFile(file.path, mimeType: 'model/stl')],
        subject: '$name.stl');
    return 'to Files → CADSketch → $name.stl';
  }
  final dir = Directory(Platform.environment['AI_SKETCHER_STL_OUT'] ??
      '${Directory.systemTemp.path}/cadsketch_stl')
    ..createSync(recursive: true);
  final file = File('${dir.path}/$name.stl');
  await file.writeAsBytes(bytes);
  return file.path;
}
