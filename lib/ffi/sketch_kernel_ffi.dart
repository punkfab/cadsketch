import 'dart:ffi';
import 'dart:io';
import 'dart:ui' show Offset;

import 'package:ffi/ffi.dart';

// Hand-written FFI bindings for the native kernel. The C API is tiny, so we
// bind it directly rather than running ffigen — fewer moving parts while the
// surface is still in flux. When it grows (M2: the planegcs constraint API),
// switch to ffigen against sketch_kernel.h.

typedef _SkVersionC = Int32 Function();
typedef _SkVersionDart = int Function();

typedef _SkFitLineC = Int32 Function(Pointer<Double>, Int32, Pointer<Double>);
typedef _SkFitLineDart = int Function(Pointer<Double>, int, Pointer<Double>);

typedef _SkFitCircleC = Int32 Function(Pointer<Double>, Int32, Pointer<Double>);
typedef _SkFitCircleDart = int Function(Pointer<Double>, int, Pointer<Double>);

// Constraint solver. SkSketch is an opaque handle (Pointer<Void>).
typedef _SkCreateC = Pointer<Void> Function();
typedef _SkDestroyC = Void Function(Pointer<Void>);
typedef _SkDestroyDart = void Function(Pointer<Void>);
typedef _SkAddPointC = Int32 Function(Pointer<Void>, Double, Double);
typedef _SkAddPointDart = int Function(Pointer<Void>, double, double);
typedef _SkFixPointC = Void Function(Pointer<Void>, Int32, Int32);
typedef _SkFixPointDart = void Function(Pointer<Void>, int, int);
typedef _SkAddConstraintC = Int32 Function(
    Pointer<Void>, Int32, Int32, Int32, Int32, Int32, Double);
typedef _SkAddConstraintDart = int Function(
    Pointer<Void>, int, int, int, int, int, double);
typedef _SkSolveC = Int32 Function(Pointer<Void>);
typedef _SkSolveDart = int Function(Pointer<Void>);
typedef _SkPointC = Void Function(
    Pointer<Void>, Int32, Pointer<Double>, Pointer<Double>);
typedef _SkPointDart = void Function(
    Pointer<Void>, int, Pointer<Double>, Pointer<Double>);
typedef _SkAddRadiusC = Int32 Function(Pointer<Void>, Double);
typedef _SkAddRadiusDart = int Function(Pointer<Void>, double);
typedef _SkRadiusC = Double Function(Pointer<Void>, Int32);
typedef _SkRadiusDart = double Function(Pointer<Void>, int);
typedef _SkConRadiusC = Int32 Function(Pointer<Void>, Int32, Double);
typedef _SkConRadiusDart = int Function(Pointer<Void>, int, double);
typedef _SkConPocC = Int32 Function(Pointer<Void>, Int32, Int32, Int32);
typedef _SkConPocDart = int Function(Pointer<Void>, int, int, int);
typedef _SkConTanC = Int32 Function(Pointer<Void>, Int32, Int32, Int32, Int32);
typedef _SkConTanDart = int Function(Pointer<Void>, int, int, int, int);

/// Constraint type codes — must match enum SkConstraintType in sketch_kernel.h.
enum ConstraintType {
  coincident(0),
  horizontal(1),
  vertical(2),
  parallel(3),
  perpendicular(4),
  equalLength(5),
  distance(6);

  const ConstraintType(this.code);
  final int code;
}

class SketchKernel {
  SketchKernel._(DynamicLibrary lib)
      : _version = lib.lookupFunction<_SkVersionC, _SkVersionDart>('sk_version'),
        _fitLine = lib.lookupFunction<_SkFitLineC, _SkFitLineDart>('sk_fit_line'),
        _fitCircle =
            lib.lookupFunction<_SkFitCircleC, _SkFitCircleDart>('sk_fit_circle'),
        _skCreate = lib.lookupFunction<_SkCreateC, _SkCreateC>('sk_create'),
        _skDestroy = lib.lookupFunction<_SkDestroyC, _SkDestroyDart>('sk_destroy'),
        _skAddPoint =
            lib.lookupFunction<_SkAddPointC, _SkAddPointDart>('sk_add_point'),
        _skFixPoint =
            lib.lookupFunction<_SkFixPointC, _SkFixPointDart>('sk_fix_point'),
        _skAddConstraint = lib.lookupFunction<_SkAddConstraintC,
            _SkAddConstraintDart>('sk_add_constraint'),
        _skSolve = lib.lookupFunction<_SkSolveC, _SkSolveDart>('sk_solve'),
        _skPoint = lib.lookupFunction<_SkPointC, _SkPointDart>('sk_point'),
        _skAddRadius =
            lib.lookupFunction<_SkAddRadiusC, _SkAddRadiusDart>('sk_add_radius'),
        _skRadius = lib.lookupFunction<_SkRadiusC, _SkRadiusDart>('sk_radius'),
        _skConRadius = lib.lookupFunction<_SkConRadiusC, _SkConRadiusDart>(
            'sk_constrain_radius'),
        _skConPoc = lib.lookupFunction<_SkConPocC, _SkConPocDart>(
            'sk_constrain_point_on_circle'),
        _skConTan = lib.lookupFunction<_SkConTanC, _SkConTanDart>(
            'sk_constrain_tangent_line');

  final _SkVersionDart _version;
  final _SkFitLineDart _fitLine;
  final _SkFitCircleDart _fitCircle;

