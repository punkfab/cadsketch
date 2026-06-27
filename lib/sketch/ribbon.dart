import 'dart:ui' show Offset;

/// Thickens an open polyline [pts] into a closed contour of total width
/// [width]: the centerline becomes a filled ribbon (left side forward, right
/// side back). This is the bridge that turns a single-stroke mark — i.e. text —
/// into an extrudable profile, so "text" rides the exact same extrude pipeline
/// as any other closed sketch, no filled-outline font required. Returns an
/// empty list if the stroke is degenerate.
List<Offset> strokeRibbon(List<Offset> pts, double width) {
  // Drop consecutive duplicate points so segment normals are well-defined.
  final p = <Offset>[];
  for (final q in pts) {
    if (p.isEmpty || (q - p.last).distance > 1e-6) p.add(q);
  }
  if (p.length < 2) return const [];

  final h = width / 2;
  final left = <Offset>[];
  final right = <Offset>[];
  for (var i = 0; i < p.length; i++) {
    final Offset n;
    if (i == 0) {
      n = _normal(p[0], p[1]);
    } else if (i == p.length - 1) {
      n = _normal(p[i - 1], p[i]);
    } else {
      // Average the two adjacent edge normals (a simple miter).
      final sum = _normal(p[i - 1], p[i]) + _normal(p[i], p[i + 1]);
      final l = sum.distance;
      n = l < 1e-6 ? _normal(p[i - 1], p[i]) : sum * (1 / l);
    }
    left.add(p[i] + n * h);
    right.add(p[i] - n * h);
  }
  return [...left, ...right.reversed];
}

/// Unit left-normal of edge a->b (zero for a degenerate edge).
Offset _normal(Offset a, Offset b) {
  final d = b - a;
  final len = d.distance;
  if (len < 1e-9) return Offset.zero;
  return Offset(-d.dy / len, d.dx / len);
}
