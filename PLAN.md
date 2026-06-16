# ai-sketcher — Plan

A CAD sketch assistant. You sketch freehand; the app beautifies strokes, infers
geometric constraints, solves to clean parametric geometry with live dimensions,
extrudes to solids, and assembles parts with mates and shared parameters.

## Strategy

- **The Flutter app is a disposable prototyping harness.** Run it on Linux
  desktop with a tablet (Huion) to iterate fast on the UX and AI behavior.
- **The eventual product is native, iPad-only**, for the best Apple Pencil +
  Metal experience.
- **The one durable artifact is the C++ geometry kernel** behind a flat C ABI
  (`native/sketch_kernel.h`). Dart consumes it via `dart:ffi` now; Swift consumes
  the same ABI later. The Flutter UI is throwaway; the kernel is not.
- **Design rule:** stable/heavy math → C++ kernel; tune-by-feel logic
  (recognition thresholds, inference rules, AI prompts) → hot-reloadable Dart.

## Architecture

```
native/        C++ kernel (durable) — survives to the native iOS rebuild
  sketch_kernel.h/.cpp   flat C ABI; LM constraint solver; line/circle fits
lib/
  ffi/         dart:ffi bindings (SketchKernel + Sketch wrapper)
  sketch/      model (ParametricSketch, Part, Solid), recognition, mesh import,
               assembly (mates), 3D transforms
  ui/          canvas + 3D wireframe + assembly views, dialogs
```

Solver: self-written Levenberg–Marquardt (numerical central-difference Jacobian,
Cholesky), with a weak regularization toward drawn positions (resolves
under-constraint, prevents runaway). Radius is a solve unknown. **planegcs/OCCT
can replace the internals later behind the same C ABI.**

## Milestones

- [x] **M0** Canvas + stylus/mouse stroke capture + render
- [x] **M1** Beautify straight strokes → clean lines (kernel TLS fit)
- [x] **M2** Recognition (line / circle / arc / polyline via corner-sharpness);
  constraint solver; inference (merge, H/V, perpendicular, parallel,
  equal-length); CAD-style constraint glyphs
- [x] **M3** Driving vs driven dimensions; tap an edge → set a length / bind a
  shared parameter; parametric rectangles (equal-length)
- [x] **M3.5** Extrude a closed profile → rotatable orthographic wireframe
  (pseudo-3D in CustomPaint)
- [x] **M4** Multipart (parts bar); face-tap mate connectors; **fasten mates**
  assemble parts in a shared 3D scene (closed-form alignment); **shared
  parameters** across parts; circle → cylinder extrude
- [x] **Line+arc contours** Arcs are solver entities (radius unknown,
  point-on-circle); closed line+arc contours (slots, rounded shapes) solve and
  extrude; **auto-tangency** inference
- [x] **Import** STL/OBJ meshes import as parts (render, connectors, mate)
- [~] **M5** AI design assistant: structured sketch JSON → Claude → suggestions
  for constraints + design-rule flags. **Harness path live**: a right-side
  `AiPanel` serializes the active part (`lib/ai/sketch_serializer.dart`) and
  calls Claude through the terminal session via `claude -p`
  (`lib/ai/ai_client.dart`) — reuses `~/.claude` auth, no API key, billed
  against the subscription. Still to do: apply suggestions back onto the
  sketch (tool-calls), and the "always watching" debounced auto-review.

## Deferred to the native (iOS) build

These intentionally wait for the native rebuild; the harness validates the UX
around them.

- **Real 3D rendering** (shaded, Metal) — harness uses orthographic wireframe.
- **OpenCASCADE (OCCT)** B-rep kernel → real **STEP import** (tessellate to the
  same `Part.importedSolid`), booleans, fillets, NURBS. Convert STEP→STL
  meanwhile.
- **Apple Pencil** integration (low-latency, hover, pressure).
- **6-DOF / over-constrained assembly mate solver** — harness does single
  closed-form fasten mates.
- Native **file picker** (harness types a path).
- **AI transport**: harness shells out to the terminal `claude` CLI (subscription
  auth). The native build needs a real backend proxy holding an Anthropic API
  key; `AiClient` keeps the same call shape so only the transport swaps.

## Known harness gaps / polish backlog

- Arc **radius** isn't tap-to-dimension yet (lines + full circles are).
- **Bigon** contours (two edges between the same two points, e.g. a pure "D")
  don't tessellate; ≥3 distinct points work.
- Dense triangle-edge wireframe on high-poly imported meshes.
- Front-face connector picking uses a depth heuristic.
- Mate connectors aren't constrained to a sub-feature within a face.

## Testing

`flutter test` runs the suite (recognition, solver, dimensions, assembly,
arcs/tangency, mesh import, integration). The native kernel builds via
`./build_native.sh` and is bundled into the Linux app by `linux/CMakeLists.txt`.