  // Solver entry points, consumed by the Sketch wrapper below.
  final _SkCreateC _skCreate;
  final _SkDestroyDart _skDestroy;
  final _SkAddPointDart _skAddPoint;
  final _SkFixPointDart _skFixPoint;
  final _SkAddConstraintDart _skAddConstraint;
  final _SkSolveDart _skSolve;
  final _SkPointDart _skPoint;
  final _SkAddRadiusDart _skAddRadius;
  final _SkRadiusDart _skRadius;
  final _SkConRadiusDart _skConRadius;
  final _SkConPocDart _skConPoc;
  final _SkConTanDart _skConTan;

  static SketchKernel? _instance;
  static SketchKernel get instance => _instance ??= SketchKernel._(_open());

  static DynamicLibrary _open() {
    if (Platform.isIOS) {
      // On iOS the kernel will be statically linked into the app binary.
      return DynamicLibrary.process();
    }
    final name = Platform.isWindows
        ? 'sketch_kernel.dll'
        : Platform.isMacOS
            ? 'libsketch_kernel.dylib'
            : 'libsketch_kernel.so';
    // 1) Bundled next to the executable (flutter run/build, via $ORIGIN/lib rpath).
    try {
      return DynamicLibrary.open(name);
    } catch (_) {
      // 2) Standalone build_native.sh output, for quick native-only iteration.
      return DynamicLibrary.open('build/native/$name');
    }
  }

  int get version => _version();

  /// Fits a clean line segment to [points] using total-least-squares.
  /// Returns the snapped endpoints, or null if the fit failed.
  ({Offset a, Offset b})? fitLine(List<Offset> points) {
    final n = points.length;
    if (n < 2) return null;

    final input = calloc<Double>(n * 2);
    final output = calloc<Double>(4);
    try {
      for (var i = 0; i < n; i++) {
        input[2 * i] = points[i].dx;
        input[2 * i + 1] = points[i].dy;
      }
      final ok = _fitLine(input, n, output);
      if (ok == 0) return null;
      return (
        a: Offset(output[0], output[1]),
        b: Offset(output[2], output[3]),
      );
    } finally {
      calloc.free(input);
      calloc.free(output);
    }
  }

  /// Fits a circle to [points] (Kåsa algebraic fit). Returns center, radius and
  /// the RMS radial residual, or null if the fit failed.
  ({Offset center, double radius, double rms})? fitCircle(List<Offset> points) {
    final n = points.length;
    if (n < 3) return null;

    final input = calloc<Double>(n * 2);
    final output = calloc<Double>(4);
    try {
      for (var i = 0; i < n; i++) {
        input[2 * i] = points[i].dx;
        input[2 * i + 1] = points[i].dy;
      }
      final ok = _fitCircle(input, n, output);
      if (ok == 0) return null;
      return (
        center: Offset(output[0], output[1]),
        radius: output[2],
        rms: output[3],
      );
    } finally {
      calloc.free(input);
      calloc.free(output);
    }
  }

  /// Creates a new constraint-solver sketch. Caller must dispose it.
  Sketch newSketch() => Sketch._(this, _skCreate());
}

/// A constraint-solver sketch: add points, constrain them, solve, read back.
/// Owns a native handle — call [dispose] when done.
class Sketch {
  Sketch._(this._k, this._handle);

  final SketchKernel _k;
  final Pointer<Void> _handle;
  bool _disposed = false;

  /// Adds a point and returns its id.
  int addPoint(Offset p) => _k._skAddPoint(_handle, p.dx, p.dy);

  /// Pins a point so the solver treats it as a constant.
  void fixPoint(int id, {bool fixed = true}) =>
      _k._skFixPoint(_handle, id, fixed ? 1 : 0);

  int _con(ConstraintType t, int a, int b, int c, int d, double v) =>
      _k._skAddConstraint(_handle, t.code, a, b, c, d, v);

  int coincident(int a, int b) => _con(ConstraintType.coincident, a, b, -1, -1, 0);
  int horizontal(int a, int b) => _con(ConstraintType.horizontal, a, b, -1, -1, 0);
  int vertical(int a, int b) => _con(ConstraintType.vertical, a, b, -1, -1, 0);
  int parallel(int a, int b, int c, int d) =>
      _con(ConstraintType.parallel, a, b, c, d, 0);
  int perpendicular(int a, int b, int c, int d) =>
      _con(ConstraintType.perpendicular, a, b, c, d, 0);
  int equalLength(int a, int b, int c, int d) =>
      _con(ConstraintType.equalLength, a, b, c, d, 0);
  int distance(int a, int b, double value) =>
      _con(ConstraintType.distance, a, b, -1, -1, value);

  /// Adds a radius scalar unknown (initial value); returns its id.
  int addRadius(double value) => _k._skAddRadius(_handle, value);

  /// Reads back a (possibly solved) radius.
  double radius(int rad) => _k._skRadius(_handle, rad);

  /// radius[rad] == value.
  int constrainRadius(int rad, double value) =>
      _k._skConRadius(_handle, rad, value);

  /// |point - center| == radius[rad] (point lies on the circle).
  int pointOnCircle(int point, int center, int rad) =>
      _k._skConPoc(_handle, point, center, rad);

  /// Perpendicular distance from center to line (p1,p2) == radius[rad].
  int tangentLine(int p1, int p2, int center, int rad) =>
      _k._skConTan(_handle, p1, p2, center, rad);

  /// Solves in place. Returns true on convergence.
  bool solve() => _k._skSolve(_handle) == 0;

  /// Reads back a (possibly solved) point.
  Offset point(int id) {
    final buf = calloc<Double>(2);
    try {
      _k._skPoint(_handle, id, buf, buf + 1);
      return Offset(buf[0], buf[1]);
    } finally {
      calloc.free(buf);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _k._skDestroy(_handle);
  }
}
