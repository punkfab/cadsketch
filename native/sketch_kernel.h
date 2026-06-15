// sketch_kernel — the durable C ABI.
//
// This is the ONE piece of the prototype that survives to the native iOS
// rebuild: a flat C interface that both Dart (via dart:ffi) and Swift can
// consume. Keep it small and stable. Heavy/stable math lives here; tune-by-feel
// logic (classification thresholds, snapping tolerances) stays in Dart.
//
// At M2 this grows the real planegcs-backed constraint API:
//   sk_create / sk_add_point / sk_add_line / sk_constrain / sk_solve / ...
// For M0/M1 we only need a version probe and a line fit, which is enough to
// prove the scariest plumbing: marshalling point arrays across the FFI boundary
// in both directions.

#ifndef SKETCH_KERNEL_H
#define SKETCH_KERNEL_H

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define SK_API __declspec(dllexport)
#else
#define SK_API __attribute__((visibility("default")))
#endif

// Returns the ABI version. Bump when the C signatures below change.
SK_API int sk_version(void);

// Algebraic (Kåsa) circle fit by linear least squares.
//   xy   : input points, interleaved [x0,y0, ...], length 2*n
//   n    : number of points (>= 3)
//   out4 : output [cx, cy, r, rms] — center, radius, and RMS radial residual
//          (root-mean-square of |distance(point, center) - r|). Divide rms by r
//          in the caller to get a scale-free circularity measure.
// Returns 1 on success, 0 on failure (n < 3 or degenerate/collinear input).
SK_API int sk_fit_circle(const double* xy, int n, double* out4);

// Total-least-squares (orthogonal) line fit.
//   xy   : input points, interleaved [x0,y0, x1,y1, ...], length 2*n
//   n    : number of points (>= 2)
//   out4 : output endpoints [ax,ay, bx,by] — the input's first/last point
//          projected onto the fitted line, giving a clean snapped segment.
// Returns 1 on success, 0 on failure (n < 2 or degenerate input).
SK_API int sk_fit_line(const double* xy, int n, double* out4);

#ifdef __cplusplus
}
#endif

#endif  // SKETCH_KERNEL_H
