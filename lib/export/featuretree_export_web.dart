import '../sketch/part.dart';

/// Web stub: the browser sandbox can't write files. On web, use the desktop
/// build (or copy the IR out) to hand off to featuretree.
String writeFeatureTreeIr(Part part, {double scale = 1.0}) {
  throw UnsupportedError(
      'Feature-tree export writes a file — run the desktop build for this.');
}
