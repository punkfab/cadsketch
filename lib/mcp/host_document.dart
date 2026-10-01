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
    controller.importDxf(spec.name, spec.toDrawing());
    controller.setPartDepth(controller.parts.length - 1, spec.depth);
  }
  if (specs.isNotEmpty) {
    controller.removePart(0); // drop the placeholder
    controller.setActive(0);
    // Model coordinates are arbitrary (often a small part near the origin):
    // frame it, or it lands in a corner of the canvas at 1 px per mm.
    controller.requestFitView();
  }
}

/// The document as model-visible context.
({Map<String, dynamic> structured, String text}) modelContextOf(
        SketchController controller) =>
    documentToModelContext(
        controller.parts, controller.activeIndex, controller.parameters);
