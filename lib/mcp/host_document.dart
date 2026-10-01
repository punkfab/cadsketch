import 'dart:convert';

import '../import/featuretree_import.dart';
import '../sketch/dxf.dart';
import '../sketch/model.dart';
import '../ui/sketch_canvas.dart';
import 'part_spec.dart';

// Glue between the host part format and the live document. Uses only the
// controller's existing public API (new project, DXF import, depth, remove),
// so a part drawn by a model lands in the document the same way an imported
// .dxf does and behaves like any other part afterwards.

/// Replaces the document with [specs].
void loadPartSpecs(SketchController controller, List<PartSpec> specs) {
  controller.newProject(); // back to one empty placeholder part
  for (final spec in specs) {
    importPartSpec(controller, spec);
  }
  if (specs.isNotEmpty) {
    controller.removePart(0); // drop the placeholder
    controller.setActive(0);
    // Model coordinates are arbitrary (often a small part near the origin):
    // frame it, or it lands in a corner of the canvas at 1 px per mm.
    controller.requestFitView();
  }
}

/// Adds one host-drawn part and makes it the active part.
///
/// A part given as coordinates has no design intent, so an edge driven to a new
/// length would skew the shape. Edges drawn exactly horizontal or vertical get
/// that constraint, which is what the app infers from a hand-drawn rectangle:
/// "make it 95 wide" then widens the plate instead of bending it.
void importPartSpec(SketchController controller, PartSpec spec) {
  controller.importDxf(spec.name, spec.toDrawing());
  controller.setPartDepth(controller.parts.length - 1, spec.depth);
  final sketch = controller.model; // importDxf made the new part active
  final inferred = <SketchConstraint>[];
  for (var i = 0; i < sketch.segments.length; i++) {
    final seg = sketch.segments[i];
    if (seg.isArc) continue;
    final d = sketch.points[seg.b] - sketch.points[seg.a];
    final tolerance = 1e-9 * (d.distance + 1);
    if (d.distance < 1e-9) continue;
    if (d.dy.abs() <= tolerance) {
      inferred.add(SketchConstraint(ConstraintKind.horizontal, [i]));
    } else if (d.dx.abs() <= tolerance) {
      inferred.add(SketchConstraint(ConstraintKind.vertical, [i]));
    }
  }
  if (inferred.isNotEmpty) controller.applyConstraints(inferred);
}

/// Replaces the document with the contents of a DXF file the host opened (the
/// same parser and import path as the app's own "Import DXF").
void loadDxfText(SketchController controller, String name, String text) {
  final drawing = parseDxf(text);
  if (drawing.isEmpty) {
    throw const PartSpecException(
        'No supported DXF entities (LINE / LWPOLYLINE / POLYLINE / CIRCLE / ARC)');
  }
  controller.newProject();
  controller.importDxf(name, drawing);
  controller.removePart(0); // drop the placeholder
  controller.setActive(0);
  controller.requestFitView();
}

/// Replaces the document with a featuretree IR file the host opened (the same
/// reader as the app's own "Import feature tree"). Returns what came in and
/// what was skipped, for the host to tell the user and the model.
List<IrImport> loadFeatureIrText(SketchController controller, String text) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException catch (e) {
    throw IrImportException('not valid JSON: ${e.message}');
  }
  final bodies = importFeatureIrDocument(json);
  controller.newProject();
  for (final body in bodies) {
    controller.importParts(body.parts);
  }
  controller.removePart(0); // drop the placeholder
  controller.setActive(0);
  controller.requestFitView();
  return bodies;
}

/// The document as model-visible context.
({Map<String, dynamic> structured, String text}) modelContextOf(
        SketchController controller) =>
    documentToModelContext(
        controller.parts, controller.activeIndex, controller.parameters);
