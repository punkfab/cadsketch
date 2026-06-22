import 'dart:js_interop';
import 'dart:ui' show Offset;

// Web binding to the geometry kernel compiled to WebAssembly (emscripten).
// The hand-written JS glue (web/kernel/kernel_glue.js) loads the module and
// exposes a flat `SketchKernelJS` object plus a `SketchKernelReady` promise;
// this file mirrors the native SketchKernel / Sketch API exactly so the rest of
// the app is platform-agnostic. Pointer/heap marshalling lives in the JS glue.

@JS('SketchKernelReady')
external JSPromise<JSAny?> get _ready;

@JS('SketchKernelJS')
external _KernelJs? get _jsKernel;

extension type _KernelJs._(JSObject _) implements JSObject {
  external int version();
  external JSArray<JSNumber>? fitLine(JSArray<JSNumber> flat, int n);
  external JSArray<JSNumber>? fitCircle(JSArray<JSNumber> flat, int n);
  external int create();
  external void destroy(int h);
  external int addPoint(int h, double x, double y);
  external void fixPoint(int h, int id, int fixed);
  external int addConstraint(
      int h, int type, int a, int b, int c, int d, double v);
  external int solve(int h);
  external JSArray<JSNumber> point(int h, int id);
  external int addRadius(int h, double v);
  external double radius(int h, int id);
  external int conRadius(int h, int id, double v);
  external int conPoc(int h, int pt, int center, int rad);
  external int conTan(int h, int p1, int p2, int center, int rad);
}

/// Awaits the WASM module load. Call once before using the kernel (main()).
Future<void> ensureKernelReady() async {
  await _ready.toDart;
}

JSArray<JSNumber> _flat(List<Offset> pts) {
  final a = <JSNumber>[];
  for (final p in pts) {
    a.add(p.dx.toJS);
    a.add(p.dy.toJS);
  }
  return a.toJS;
}

class SketchKernel {
  SketchKernel._();
  static final SketchKernel instance = SketchKernel._();

  _KernelJs get _k =>
      _jsKernel ??
      (throw StateError('kernel not ready — await ensureKernelReady() first'));

  int get version => _k.version();

  ({Offset a, Offset b})? fitLine(List<Offset> points) {
    if (points.length < 2) return null;
    final r = _k.fitLine(_flat(points), points.length);
    if (r == null) return null;
    final d = r.toDart;
    return (
      a: Offset(d[0].toDartDouble, d[1].toDartDouble),
      b: Offset(d[2].toDartDouble, d[3].toDartDouble),
    );
  }

  ({Offset center, double radius, double rms})? fitCircle(List<Offset> points) {
    if (points.length < 3) return null;
    final r = _k.fitCircle(_flat(points), points.length);
    if (r == null) return null;
    final d = r.toDart;
    return (
      center: Offset(d[0].toDartDouble, d[1].toDartDouble),
      radius: d[2].toDartDouble,
      rms: d[3].toDartDouble,
    );
  }

  Sketch newSketch() => Sketch._(_k, _k.create());
}

/// Mirrors the native Sketch wrapper. Constraint type codes match
/// SkConstraintType in sketch_kernel.h.
class Sketch {
  Sketch._(this._k, this._handle);

  final _KernelJs _k;
  final int _handle;
  bool _disposed = false;

  int addPoint(Offset p) => _k.addPoint(_handle, p.dx, p.dy);
  void fixPoint(int id, {bool fixed = true}) =>
      _k.fixPoint(_handle, id, fixed ? 1 : 0);

  int coincident(int a, int b) => _k.addConstraint(_handle, 0, a, b, -1, -1, 0);
  int horizontal(int a, int b) => _k.addConstraint(_handle, 1, a, b, -1, -1, 0);
  int vertical(int a, int b) => _k.addConstraint(_handle, 2, a, b, -1, -1, 0);
  int parallel(int a, int b, int c, int d) =>
      _k.addConstraint(_handle, 3, a, b, c, d, 0);
  int perpendicular(int a, int b, int c, int d) =>
      _k.addConstraint(_handle, 4, a, b, c, d, 0);
  int equalLength(int a, int b, int c, int d) =>
      _k.addConstraint(_handle, 5, a, b, c, d, 0);
  int distance(int a, int b, double value) =>
      _k.addConstraint(_handle, 6, a, b, -1, -1, value);

  int addRadius(double value) => _k.addRadius(_handle, value);
  double radius(int rad) => _k.radius(_handle, rad);
  int constrainRadius(int rad, double value) =>
      _k.conRadius(_handle, rad, value);
  int pointOnCircle(int point, int center, int rad) =>
      _k.conPoc(_handle, point, center, rad);
  int tangentLine(int p1, int p2, int center, int rad) =>
      _k.conTan(_handle, p1, p2, center, rad);

  bool solve() => _k.solve(_handle) == 0;

  Offset point(int id) {
    final d = _k.point(_handle, id).toDart;
    return Offset(d[0].toDartDouble, d[1].toDartDouble);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _k.destroy(_handle);
  }
}
