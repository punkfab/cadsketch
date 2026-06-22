// Kernel binding facade. The geometry kernel is the one durable artifact; how
// it's reached depends on the platform:
//   - native (VM/desktop/iOS): dart:ffi → the C++ kernel (sketch_kernel_io.dart)
//   - web: dart:js_interop → the same C++ kernel compiled to WASM
//           (sketch_kernel_web.dart)
// Both expose the identical SketchKernel / Sketch / ensureKernelReady surface,
// so the rest of the app imports only this file and never the platform variant.
export 'sketch_kernel_io.dart' if (dart.library.js_interop) 'sketch_kernel_web.dart';
