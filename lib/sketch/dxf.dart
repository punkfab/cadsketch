import 'dart:ui' show Offset;

// A minimal DXF reader: enough of the ASCII DXF entity model to turn a 2D CAD
// drawing into a sketch profile. Supports LINE, LWPOLYLINE, POLYLINE/VERTEX,
// CIRCLE, and ARC — the common entities a 2D part outline uses. Splines,
// ellipses, blocks/INSERTs, and text are ignored for now (a later refinement).
//
// This is pure (String in, data out) so it runs on every platform and is easy
// to test; file/picker access lives behind the dxf_import facade.

class DxfLine {
  const DxfLine(this.a, this.b);
  final Offset a;
  final Offset b;
}

class DxfPolyline {
  const DxfPolyline(this.points, this.closed);
  final List<Offset> points;
  final bool closed;
}

class DxfCircle {
  const DxfCircle(this.center, this.radius);
  final Offset center;
  final double radius;
}

/// An arc, angles in DEGREES, CCW from [startDeg] to [endDeg] (DXF convention).
class DxfArc {
  const DxfArc(this.center, this.radius, this.startDeg, this.endDeg);
  final Offset center;
  final double radius;
  final double startDeg;
  final double endDeg;
}

class DxfDrawing {
  final List<DxfLine> lines = [];
  final List<DxfPolyline> polylines = [];
  final List<DxfCircle> circles = [];
  final List<DxfArc> arcs = [];

  bool get isEmpty =>
      lines.isEmpty && polylines.isEmpty && circles.isEmpty && arcs.isEmpty;

  int get entityCount =>
      lines.length + polylines.length + circles.length + arcs.length;
}

class DxfException implements Exception {
  DxfException(this.message);
  final String message;
  @override
  String toString() => 'DxfException: $message';
}

/// Parses DXF [text] into a [DxfDrawing]. Tolerant of the surrounding sections
/// (HEADER/TABLES/BLOCKS): it simply collects every supported entity it sees.
DxfDrawing parseDxf(String text) {
  final rawLines = text.split('\n');
  // DXF is (group code, value) pairs, one each per line. Pair them up.
  final pairs = <(int, String)>[];
  for (var i = 0; i + 1 < rawLines.length; i += 2) {
    final code = int.tryParse(rawLines[i].trim());
    if (code == null) {
      throw DxfException('Malformed DXF near line ${i + 1} '
          '(expected a group code, got "${rawLines[i].trim()}")');
    }
    pairs.add((code, rawLines[i + 1].trim()));
  }

  // Group pairs into entities: a (0, TYPE) pair starts a new entity; the pairs
  // that follow (until the next code 0) are its fields.
  final entities = <(String, List<(int, String)>)>[];
  String? type;
  var fields = <(int, String)>[];
  for (final (code, value) in pairs) {
    if (code == 0) {
      if (type != null) entities.add((type, fields));
      type = value;
      fields = <(int, String)>[];
    } else if (type != null) {
      fields.add((code, value));
    }
  }
  if (type != null) entities.add((type, fields));

  final d = DxfDrawing();
  for (var e = 0; e < entities.length; e++) {
    final (t, fs) = entities[e];
    switch (t) {
      case 'LINE':
        d.lines.add(DxfLine(_pt(fs, 10, 20), _pt(fs, 11, 21)));
      case 'CIRCLE':
        d.circles.add(DxfCircle(_pt(fs, 10, 20), _num(fs, 40)));
      case 'ARC':
        d.arcs.add(
            DxfArc(_pt(fs, 10, 20), _num(fs, 40), _num(fs, 50), _num(fs, 51)));
      case 'LWPOLYLINE':
        final pts = _lwVertices(fs);
        if (pts.length >= 2) {
          d.polylines.add(DxfPolyline(pts, _flagClosed(fs)));
        }
      case 'POLYLINE':
        // Old-style polyline: the vertices are the following VERTEX entities,
        // terminated by SEQEND.
        final closed = _flagClosed(fs);
        final pts = <Offset>[];
        while (e + 1 < entities.length && entities[e + 1].$1 == 'VERTEX') {
          e++;
          pts.add(_pt(entities[e].$2, 10, 20));
        }
        if (e + 1 < entities.length && entities[e + 1].$1 == 'SEQEND') e++;
        if (pts.length >= 2) d.polylines.add(DxfPolyline(pts, closed));
    }
  }
  return d;
}

// --- field helpers -------------------------------------------------------

/// First value for group [code] in [fs], as a double.
double _num(List<(int, String)> fs, int code) {
  for (final (c, v) in fs) {
    if (c == code) return double.parse(v);
  }
  throw DxfException('Missing group code $code');
}

int _intOr(List<(int, String)> fs, int code, int fallback) {
  for (final (c, v) in fs) {
    if (c == code) return int.tryParse(v) ?? fallback;
  }
  return fallback;
}

/// A point from group codes [cx]/[cy] (first occurrence of each).
Offset _pt(List<(int, String)> fs, int cx, int cy) {
  double? x, y;
  for (final (c, v) in fs) {
    if (c == cx && x == null) x = double.parse(v);
    if (c == cy && y == null) y = double.parse(v);
  }
  if (x == null || y == null) {
    throw DxfException('Missing point group codes $cx/$cy');
  }
  return Offset(x, y);
}

/// LWPOLYLINE vertices: repeated 10 (x) / 20 (y) in order.
List<Offset> _lwVertices(List<(int, String)> fs) {
  final pts = <Offset>[];
  double? x;
  for (final (c, v) in fs) {
    if (c == 10) {
      x = double.parse(v);
    } else if (c == 20 && x != null) {
      pts.add(Offset(x, double.parse(v)));
      x = null;
    }
  }
  return pts;
}

/// Bit 1 of the 70 flag = closed polyline.
bool _flagClosed(List<(int, String)> fs) => (_intOr(fs, 70, 0) & 1) == 1;
