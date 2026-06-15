# ai-sketcher

A CAD sketch assistant. **This Flutter app is a disposable local prototyping
harness** — run it on Linux desktop with a connected tablet (Huion) to iterate
fast on the sketch → beautify → constrain → dimension → AI loop. The eventual
product is a native iOS-only app; the one piece that survives that rebuild is
the C++ geometry kernel behind the flat C ABI in `native/sketch_kernel.h`.

## Architecture

```
native/                 Durable C++ kernel (survives to the iOS rebuild)
  sketch_kernel.h        The flat C ABI — Dart (now) and Swift (later) consume this
  sketch_kernel.cpp      Stable math: total-least-squares line fit (M2: planegcs solver)
lib/
  ffi/sketch_kernel_ffi.dart   Hand-written dart:ffi bindings to the kernel
  sketch/entities.dart         Sketch model (RawStroke, LineEntity) — JSON-able for AI (M5)
  sketch/beautify.dart         Tune-by-feel classification thresholds (hot-reloadable)
  ui/sketch_canvas.dart        Pointer/stylus capture + CustomPainter rendering
  main.dart                    App shell; probes the FFI bridge on launch
```

Design rule: **stable heavy math → C++ kernel; tune-by-feel logic → Dart** (so
hot reload makes tuning instant). The kernel is dlopen'd via FFI and bundled
into the app by `linux/CMakeLists.txt`, so no extra build step is needed.

## Run it (Linux + tablet)

```bash
flutter run -d linux
```

Draw with the tablet/mouse. A roughly-straight stroke snaps to a clean cyan line
(beautified via the kernel); anything else stays a grey freehand stroke. The app
bar shows `kernel vN` in green when the FFI bridge loaded. "Clear" empties the
canvas.

> Huion on Linux: x/y stroke capture works; pen **pressure** is unreliable
> through Flutter's GTK embedder — don't build pressure-dependent features here.

## Iterate on the native kernel only

```bash
./build_native.sh        # builds build/native/libsketch_kernel.so
flutter test             # pure-Dart classification tests
```

## Milestones

- **M0** ✅ canvas + stroke capture + render
- **M1** ✅ beautify straight strokes → clean lines (FFI round-trip proven)
- **M2** arcs/circles + planegcs constraint solver behind the same C ABI; infer
  + solve constraints on a closed profile
- **M3** driving vs driven dimensions; edit a dimension → geometry updates live
- **M4** multiple parts on one canvas + shared parameters (assembly UX)
- **M5** AI assistant: structured sketch JSON → Claude → tool-call suggestions
