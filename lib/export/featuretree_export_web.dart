import '../sketch/part.dart';

/// Web stub: the browser sandbox can't write files. On web, use the desktop
/// build (or copy the IR out) to hand off to featuretree.
Future<({String where, List<String> dropped})> writeFeatureTreeIr(
    Part root, Iterable<Part> parts,
    {double scale = 1.0}) async {
  throw UnsupportedError(
      'Feature-tree export writes a file — run the desktop build for this.');
}
