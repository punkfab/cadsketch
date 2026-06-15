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

// ---------------------------------------------------------------------------
// Constraint solver (M2). A sketch is a set of points (the unknowns) plus
// geometric constraints among them; sk_solve moves the free points to satisfy
// the constraints. Lines/arcs in the Dart layer are expressed as point ids, so
// the kernel only needs points + constraints.
//
// IMPLEMENTATION NOTE: the internals are a self-contained Levenberg-Marquardt
// solver today. This ABI is deliberately the durable contract — planegcs (or
// any other solver) can replace the internals later without changing it.
// ---------------------------------------------------------------------------

typedef void* SkSketch;

// Constraint type codes. The point-id arguments used by each (a,b,c,d) are
// noted; unused ids pass -1 and an unused value passes 0.
enum SkConstraintType {
  SK_COINCIDENT = 0,     // a,b      : point a == point b
  SK_HORIZONTAL = 1,     // a,b      : segment a-b is horizontal (ay == by)
  SK_VERTICAL = 2,       // a,b      : segment a-b is vertical (ax == bx)
  SK_PARALLEL = 3,       // a,b,c,d  : segment a-b parallel to c-d
  SK_PERPENDICULAR = 4,  // a,b,c,d  : segment a-b perpendicular to c-d
  SK_EQUAL_LENGTH = 5,   // a,b,c,d  : |a-b| == |c-d|
  SK_DISTANCE = 6,       // a,b,value: |a-b| == value
};

SK_API SkSketch sk_create(void);
SK_API void sk_destroy(SkSketch s);

// Adds a point at (x,y); returns its id (>= 0).
SK_API int sk_add_point(SkSketch s, double x, double y);

// Pins/unpins a point so the solver treats its coords as constants.
SK_API void sk_fix_point(SkSketch s, int id, int fixed);

// Adds a constraint; returns its id (>= 0) or -1 on invalid arguments.
SK_API int sk_add_constraint(SkSketch s, int type, int a, int b, int c, int d,
                             double value);

// Solves the system in place. Returns 0 on convergence, 1 if it did not
// converge within the iteration budget, -1 on error.
SK_API int sk_solve(SkSketch s);

// Reads back a (possibly solved) point's coordinates.
SK_API void sk_point(SkSketch s, int id, double* x, double* y);

// Number of points in the sketch.
SK_API int sk_point_count(SkSketch s);

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
