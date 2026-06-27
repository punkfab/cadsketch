import 'dart:ui' show Offset;

// A minimal single-stroke ("stick") vector font. Each glyph is a set of
// polylines on a grid 0..width wide by 0.._emH tall (y-down, baseline at _emH,
// cap line at 0). It exists to make the point that text is not a special CAD
// feature: it's just a *contour source* that emits the very same polylines a
// freehand stroke produces. "Text on a face" is then a sketch on that face —
// the same primitive flowing through the same pipeline.
//
// Uppercase + digits + a little punctuation; lowercase folds to uppercase.

class _Glyph {
  const _Glyph(this.width, this.strokes);
  final double width;
  final List<List<Offset>> strokes;
}

const double _emH = 6;

const _Glyph _space = _Glyph(3, []);

const Map<String, _Glyph> _font = {
  ' ': _space,
  'A': _Glyph(4, [
    [Offset(0, 6), Offset(2, 0), Offset(4, 6)],
    [Offset(0.8, 3.8), Offset(3.2, 3.8)],
  ]),
  'B': _Glyph(4, [
    [Offset(0, 0), Offset(0, 6)],
    [Offset(0, 0), Offset(2.6, 0), Offset(3.4, 0.6), Offset(3.4, 2.2), Offset(2.6, 3), Offset(0, 3)],
    [Offset(0, 3), Offset(2.8, 3), Offset(3.7, 3.7), Offset(3.7, 5.2), Offset(2.8, 6), Offset(0, 6)],
  ]),
  'C': _Glyph(4, [
    [Offset(3.8, 1.3), Offset(3.0, 0.4), Offset(1.3, 0.3), Offset(0.5, 1.2), Offset(0.2, 2.3), Offset(0.2, 3.7), Offset(0.5, 4.8), Offset(1.3, 5.7), Offset(3.0, 5.6), Offset(3.8, 4.7)],
  ]),
  'D': _Glyph(4, [
    [Offset(0, 0), Offset(0, 6)],
    [Offset(0, 0), Offset(2.4, 0), Offset(3.4, 1.0), Offset(3.8, 2.3), Offset(3.8, 3.7), Offset(3.4, 5.0), Offset(2.4, 6), Offset(0, 6)],
  ]),
  'E': _Glyph(4, [
    [Offset(4, 0), Offset(0, 0), Offset(0, 6), Offset(4, 6)],
    [Offset(0, 3), Offset(2.8, 3)],
  ]),
  'F': _Glyph(4, [
    [Offset(4, 0), Offset(0, 0), Offset(0, 6)],
    [Offset(0, 3), Offset(2.8, 3)],
  ]),
  'G': _Glyph(4, [
    [Offset(3.8, 1.3), Offset(3.0, 0.4), Offset(1.3, 0.3), Offset(0.5, 1.2), Offset(0.2, 2.3), Offset(0.2, 3.7), Offset(0.5, 4.8), Offset(1.3, 5.7), Offset(3.0, 5.7), Offset(3.8, 4.9), Offset(3.8, 3.4), Offset(2.4, 3.4)],
  ]),
  'H': _Glyph(4, [
    [Offset(0, 0), Offset(0, 6)],
    [Offset(4, 0), Offset(4, 6)],
    [Offset(0, 3), Offset(4, 3)],
  ]),
  'I': _Glyph(2, [
    [Offset(0, 0), Offset(2, 0)],
    [Offset(1, 0), Offset(1, 6)],
    [Offset(0, 6), Offset(2, 6)],
  ]),
  'J': _Glyph(4, [
    [Offset(3, 0), Offset(3, 4.6), Offset(2.2, 5.7), Offset(1.0, 5.7), Offset(0.2, 4.6)],
  ]),
  'K': _Glyph(4, [
    [Offset(0, 0), Offset(0, 6)],
    [Offset(4, 0), Offset(0, 3.4)],
    [Offset(1.3, 2.6), Offset(4, 6)],
  ]),
  'L': _Glyph(4, [
    [Offset(0, 0), Offset(0, 6), Offset(3.8, 6)],
  ]),
  'M': _Glyph(5, [
    [Offset(0, 6), Offset(0, 0), Offset(2.5, 3.5), Offset(5, 0), Offset(5, 6)],
  ]),
  'N': _Glyph(4, [
    [Offset(0, 6), Offset(0, 0), Offset(4, 6), Offset(4, 0)],
  ]),
  'O': _Glyph(4, [
    [Offset(2, 0.2), Offset(0.7, 1.0), Offset(0.2, 2.3), Offset(0.2, 3.7), Offset(0.7, 5.0), Offset(2, 5.8), Offset(3.3, 5.0), Offset(3.8, 3.7), Offset(3.8, 2.3), Offset(3.3, 1.0), Offset(2, 0.2)],
  ]),
  'P': _Glyph(4, [
    [Offset(0, 6), Offset(0, 0), Offset(2.8, 0), Offset(3.6, 0.7), Offset(3.6, 2.3), Offset(2.8, 3.0), Offset(0, 3.0)],
  ]),
  'Q': _Glyph(4, [
    [Offset(2, 0.2), Offset(0.7, 1.0), Offset(0.2, 2.3), Offset(0.2, 3.7), Offset(0.7, 5.0), Offset(2, 5.8), Offset(3.3, 5.0), Offset(3.8, 3.7), Offset(3.8, 2.3), Offset(3.3, 1.0), Offset(2, 0.2)],
    [Offset(2.6, 4.4), Offset(4.2, 6.2)],
  ]),
  'R': _Glyph(4, [
    [Offset(0, 6), Offset(0, 0), Offset(2.8, 0), Offset(3.6, 0.7), Offset(3.6, 2.3), Offset(2.8, 3.0), Offset(0, 3.0)],
    [Offset(1.8, 3.0), Offset(3.8, 6)],
  ]),
  'S': _Glyph(4, [
    [Offset(3.8, 1.3), Offset(3.0, 0.4), Offset(1.4, 0.3), Offset(0.4, 1.1), Offset(0.4, 2.3), Offset(1.2, 2.9), Offset(2.8, 3.0), Offset(3.6, 3.7), Offset(3.6, 4.9), Offset(2.7, 5.7), Offset(1.1, 5.7), Offset(0.3, 4.9)],
  ]),
  'T': _Glyph(4, [
    [Offset(0, 0), Offset(4, 0)],
    [Offset(2, 0), Offset(2, 6)],
  ]),
  'U': _Glyph(4, [
    [Offset(0.2, 0), Offset(0.2, 4.4), Offset(1.0, 5.6), Offset(3.0, 5.6), Offset(3.8, 4.4), Offset(3.8, 0)],
  ]),
  'V': _Glyph(4, [
    [Offset(0, 0), Offset(2, 6), Offset(4, 0)],
  ]),
  'W': _Glyph(6, [
    [Offset(0, 0), Offset(1.2, 6), Offset(3, 2), Offset(4.8, 6), Offset(6, 0)],
  ]),
  'X': _Glyph(4, [
    [Offset(0, 0), Offset(4, 6)],
    [Offset(4, 0), Offset(0, 6)],
  ]),
  'Y': _Glyph(4, [
    [Offset(0, 0), Offset(2, 3), Offset(4, 0)],
    [Offset(2, 3), Offset(2, 6)],
  ]),
  'Z': _Glyph(4, [
    [Offset(0, 0), Offset(4, 0), Offset(0, 6), Offset(4, 6)],
  ]),
  '0': _Glyph(4, [
    [Offset(2, 0.2), Offset(0.7, 1.0), Offset(0.2, 2.3), Offset(0.2, 3.7), Offset(0.7, 5.0), Offset(2, 5.8), Offset(3.3, 5.0), Offset(3.8, 3.7), Offset(3.8, 2.3), Offset(3.3, 1.0), Offset(2, 0.2)],
    [Offset(1.2, 4.8), Offset(2.8, 1.2)],
  ]),
  '1': _Glyph(4, [
    [Offset(1, 1.2), Offset(2, 0.2), Offset(2, 6)],
    [Offset(0.8, 6), Offset(3.2, 6)],
  ]),
  '2': _Glyph(4, [
    [Offset(0.3, 1.3), Offset(1.2, 0.3), Offset(2.8, 0.3), Offset(3.7, 1.2), Offset(3.7, 2.4), Offset(0.3, 6), Offset(3.9, 6)],
  ]),
  '3': _Glyph(4, [
    [Offset(0.3, 0.8), Offset(1.2, 0.2), Offset(2.8, 0.2), Offset(3.7, 1.0), Offset(3.7, 2.3), Offset(2.4, 3.0), Offset(3.7, 3.7), Offset(3.7, 5.0), Offset(2.8, 5.8), Offset(1.2, 5.8), Offset(0.3, 5.1)],
  ]),
  '4': _Glyph(4, [
    [Offset(2.9, 6), Offset(2.9, 0.2), Offset(0.2, 4.2), Offset(3.9, 4.2)],
  ]),
  '5': _Glyph(4, [
    [Offset(3.7, 0.2), Offset(0.6, 0.2), Offset(0.4, 2.6), Offset(1.4, 2.0), Offset(3.0, 2.0), Offset(3.8, 2.9), Offset(3.8, 4.8), Offset(2.9, 5.8), Offset(1.1, 5.8), Offset(0.3, 5.0)],
  ]),
  '6': _Glyph(4, [
    [Offset(3.5, 0.9), Offset(2.6, 0.2), Offset(1.2, 0.6), Offset(0.4, 2.2), Offset(0.2, 3.8), Offset(0.7, 5.1), Offset(2.0, 5.8), Offset(3.3, 5.1), Offset(3.8, 3.9), Offset(3.3, 2.8), Offset(2.0, 2.5), Offset(0.7, 3.0)],
  ]),
  '7': _Glyph(4, [
    [Offset(0.2, 0.2), Offset(3.9, 0.2), Offset(1.6, 6)],
  ]),
  '8': _Glyph(4, [
    [Offset(2, 0.2), Offset(0.8, 0.8), Offset(0.8, 1.9), Offset(2, 2.6), Offset(3.2, 1.9), Offset(3.2, 0.8), Offset(2, 0.2)],
    [Offset(2, 2.6), Offset(0.5, 3.4), Offset(0.4, 4.9), Offset(2, 5.8), Offset(3.6, 4.9), Offset(3.5, 3.4), Offset(2, 2.6)],
  ]),
  '9': _Glyph(4, [
    [Offset(3.4, 1.0), Offset(2.2, 0.3), Offset(1.0, 0.8), Offset(0.4, 1.9), Offset(0.8, 3.1), Offset(2.0, 3.6), Offset(3.2, 3.1), Offset(3.6, 1.9)],
    [Offset(3.6, 1.9), Offset(3.6, 4.6), Offset(2.6, 5.8), Offset(1.0, 5.8), Offset(0.4, 5.0)],
  ]),
  '-': _Glyph(4, [
    [Offset(0.6, 3.0), Offset(3.4, 3.0)],
  ]),
  '.': _Glyph(2, [
    [Offset(0.7, 5.5), Offset(1.3, 5.5), Offset(1.3, 6.0), Offset(0.7, 6.0), Offset(0.7, 5.5)],
  ]),
  ':': _Glyph(2, [
    [Offset(0.7, 1.8), Offset(1.3, 1.8), Offset(1.3, 2.4), Offset(0.7, 2.4), Offset(0.7, 1.8)],
    [Offset(0.7, 4.4), Offset(1.3, 4.4), Offset(1.3, 5.0), Offset(0.7, 5.0), Offset(0.7, 4.4)],
  ]),
  '/': _Glyph(4, [
    [Offset(0.2, 6), Offset(3.4, 0.2)],
  ]),
  '#': _Glyph(5, [
    [Offset(1.4, 0.4), Offset(0.8, 5.6)],
    [Offset(3.4, 0.4), Offset(2.8, 5.6)],
    [Offset(0.4, 2.2), Offset(4.2, 2.2)],
    [Offset(0.2, 3.8), Offset(4.0, 3.8)],
  ]),
};

/// Text as polylines, cap height [size] (model units), centered on the origin
/// so a caller can drop it on a datum point. Unknown characters advance a space.
/// Returns the SAME shape a freehand stroke does — a list of point polylines.
List<List<Offset>> textToStrokes(String text,
    {double size = 24, double tracking = 0.6}) {
  final raw = <List<Offset>>[];
  final s = size / _emH;
  var penX = 0.0;
  for (final ch in text.toUpperCase().split('')) {
    final g = _font[ch] ?? _space;
    for (final stroke in g.strokes) {
      raw.add([for (final p in stroke) Offset(penX + p.dx * s, p.dy * s)]);
    }
    penX += g.width * s + tracking;
  }
  if (raw.isEmpty) return raw;
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final st in raw) {
    for (final p in st) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
  }
  final c = Offset((minX + maxX) / 2, (minY + maxY) / 2);
  return [
    for (final st in raw) [for (final p in st) p - c]
  ];
}
