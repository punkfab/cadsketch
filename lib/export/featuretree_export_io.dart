import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../sketch/part.dart';
import 'featuretree_ir.dart';

/// Serializes the body [root] and the face features on it (from [parts]) to
/// featuretree IR and writes it as `<slug>.ir.json`, returning where it went
/// and what the IR had no way to say. Desktop: `$AI_SKETCHER_FT_OUT` if set,
/// else `<system temp>/ai_sketcher_ir`, returned as a path. Mobile (#10): the
/// app's Documents folder (Files → CADSketch) plus the share sheet, since the
/// sandbox tmp dir is unreachable there.
///
/// That file is the whole handoff: `python3 featuretree/gen.py <file> out.FCStd`
/// (or the featuretree Claude Code skill) turns it into an editable FreeCAD
/// PartDesign tree, and `b3d_emit.py` into a watertight build123d solid.
Future<({String where, List<String> dropped})> writeFeatureTreeIr(
    Part root, Iterable<Part> parts,
    {double scale = 1.0}) async {
  final body = bodyToIr(root, parts, scale: scale);
  final ir = body.ir;
  final name = (ir['name'] as String);
  final json = const JsonEncoder.withIndent('  ').convert(ir);
  if (Platform.isIOS || Platform.isAndroid) {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$name.ir.json');
    await file.writeAsString(json);
    await Share.shareXFiles([XFile(file.path, mimeType: 'application/json')],
        subject: '$name.ir.json');
    return (where: 'to Files → CADSketch → $name.ir.json', dropped: body.dropped);
  }
  final outDir = Platform.environment['AI_SKETCHER_FT_OUT'] ??
      '${Directory.systemTemp.path}/ai_sketcher_ir';
  Directory(outDir).createSync(recursive: true);
  final path = '$outDir/$name.ir.json';
  File(path).writeAsStringSync(json);
  return (where: path, dropped: body.dropped);
}
