import 'dart:convert';
import 'dart:io';

import '../sketch/part.dart';
import 'featuretree_ir.dart';

/// Serializes [part] to featuretree IR and writes it as `<slug>.ir.json`,
/// returning the file path. The output directory is `$AI_SKETCHER_FT_OUT` if
/// set, else `<system temp>/ai_sketcher_ir`.
///
/// That file is the whole handoff: `python3 featuretree/gen.py <file> out.FCStd`
/// (or the featuretree Claude Code skill) turns it into an editable FreeCAD
/// PartDesign tree, and `b3d_emit.py` into a watertight build123d solid.
String writeFeatureTreeIr(Part part, {double scale = 1.0}) {
  final ir = partToIr(part, scale: scale);
  final outDir = Platform.environment['AI_SKETCHER_FT_OUT'] ??
      '${Directory.systemTemp.path}/ai_sketcher_ir';
  Directory(outDir).createSync(recursive: true);
  final name = (ir['name'] as String);
  final path = '$outDir/$name.ir.json';
  File(path).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(ir));
  return path;
}
