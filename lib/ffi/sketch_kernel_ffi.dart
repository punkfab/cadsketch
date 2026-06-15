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

class SketchKernel {
  SketchKernel._(DynamicLibrary lib)
      : _version = lib.lookupFunction<_SkVersionC, _SkVersionDart>('sk_version'),
        _fitLine = lib.lookupFunction<_SkFitLineC, _SkFitLineDart>('sk_fit_line'),
        _fitCircle =
            lib.lookupFunction<_SkFitCircleC, _SkFitCircleDart>('sk_fit_circle');

  final _SkVersionDart _version;
  final _SkFitLineDart _fitLine;
  final _SkFitCircleDart _fitCircle;

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
}
