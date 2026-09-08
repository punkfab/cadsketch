import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sketch/assembly.dart';
import '../sketch/beautify.dart';
import '../sketch/dxf.dart';
import '../sketch/entities.dart';
import '../sketch/model.dart';
import '../sketch/part.dart';
import '../sketch/plane.dart';
import '../sketch/solid.dart';
import '../sketch/stroke_font.dart';

/// Captures strokes; lines feed the parametric model (inferred + solved),
/// everything else is kept as a decorative entity. Constraints are rendered
/// as CAD-style glyphs over the geometry.
class SketchCanvas extends StatefulWidget {
  const SketchCanvas({super.key, required this.controller});

  final SketchController controller;

  /// The model point that should sit at the pane center (and stays fixed under
  /// zoom): a face sketch's reference-outline centroid, else the pane center
  /// itself (which keeps base-plane sketches at "screen pixels == world units"
  /// when zoom == 1).
  static Offset anchorModel(Size size, List<Offset>? reference) {
    final paneCenter = Offset(size.width / 2, size.height / 2);
    if (reference == null || reference.isEmpty) return paneCenter;
    var cx = 0.0, cy = 0.0;
    for (final p in reference) {
      cx += p.dx;
      cy += p.dy;
    }
    return Offset(cx / reference.length, cy / reference.length);
  }

  /// Pan offset at zoom 1 (screen = model + offset) that centers a face
  /// sketch's outline; zero for base-plane sketches. (Kept for clarity/tests:
  /// equals paneCenter - anchorModel.)
  static Offset viewOffset(Size size, List<Offset>? reference) {
    return Offset(size.width / 2, size.height / 2) -
        anchorModel(size, reference);
  }

  @override
  State<SketchCanvas> createState() => _SketchCanvasState();
}

/// What the user currently has selected, for delete / edit affordances.
enum _SelKind { point, segment, circle, constraint }

class _Selection {
  const _Selection(this.kind, this.index);
  final _SelKind kind;
  final int index;
}

class _SketchCanvasState extends State<SketchCanvas> {
  List<Offset>? _active;
  int? _selected; // segment whose dimension dialog is open (highlighted)
  int? _selectedCircle; // decoration index of circle being edited
  _Selection? _sel; // the persistently selected element (delete/edit target)

  // Vertex-drag gesture: the point grabbed on press, and whether it has moved
  // past the tap threshold (a press that doesn't move just selects the vertex).
  int? _dragPoint;
  Offset? _downPos;
  bool _dragMoved = false;
  int? _snapTarget; // vertex the dragged point would weld onto on release
  // Constraints inferred while dragging (H/V/parallel/perp); previewed in green
  // and applied on release so the alignment persists.
  List<SketchConstraint> _dragCandidates = const [];

  /// Drag a vertex within this (model units) of another to weld them on release.
  static const double _snapRadius = 16.0;

  // View transform: screen = model * _zoom + _pan. Geometry is stored/edited in
  // model coords. Each build sets _pan = paneCenter - anchor*_zoom + _userPan:
  // the anchor keeps a face sketch centered, _userPan is free two-finger panning,
  // _zoom is pinch (touch) or scroll-wheel (desktop).
  double _zoom = 1;
  Offset _pan = Offset.zero;
  Offset _userPan = Offset.zero; // accumulated two-finger pan
  Offset _toModel(Offset screen) => (screen - _pan) / _zoom;
  Offset _toScreenPt(Offset model) => model * _zoom + _pan;

  int? _hoveredDim; // dimension label under the cursor (mouse hover)

  // --- Line tool: tap-to-place chain of connected segments -----------------
  // When on, one-finger taps place vertices instead of drawing freehand. The
  // first tap sets the chain start (snapping onto an existing vertex if you tap
  // near one — that's how you "continue a line from an existing point"); each
  // later tap commits a segment and continues from there; tapping the first
  // vertex closes the loop; Esc / Done ends the chain.
  bool _lineTool = false;
  Offset? _chainStart; // last placed vertex (model coords), or null = no chain
  Offset? _chainFirst; // the chain's first vertex, for close detection
  Offset? _linePreview; // where the rubber-band currently points (model coords)

  /// Snaps a model point onto the nearest existing vertex within [_snapRadius],
  /// else returns it unchanged — so taps land exactly on endpoints to weld.
  Offset _snapModel(Offset m) {
    final model = widget.controller.model;
    final pi = model.hitTestPoint(m, radius: _snapRadius);
    return pi != null ? model.points[pi] : m;
  }

  void _toggleLineTool() => setState(() {
        _lineTool = !_lineTool;
        _chainStart = _chainFirst = _linePreview = null;
        _sel = null;
      });

  void _endChain() =>
      setState(() => _chainStart = _chainFirst = _linePreview = null);

  /// Commits the next chain vertex at [m] (already snapped). Starts the chain if
  /// none is in progress; otherwise adds a segment from the previous vertex and
  /// continues (or closes, if [m] is the chain's first vertex).
  void _lineCommit(Offset m) {
    final start = _chainStart;
    if (start == null) {
      setState(() {
        _chainStart = m;
        _chainFirst = m;
      });
      return;
    }
    if ((m - start).distance < 1e-3) return; // tapped the same point — ignore
    widget.controller.addSegmentBetween(start, m);
    final first = _chainFirst;
    final closed = first != null && (m - first).distance < 1e-3;
    setState(() {
      _linePreview = null;
      if (closed) {
        _chainStart = _chainFirst = null;
      } else {
        _chainStart = m;
      }
    });
  }

  /// The segment whose dimension label is under [screen] (tested in SCREEN
  /// space, since labels are drawn at a constant on-screen size). Fixes the
  /// click target drifting from the number at non-1 zoom.
  int? _hitDimensionScreen(Offset screen) {
    final m = widget.controller.model;
    int? best;
    var bestD = 24.0; // generous px radius around the number
    for (var si = 0; si < m.segments.length; si++) {
      final d = (_toScreenPt(m.dimAnchor(si)) - screen).distance;
      if (d < bestD) {
        bestD = d;
        best = si;
      }
    }
    return best;
  }

  void _onHover(Offset screen) {
    final h = _hitDimensionScreen(screen);
    if (h != _hoveredDim) setState(() => _hoveredDim = h);
  }

  /// The constraint whose glyph badge is under [screen] (screen space, since
  /// badges are a constant on-screen size). Anchors mirror the painter's.
  int? _hitConstraintScreen(Offset screen) {
    final m = widget.controller.model;
    Offset off(int si) => m.segMid(si) + m.segNormal(si) * 16;
    int? best;
    var bestD = 20.0;
    for (var i = 0; i < m.constraints.length; i++) {
      final c = m.constraints[i];
      final anchors = <Offset>[];
      switch (c.kind) {
        case ConstraintKind.horizontal:
        case ConstraintKind.vertical:
          anchors.add(off(c.segments[0]));
        case ConstraintKind.perpendicular:
        case ConstraintKind.parallel:
          anchors.add((off(c.segments[0]) + off(c.segments[1])) / 2);
        case ConstraintKind.equalLength:
          anchors
            ..add(off(c.segments[0]))
            ..add(off(c.segments[1]));
        case ConstraintKind.tangent:
          final line = m.segments[c.segments[0]];
          final arc = m.segments[c.segments[1]];
          final shared = (line.a == arc.a || line.a == arc.b) ? line.a : line.b;
          anchors.add(m.points[shared] + const Offset(0, -16));
      }
      for (final a in anchors) {
        final d = (_toScreenPt(a) - screen).distance;
        if (d < bestD) {
          bestD = d;
          best = i;
        }
      }
    }
    return best;
  }

  static const double _minZoom = 0.25;
  static const double _maxZoom = 12.0;

  // Captured each build so the pinch handler can do focal-point math.
  Offset _anchor = Offset.zero;
  Offset _paneCenter = Offset.zero;

  // Multi-touch pinch/pan state. While two fingers are down we zoom/pan the view
  // and suppress drawing; one finger draws/selects as before.
  final Map<int, Offset> _pointers = {};
  bool _gesturing = false;
  double _pinchStartZoom = 1;
  double _pinchStartDist = 1;
  Offset _pinchStartModel = Offset.zero; // model point under the initial focal

  final _focus = FocusNode();

  void _zoomBy(double dy) => setState(() {
        _zoom = (_zoom * (dy > 0 ? 1 / 1.12 : 1.12)).clamp(_minZoom, _maxZoom);
      });

  void _resetView() => setState(() {
        _zoom = 1;
        _userPan = Offset.zero;
      });

  /// Movement below this (logical px) counts as a tap, not a stroke/drag.
  /// Generous enough to absorb stylus jitter on a tap.
  static const double _tapSlop = 10.0;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  // --- Pointer routing: 1 finger draws/selects, 2 fingers zoom/pan the view ---

  void _pointerDown(int id, Offset pos) {
    _pointers[id] = pos;
    if (_pointers.length == 1) {
      _onDown(pos);
    } else if (_pointers.length == 2) {
      // A second finger means "manipulate the view", not "draw": abandon any
      // stroke/vertex-grab the first finger started, and begin the pinch.
      _dragPoint = null;
      _snapTarget = null;
      setState(() {
        _active = null;
        _linePreview = null;
      });
      _gesturing = true;
      final pts = _pointers.values.toList();
      _pinchStartDist = (pts[0] - pts[1]).distance;
      _pinchStartZoom = _zoom;
      _pinchStartModel = _toModel((pts[0] + pts[1]) / 2);
    }
  }

  void _pointerMove(int id, Offset pos) {
    if (!_pointers.containsKey(id)) return;
    _pointers[id] = pos;
    if (_pointers.length >= 2) {
      final pts = _pointers.values.toList();
      final dist = (pts[0] - pts[1]).distance;
      final focal = (pts[0] + pts[1]) / 2;
      if (_pinchStartDist <= 0) return;
      final z =
          (_pinchStartZoom * dist / _pinchStartDist).clamp(_minZoom, _maxZoom);
      // Keep the model point that was under the initial focal point under the
      // (possibly moved) focal point — pinch zooms toward the fingers, and a
      // two-finger drag pans. _pan = paneCenter - anchor*z + _userPan, so:
      setState(() {
        _zoom = z;
        _userPan = focal - _pinchStartModel * z - _paneCenter + _anchor * z;
      });
    } else if (!_gesturing) {
      _onMove(pos);
    }
  }

  void _pointerUp(int id) {
    _pointers.remove(id);
    if (_gesturing) {
      // Stay in gesture mode until every finger lifts, so a lingering finger
      // can't start drawing mid-zoom.
      if (_pointers.isEmpty) _gesturing = false;
      return;
    }
    _onUp();
  }

  void _onDown(Offset screen) {
    _downPos = screen;
    _dragMoved = false;
    _focus.requestFocus(); // so Delete/Backspace reaches us
    if (_lineTool) {
      // Line tool: taps place a chain; a press just previews where the next
      // vertex would land (snapped to a nearby existing vertex).
      setState(() => _linePreview = _snapModel(_toModel(screen)));
      return;
    }
    final m = _toModel(screen);
    final pi = widget.controller.model.hitTestPoint(m);
    if (pi != null) {
      _dragPoint = pi; // grab the vertex; don't start a stroke
      return;
    }
    setState(() => _active = [m]); // begin a freehand stroke (model coords)
  }

  void _onMove(Offset screen) {
    if (_lineTool) {
      setState(() => _linePreview = _snapModel(_toModel(screen)));
      return;
    }
    if (_dragPoint != null) {
      if (!_dragMoved &&
          (_downPos == null || (screen - _downPos!).distance < _tapSlop)) {
        return; // still within tap slop — not a drag yet
      }
      _dragMoved = true;
      final model = widget.controller.model;
      // Infer + snap: align incident edges to axes / a nearby edge as you drag.
      final snap = widget.controller.snapDrag(_dragPoint!, _toModel(screen));
      widget.controller.movePoint(_dragPoint!, snap.target); // live re-solve
      // Preview the weld target: another vertex within snap range of where the
      // dragged point now sits. Highlighted so "release to close" is legible.
      final target = model.hitTestPoint(model.points[_dragPoint!],
          exclude: _dragPoint, radius: _snapRadius);
      setState(() {
        _dragCandidates = snap.candidates;
        _snapTarget = target;
      });
      return;
    }
    setState(() => _active?.add(_toModel(screen)));
  }

  void _onUp() {
    if (_lineTool) {
      final target = _linePreview;
      if (target != null) _lineCommit(target);
      return;
    }
    final dp = _dragPoint;
    if (dp != null) {
      _dragPoint = null;
      final cands = _dragCandidates;
      _dragCandidates = const [];
      final target = _snapTarget;
      _snapTarget = null;
      // Apply inferred constraints first (they reference the current segment
      // indices), before any weld reindexes them.
      if (_dragMoved && cands.isNotEmpty) {
        widget.controller.applyConstraints(cands);
      }
      if (target != null && target != dp && _dragMoved) {
        // Dropped on another vertex → weld them (closes the path).
        final kept = widget.controller.mergePoints(dp, target);
        setState(() => _sel = _Selection(_SelKind.point, kept));
      } else {
        // A press on a vertex (moved or not) leaves it selected.
        setState(() => _sel = _Selection(_SelKind.point, dp));
      }
      return;
    }
    _end();
  }

  void _end() {
    final stroke = _active;
    setState(() => _active = null);
    if (stroke == null || stroke.isEmpty) return;

    // Tap (little movement) → select / edit; otherwise it's a drawn stroke.
    final extent =
        stroke.fold(0.0, (m, p) => (p - stroke.first).distance.clamp(m, 1e9));
    if (extent < _tapSlop) {
      _handleTap(stroke.first);
      return;
    }
    if (stroke.length >= 2) {
      widget.controller.addStroke(stroke);
      setState(() => _sel = null); // drawing clears the selection
    }
  }

  void _handleTap(Offset p) {
    final m = widget.controller.model;
    // The dimension number is the target — hit-test it in screen space so the
    // click lands on the drawn label regardless of zoom.
    final di = _hitDimensionScreen(_toScreenPt(p));
    if (di != null) {
      _editDimension(di);
      return;
    }
    // A tap on a constraint glyph selects it (so it can be deleted).
    final ki = _hitConstraintScreen(_toScreenPt(p));
    if (ki != null) {
      setState(() => _sel = _Selection(_SelKind.constraint, ki));
      return;
    }
    // Otherwise a tap anywhere on an edge / circle selects it (vertices are
    // handled on press, in _onDown).
    final si = m.hitTestSegment(p);
    if (si != null) {
      setState(() => _sel = _Selection(_SelKind.segment, si));
      return;
    }
    final ci = _hitTestCircle(p);
    if (ci != null) {
      setState(() => _sel = _Selection(_SelKind.circle, ci));
      return;
    }
    setState(() => _sel = null); // tapped empty space → clear
  }

  void _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      if (_lineTool && _chainStart != null) {
        _endChain(); // finish the current chain without leaving the tool
      }
      return;
    }
    if (e.logicalKey == LogicalKeyboardKey.delete ||
        e.logicalKey == LogicalKeyboardKey.backspace) {
      _deleteSelection();
    }
  }

  void _deleteSelection() {
    final sel = _sel;
    if (sel == null) return;
    switch (sel.kind) {
      case _SelKind.point:
        widget.controller.deletePoint(sel.index);
      case _SelKind.segment:
        widget.controller.deleteSegment(sel.index);
      case _SelKind.circle:
        widget.controller.deleteDecoration(sel.index);
      case _SelKind.constraint:
        widget.controller.removeConstraint(sel.index);
    }
    setState(() => _sel = null);
  }

  /// Human name for the constraint currently selected (for the selection bar).
  String _constraintName(int i) {
    final cs = widget.controller.model.constraints;
    if (i < 0 || i >= cs.length) return 'Constraint';
    return switch (cs[i].kind) {
      ConstraintKind.horizontal => 'Horizontal',
      ConstraintKind.vertical => 'Vertical',
      ConstraintKind.parallel => 'Parallel',
      ConstraintKind.perpendicular => 'Perpendicular',
      ConstraintKind.equalLength => 'Equal length',
      ConstraintKind.tangent => 'Tangent',
    };
  }

  /// Decoration index of a circle whose outline is near [p], or null.
  int? _hitTestCircle(Offset p, {double tolerance = 12}) {
    final decs = widget.controller.decorations;
    int? best;
    var bestDist = tolerance;
    for (var i = 0; i < decs.length; i++) {
      final e = decs[i];
      if (e is CircleEntity) {
        final d = ((p - e.center).distance - e.radius).abs();
        if (d <= bestDist) {
          bestDist = d;
          best = i;
        }
      }
    }
    return best;
  }

  Future<void> _editCircleRadius(int ci) async {
    setState(() => _selectedCircle = ci);
    try {
      final circle = widget.controller.decorations[ci] as CircleEntity;
      final action = await showDialog<_DimAction>(
        context: context,
        builder: (ctx) => _DimensionDialog(
          initial: circle.radius,
          parameterNames: widget.controller.parameters.keys.toList(),
          valueLabel: 'Radius',
        ),
      );
      switch (action) {
        case _SetLiteral(:final value):
          if (value > 0) widget.controller.setCircleRadius(ci, value);
        case _BindParam(:final name):
          if (name.isNotEmpty) widget.controller.bindCircleRadius(ci, name);
        case _MakeDriven():
          widget.controller.setCircleRadius(ci, circle.radius); // just unbind
        case null:
          break;
      }
    } finally {
      if (mounted) setState(() => _selectedCircle = null);
    }
  }

  Future<void> _editDimension(int si) async {
    setState(() => _selected = si);
    try {
      final model = widget.controller.model;
      final current =
          model.segments[si].drivingLength ?? model.measuredLength(si);
      final action = await showDialog<_DimAction>(
        context: context,
        builder: (ctx) => _DimensionDialog(
          initial: current,
          parameterNames: widget.controller.parameters.keys.toList(),
        ),
      );
      switch (action) {
        case _SetLiteral(:final value):
          if (value > 0) widget.controller.setDrivingLength(si, value);
        case _BindParam(:final name):
          if (name.isNotEmpty) widget.controller.bindDimension(si, name);
        case _MakeDriven():
          widget.controller.setDrivingLength(si, null);
        case null:
          break; // cancelled
      }
    } finally {
      if (mounted) setState(() => _selected = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focus,
      onKeyEvent: _onKey,
      // Clip to the pane: panning/zooming the sketch must not paint the canvas
      // outside its own bounds (it would spill into the adjacent 3D pane).
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) => AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) {
              final reference = widget.controller.active.referenceLoop;
              // Anchor the centering point at the pane center; zoom about it,
              // then apply the user's free two-finger pan on top.
              _anchor = SketchCanvas.anchorModel(constraints.biggest, reference);
              _paneCenter = Offset(
                  constraints.maxWidth / 2, constraints.maxHeight / 2);
              _pan = _paneCenter - _anchor * _zoom + _userPan;
              final sel = _sel;
              final segHi = _selected ??
                  (sel?.kind == _SelKind.segment ? sel!.index : null);
              final circHi = _selectedCircle ??
                  (sel?.kind == _SelKind.circle ? sel!.index : null);
              final ptHi = sel?.kind == _SelKind.point ? sel!.index : null;
              final conHi =
                  sel?.kind == _SelKind.constraint ? sel!.index : null;
              final viewMoved =
                  (_zoom - 1).abs() > 1e-3 || _userPan != Offset.zero;
              return Stack(
                children: [
                  // Pointer handling lives ONLY on the canvas layer, so tapping
                  // an overlay button (delete / reset / line tool) can't also
                  // fire a canvas gesture and disrupt the button's tap.
                  Positioned.fill(
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (e) =>
                          _pointerDown(e.pointer, e.localPosition),
                      onPointerMove: (e) =>
                          _pointerMove(e.pointer, e.localPosition),
                      onPointerHover: (e) => _onHover(e.localPosition),
                      onPointerUp: (e) => _pointerUp(e.pointer),
                      onPointerCancel: (e) => _pointerUp(e.pointer),
                      onPointerSignal: (e) {
                        if (e is PointerScrollEvent) _zoomBy(e.scrollDelta.dy);
                      },
                      child: CustomPaint(
                        painter: _SketchPainter(widget.controller, _active,
                            segHi, circHi, ptHi, _pan, _zoom, reference,
                            _snapTarget, _hoveredDim, _chainStart, _linePreview,
                            conHi, _dragCandidates),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                  _toolbar(),
                  if (sel != null) _selectionBar(sel),
                  if (viewMoved)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Tooltip(
                        message: 'Reset view (${(_zoom * 100).round()}%)',
                        child: FloatingActionButton.small(
                          heroTag: null,
                          onPressed: _resetView,
                          child: const Icon(Icons.center_focus_strong),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Top-left tool toggles. The Line tool turns one-finger taps into a
  /// tap-to-place chain (so you can continue a line from an existing point);
  /// while it's active a Done button ends the current chain.
  Widget _toolbar() {
    return Positioned(
      left: 8,
      top: 6,
      child: Material(
        color: const Color(0xE6161C22),
        borderRadius: BorderRadius.circular(8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: _lineTool
                  ? 'Line tool on — tap to place points'
                  : 'Line tool: tap to place a connected chain',
              child: IconButton(
                icon: const Icon(Icons.polyline, size: 20),
                color: _lineTool ? const Color(0xFF4DD0E1) : Colors.white70,
                onPressed: _toggleLineTool,
              ),
            ),
            if (_lineTool && _chainStart != null)
              TextButton(
                onPressed: _endChain,
                child: const Text('Done'),
              ),
          ],
        ),
      ),
    );
  }

  /// Floating action bar for the current selection: delete it, and (for a
  /// segment/circle) jump to its dimension editor.
  Widget _selectionBar(_Selection sel) {
    final label = switch (sel.kind) {
      _SelKind.point => 'Point',
      _SelKind.segment => 'Line',
      _SelKind.circle => 'Circle',
      _SelKind.constraint => _constraintName(sel.index),
    };
    return Positioned(
      right: 8,
      top: 6,
      child: Material(
        color: const Color(0xE6161C22),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.only(left: 12, right: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
              if (sel.kind == _SelKind.segment)
                TextButton(
                  onPressed: () => _editDimension(sel.index),
                  child: const Text('Dimension…'),
                ),
              if (sel.kind == _SelKind.circle)
                TextButton(
                  onPressed: () => _editCircleRadius(sel.index),
                  child: const Text('Radius…'),
                ),
              IconButton(
                tooltip: 'Delete (Del)',
                icon: const Icon(Icons.delete_outline, size: 20),
                color: Colors.redAccent,
                onPressed: _deleteSelection,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SketchController extends ChangeNotifier {
  final List<Part> parts = [Part('Part 1')];
  final List<Mate> mates = [];

  /// Shared assembly parameters: name -> value. Dimensions across any part can
  /// bind to these so one edit drives many parts.
  final Map<String, double> parameters = {};

  int activeIndex = 0;

  Part get active => parts[activeIndex];
  // Kept for the painter / canvas, which edit the active part.
  ParametricSketch get model => active.sketch;
  List<SketchEntity> get decorations => active.decorations;

  void addPart() {
    parts.add(Part('Part ${parts.length + 1}'));
    activeIndex = parts.length - 1;
    notifyListeners();
  }

  /// Adds an imported-mesh part and makes it active.
  void importSolid(String name, Solid solid) {
    parts.add(Part(name)..importedSolid = solid);
    activeIndex = parts.length - 1;
    notifyListeners();
  }

  /// Creates a new part whose sketch is a DXF drawing. LINE/LWPOLYLINE/POLYLINE
  /// and ARC (tessellated) become the parametric profile; CIRCLE becomes a circle
  /// decoration (a hole/cylinder via the usual profile-with-holes rule). DXF is
  /// Y-up, so Y is flipped to appear upright in the Y-down canvas.
  void importDxf(String name, DxfDrawing d) {
    final part = Part(name);
    Offset flip(Offset p) => Offset(p.dx, -p.dy);

    final lines = <(Offset, Offset)>[];
    for (final l in d.lines) {
      lines.add((flip(l.a), flip(l.b)));
    }
    for (final pl in d.polylines) {
      for (var i = 0; i + 1 < pl.points.length; i++) {
        lines.add((flip(pl.points[i]), flip(pl.points[i + 1])));
      }
      if (pl.closed && pl.points.length > 2) {
        lines.add((flip(pl.points.last), flip(pl.points.first)));
      }
    }
    for (final a in d.arcs) {
      final tess = _tessellateDxfArc(a);
      for (var i = 0; i + 1 < tess.length; i++) {
        lines.add((flip(tess[i]), flip(tess[i + 1])));
      }
    }

    part.sketch.addImportedLines(lines, weld: _weldFor(lines));
    for (final c in d.circles) {
      part.decorations.add(CircleEntity(flip(c.center), c.radius));
    }

    parts.add(part);
    activeIndex = parts.length - 1;
    notifyListeners();
  }

  void setActive(int index) {
    if (index < 0 || index >= parts.length || index == activeIndex) return;
    activeIndex = index;
    notifyListeners();
  }

  /// Adds a single line segment between two model points, welding each endpoint
  /// onto an existing vertex within merge tolerance. This is how the Line tool
  /// continues a chain from an existing point: pass the existing vertex as [a].
  void addSegmentBetween(Offset a, Offset b) {
    model.addLine(a, b);
    notifyListeners();
  }

  void addStroke(List<Offset> points) {
    final result = recognizeStroke(points);
    switch (result) {
      case PolylineResult(:final vertices):
        model.addPolyline(vertices);
      case ArcResult(:final start, :final end, :final center, :final radius, :final sweep):
        model.addArc(start, end, center, radius, sweep);
      case DecorationResult(:final entity):
        decorations.add(entity);
    }
    notifyListeners();
  }

  void setDrivingLength(int si, double? length) {
    model.segments[si].lengthParam = null; // a literal edit unbinds the param
    model.setDrivingLength(si, length);
    notifyListeners();
  }

  /// Binds the active part's segment [si] to a shared parameter [name],
  /// creating the parameter (seeded from the current length) if it's new.
  void bindDimension(int si, String name) {
    final value = parameters.putIfAbsent(name, () => model.measuredLength(si));
    model.segments[si].lengthParam = name;
    model.setDrivingLength(si, value);
    notifyListeners();
  }

  /// Sets a shared parameter's value and re-solves every part that binds it
  /// (segment lengths and circle radii alike).
  void setParameter(String name, double value) {
    parameters[name] = value;
    for (final part in parts) {
      var touched = false;
      for (final seg in part.sketch.segments) {
        if (seg.lengthParam == name) {
          seg.drivingLength = value;
          touched = true;
        }
      }
      if (touched) part.sketch.solve();
      for (final e in part.decorations) {
        if (e is CircleEntity && e.radiusParam == name) e.radius = value;
      }
    }
    notifyListeners();
  }

  /// Sets a circle's radius to a literal value (unbinding any parameter).
  void setCircleRadius(int decorationIndex, double radius) {
    final e = decorations[decorationIndex];
    if (e is CircleEntity) {
      e.radius = radius;
      e.radiusParam = null;
    }
    notifyListeners();
  }

  /// Binds a circle's radius to a shared parameter (created from the current
  /// radius if new).
  void bindCircleRadius(int decorationIndex, String name) {
    final e = decorations[decorationIndex];
    if (e is CircleEntity) {
      final value = parameters.putIfAbsent(name, () => e.radius);
      e.radiusParam = name;
      e.radius = value;
    }
    notifyListeners();
  }

  void setDepth(double depth) {
    active.depth = depth;
    notifyListeners();
  }

  /// Raises the active part's surface marks (text / freehand) into 3D by
  /// thickening + extruding them (emboss). 0 returns them to flat marks.
  void setEmbossDepth(double depth) {
    active.embossDepth = depth < 0 ? 0 : depth;
    notifyListeners();
  }

  /// Sets whether the active face feature adds (union) or removes (difference)
  /// material; the extrude direction follows automatically.
  void setOperation(FeatureOp op) {
    active.operation = op;
    notifyListeners();
  }

  /// Reverses the active feature's extrude direction (the rare inward-union /
  /// outward-difference case).
  void toggleFlipDirection() {
    active.flipDirection = !active.flipDirection;
    notifyListeners();
  }

  // --- Direct manipulation: drag a vertex, delete geometry / parts ---

  /// Drags the active part's vertex [pi] to [to] (live constraint re-solve).
  void movePoint(int pi, Offset to) {
    model.dragPoint(pi, to);
    notifyListeners();
  }

  /// Snap target + inferred constraint candidates while dragging vertex [pi]
  /// toward [raw] (horizontal / vertical / parallel / perpendicular). The canvas
  /// moves the point to the snapped target live and applies the candidates on
  /// release via [applyConstraints].
  ({Offset target, List<SketchConstraint> candidates}) snapDrag(int pi, Offset raw) =>
      model.snapDrag(pi, raw);

  /// Adds inferred constraints (deduped) and re-solves — makes a snapped
  /// alignment persist after a drag.
  void applyConstraints(List<SketchConstraint> cs) {
    var added = false;
    for (final c in cs) {
      if (!model.hasConstraint(c.kind, c.segments)) {
        model.constraints.add(c);
        added = true;
      }
    }
    if (added) {
      model.solve();
      notifyListeners();
    }
  }

  /// Deletes a constraint by index (the sketch then relaxes without it).
  void removeConstraint(int i) {
    model.removeConstraint(i);
    notifyListeners();
  }

  /// Welds dragged vertex [from] onto [into] (closes a path / joins a chain).
  /// Returns the surviving vertex index.
  int mergePoints(int from, int into) {
    final kept = model.mergePoints(from, into);
    notifyListeners();
    return kept;
  }

  void deleteSegment(int si) {
    model.removeSegment(si);
    notifyListeners();
  }

  void deletePoint(int pi) {
    model.removePoint(pi);
    notifyListeners();
  }

  void deleteDecoration(int di) {
    if (di < 0 || di >= decorations.length) return;
    decorations.removeAt(di);
    notifyListeners();
  }

  /// Removes a whole part (body). The last part isn't removed but reset, so the
  /// workspace always has one active sketch. Mates referencing the removed part
  /// are dropped and the rest reindexed.
  void removePart(int index) {
    if (index < 0 || index >= parts.length) return;
    if (parts.length == 1) {
      parts[0] = Part('Part 1');
      activeIndex = 0;
      mates.clear();
      notifyListeners();
      return;
    }
    final removed = parts.removeAt(index);
    // Promote the removed body's features to base bodies (parent -> null) so they
    // don't get orphaned — an orphaned feature roots at a part no longer in the
    // list and vanishes from the assembly / part view.
    for (final p in parts) {
      if (identical(p.parent, removed)) p.parent = null;
    }
    final kept = <Mate>[
      for (final m in mates)
        if (m.partA != index && m.partB != index)
          Mate(m.partA > index ? m.partA - 1 : m.partA, m.connectorA,
              m.partB > index ? m.partB - 1 : m.partB, m.connectorB)
    ];
    mates
      ..clear()
      ..addAll(kept);
    if (activeIndex >= parts.length) activeIndex = parts.length - 1;
    notifyListeners();
  }

  /// Sets a per-region extrude-depth override on the active part (drilling into
  /// a region and changing its thickness). Associative — see decompose().
  void setRegionDepth(int region, double depth) {
    active.regionDepths[region] = depth;
    notifyListeners();
  }

  void clearRegionDepth(int region) {
    if (active.regionDepths.remove(region) != null) notifyListeners();
  }

  /// Adds a new plane-sketch (a Part on [plane]) and makes it active — the
  /// "sketch on a base plane / on a face" entry point for multi-plane work.
  /// [reference] is the parent face's outline in plane-local coords (for a
  /// "sketch on a face"); it anchors the new sketch onto the face.
  void addPlaneSketch(SketchPlane plane,
      {String? name, List<Offset>? reference, Part? parent}) {
    parts.add(Part(name ?? 'Part ${parts.length + 1}')
      ..plane = plane
      ..referenceLoop = reference
      ..parent = parent);
    activeIndex = parts.length - 1;
    notifyListeners();
  }

  /// Indices of the parts shown together in the 3D view: the active part and
  /// every part sharing its root body. A face feature (sketched on a parent's
  /// face) thus renders in context on that parent, so the containing body
  /// doesn't disappear when the feature is active.
  List<int> visiblePartIndices() {
    final root = active.root;
    return [
      for (var i = 0; i < parts.length; i++)
        if (parts[i].root == root) i,
    ];
  }

  /// Adds [text] to the active part as stroke geometry on its datum — the SAME
  /// RawStroke primitive a freehand mark uses, just emitted by a text source.
  /// "Text on a face" is therefore a sketch on that face, nothing special.
  /// Centered on the face outline (for a face sketch) or the existing geometry.
  void addText(String text, {double size = 28}) {
    final strokes = textToStrokes(text, size: size);
    if (strokes.isEmpty) return;
    final at = _datumCenter(active);
    for (final s in strokes) {
      active.decorations.add(RawStroke([for (final p in s) p + at]));
    }
    notifyListeners();
  }

  /// Where to drop placed geometry on a part's datum: the face outline's center
  /// for a face sketch, else the existing sketch's center, else the origin.
  Offset _datumCenter(Part part) {
    final ref = part.referenceLoop;
    final pts = ref ?? part.sketch.points;
    if (pts.isEmpty) return Offset.zero;
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final p in pts) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    return Offset((minX + maxX) / 2, (minY + maxY) / 2);
  }

  void addConnector(int faceIndex) {
    // Anchor the connector to its face centroid so it survives face re-indexing
    // (e.g. when a hole is later drilled and buildSolid returns a longer face
    // list). resolvedFace() re-maps by nearest centroid on every use.
    final solid = active.buildSolid();
    final anchor = (solid != null &&
            faceIndex >= 0 &&
            faceIndex < solid.faces.length)
        ? solid.faceCentroid(faceIndex)
        : null;
    active.connectors.add(MateConnector(faceIndex, anchor: anchor));
    notifyListeners();
  }

  void addMate(int partA, int connectorA, int partB, int connectorB) {
    mates.add(Mate(partA, connectorA, partB, connectorB));
    notifyListeners();
  }

  /// Duplicates part [index] (deep copy) and makes the copy active, so a part
  /// can be reused more than once in an assembly.
  void duplicatePart(int index) {
    if (index < 0 || index >= parts.length) return;
    parts.add(parts[index].clone('${parts[index].name} copy'));
    activeIndex = parts.length - 1;
    notifyListeners();
  }

  /// The index of a mate that uses (part, connector), or null — lets the
  /// assembly view unmate by tapping a mated point.
  int? mateIndexFor(int part, int connector) {
    for (var i = 0; i < mates.length; i++) {
      final m = mates[i];
      if ((m.partA == part && m.connectorA == connector) ||
          (m.partB == part && m.connectorB == connector)) {
        return i;
      }
    }
    return null;
  }

  void removeMate(int index) {
    if (index < 0 || index >= mates.length) return;
    mates.removeAt(index);
    notifyListeners();
  }

  void clearMates() {
    if (mates.isEmpty) return;
    mates.clear();
    notifyListeners();
  }

  /// Removes a mate point (connector) from a part, dropping any mates that used
  /// it and reindexing the connectors above it.
  void removeConnector(int partIndex, int connectorIndex) {
    if (partIndex < 0 || partIndex >= parts.length) return;
    final cons = parts[partIndex].connectors;
    if (connectorIndex < 0 || connectorIndex >= cons.length) return;
    cons.removeAt(connectorIndex);
    final kept = <Mate>[];
    for (final m in mates) {
      if ((m.partA == partIndex && m.connectorA == connectorIndex) ||
          (m.partB == partIndex && m.connectorB == connectorIndex)) {
        continue; // mate used the removed point
      }
      var ca = m.connectorA, cb = m.connectorB;
      if (m.partA == partIndex && ca > connectorIndex) ca--;
      if (m.partB == partIndex && cb > connectorIndex) cb--;
      kept.add(Mate(m.partA, ca, m.partB, cb));
    }
    mates
      ..clear()
      ..addAll(kept);
    notifyListeners();
  }

  /// Removes every mate point from a part (and any mates that used them).
  void clearConnectors(int partIndex) {
    if (partIndex < 0 || partIndex >= parts.length) return;
    if (parts[partIndex].connectors.isEmpty) return;
    parts[partIndex].connectors.clear();
    mates.removeWhere((m) => m.partA == partIndex || m.partB == partIndex);
    notifyListeners();
  }

  void clear() {
    model.clear();
    decorations.clear();
    active.connectors.clear();
    notifyListeners();
  }
}

/// Tessellates a DXF arc (CCW from start to end angle) into points, ~10° apart.
List<Offset> _tessellateDxfArc(DxfArc a) {
  final s = a.startDeg * math.pi / 180;
  final e = a.endDeg * math.pi / 180;
  var sweep = e - s;
  while (sweep <= 0) {
    sweep += 2 * math.pi; // DXF arcs sweep CCW from start to end
  }
  final n = math.max(2, (sweep / (math.pi / 18)).ceil());
  return [
    for (var i = 0; i <= n; i++)
      a.center +
          Offset(math.cos(s + sweep * i / n), math.sin(s + sweep * i / n)) *
              a.radius,
  ];
}

/// Endpoint weld tolerance for an imported drawing: small, but scaled to the
/// drawing's extent so exact CAD endpoints join without merging genuinely
/// distinct points on a tiny part.
double _weldFor(List<(Offset, Offset)> lines) {
  if (lines.isEmpty) return 1e-6;
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  void ext(Offset p) {
    minX = math.min(minX, p.dx);
    minY = math.min(minY, p.dy);
    maxX = math.max(maxX, p.dx);
    maxY = math.max(maxY, p.dy);
  }

  for (final (a, b) in lines) {
    ext(a);
    ext(b);
  }
  return math.max(1e-6, math.max(maxX - minX, maxY - minY) * 1e-5);
}

class _SketchPainter extends CustomPainter {
  _SketchPainter(this.controller, this.active, this.selected,
      this.selectedCircle, this.selectedPoint, this.pan, this.zoom, this.reference,
      this.snapTarget, this.hoveredDim, this.chainStart, this.linePreview,
      this.selectedConstraint, this.dragCandidates);

  final SketchController controller;
  final List<Offset>? active;
  final int? selected;
  final int? selectedCircle;
  final int? selectedPoint;
  final Offset pan;
  final double zoom;
  final List<Offset>? reference; // parent face outline (guide), in model coords
  final int? snapTarget; // vertex a dragged point would weld onto (preview)
  final int? hoveredDim; // segment whose dimension label is hovered
  final Offset? chainStart; // line tool: last placed vertex (model coords)
  final Offset? linePreview; // line tool: current rubber-band target (model)
  final int? selectedConstraint; // constraint index highlighted for delete
  final List<SketchConstraint> dragCandidates; // inferred constraints preview

  static const _glyphColor = Color(0xFFFFC857);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(pan.dx, pan.dy); // model coords -> screen
    canvas.scale(zoom);
    // The canvas is scaled by zoom, so anything meant to be a constant SCREEN
    // size — line thickness, vertex dots — must be divided by zoom. Geometry
    // (positions, circle/arc radii) stays in model units and scales normally.
    final iz = 1 / zoom;

    // Face guide: the outline of the face this sketch sits on, so you can see
    // where you're drawing relative to the part.
    final ref = reference;
    if (ref != null && ref.length >= 2) {
      final guide = Paint()
        ..color = Colors.white.withValues(alpha: 0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 * iz;
      final path = Path()..moveTo(ref.first.dx, ref.first.dy);
      for (var i = 1; i < ref.length; i++) {
        path.lineTo(ref[i].dx, ref[i].dy);
      }
      path.close();
      canvas.drawPath(path, guide);
    }

    final raw = Paint()
      ..color = Colors.blueGrey.shade400
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * iz
      ..strokeCap = StrokeCap.round;
    final line = Paint()
      ..color = Colors.cyanAccent.shade400
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5 * iz
      ..strokeCap = StrokeCap.round;
    final node = Paint()..color = Colors.cyanAccent.shade100;
    final junction = Paint()
      ..color = _glyphColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * iz;

    final circleHighlight = Paint()
      ..color = _glyphColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4 * iz;

    // Decorative entities (non-line). Labels are collected and drawn later, in
    // screen space, so they stay a constant size.
    final circleLabels = <(Offset, String)>[];
    final decs = controller.decorations;
    for (var di = 0; di < decs.length; di++) {
      final e = decs[di];
      switch (e) {
        case RawStroke(:final points):
          canvas.drawPath(_polyline(points), raw);
        case LineEntity():
          break; // lines live in the model
        case CircleEntity(:final center, :final radius):
          canvas.drawCircle(
              center, radius, di == selectedCircle ? circleHighlight : line);
          canvas.drawCircle(center, 3 * iz, node);
          final label = e.radiusParam != null
              ? '${e.radiusParam}=${radius.toStringAsFixed(0)}'
              : 'R${radius.toStringAsFixed(0)}';
          circleLabels.add((center + Offset(0, -radius), label));
        case ArcEntity(
            :final center,
            :final radius,
            :final startAngle,
            :final sweepAngle
          ):
          canvas.drawArc(Rect.fromCircle(center: center, radius: radius),
              startAngle, sweepAngle, false, line);
          canvas.drawCircle(center, 3 * iz, node);
      }
    }

    final m = controller.model;

    // Solved segments (selected one highlighted).
    final highlight = Paint()
      ..color = const Color(0xFFFFC857)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4 * iz
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < m.segments.length; i++) {
      final s = m.segments[i];
      final paint = i == selected ? highlight : line;
      final arc = s.arc;
      if (arc != null) {
        final start = m.points[s.a];
        final a0 = math.atan2(start.dy - arc.center.dy, start.dx - arc.center.dx);
        canvas.drawArc(Rect.fromCircle(center: arc.center, radius: arc.radius),
            a0, arc.sweep, false, paint);
      } else {
        canvas.drawLine(m.points[s.a], m.points[s.b], paint);
      }
    }
    // Point nodes; shared points (degree >= 2) get a coincident ring; the
    // selected vertex gets an accent ring (the drag/delete handle).
    final selectedRing = Paint()
      ..color = _glyphColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5 * iz;
    final snapRing = Paint()
      ..color = const Color(0xFF69F0AE) // green: "release to weld / close"
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3 * iz;
    for (var i = 0; i < m.points.length; i++) {
      final p = m.points[i];
      canvas.drawCircle(p, 3 * iz, node);
      if (m.degree(i) >= 2) canvas.drawCircle(p, 6 * iz, junction);
      if (i == selectedPoint) canvas.drawCircle(p, 9 * iz, selectedRing);
      if (i == snapTarget) canvas.drawCircle(p, 11 * iz, snapRing);
    }
    // In-progress stroke (still in model space).
    final a = active;
    if (a != null && a.length >= 2) canvas.drawPath(_polyline(a), raw);

    // Line tool: rubber-band from the last placed vertex to the current target,
    // an accent dot on the anchor, and a green ring on the (snapped) target so
    // "tap to place / weld here" reads.
    final cs = chainStart;
    final lp = linePreview;
    if (cs != null) {
      if (lp != null) {
        canvas.drawLine(
            cs,
            lp,
            Paint()
              ..color = Colors.cyanAccent.shade400
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2 * iz
              ..strokeCap = StrokeCap.round);
      }
      canvas.drawCircle(cs, 4 * iz, node);
    }
    if (lp != null) {
      canvas.drawCircle(
          lp,
          5 * iz,
          Paint()
            ..color = const Color(0xFF69F0AE)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 * iz);
    }

    canvas.restore();

    // --- Constant-size annotations, drawn in SCREEN space after the zoom
    // transform is popped, so constraint glyphs and dimension labels keep the
    // same size at any zoom (their positions are the projected model anchors).
    for (var i = 0; i < m.constraints.length; i++) {
      _drawConstraint(canvas, m, m.constraints[i],
          color: i == selectedConstraint ? Colors.white : _glyphColor);
    }
    // Live preview of the constraints a drag would apply on release (green).
    for (final c in dragCandidates) {
      _drawConstraint(canvas, m, c, color: const Color(0xFF69F0AE));
    }
    for (var si = 0; si < m.segments.length; si++) {
      final seg = m.segments[si];
      final driving = seg.drivingLength;
      final isDriving = driving != null;
      final value = isDriving ? driving : m.measuredLength(si);
      final label = seg.lengthParam != null
          ? '${seg.lengthParam}=${value.toStringAsFixed(0)}'
          : isDriving
              ? value.toStringAsFixed(1)
              : '(${value.toStringAsFixed(0)})';
      _dimLabel(canvas, _toScreen(m.dimAnchor(si)), label, isDriving,
          highlighted: si == hoveredDim);
    }
    for (final (pos, label) in circleLabels) {
      _dimLabel(canvas, _toScreen(pos), label, true);
    }

    // Origin datum crosshair (the part's bounding-box centre), constant size.
    final origin = controller.active.originLocal();
    if (origin != null) {
      final o = _toScreen(origin);
      final ox = Paint()
        ..color = const Color(0xFF80D8FF)
        ..strokeWidth = 1.5;
      const r = 9.0;
      canvas.drawLine(o + const Offset(-r, 0), o + const Offset(r, 0), ox);
      canvas.drawLine(o + const Offset(0, -r), o + const Offset(0, r), ox);
      canvas.drawCircle(o, 2.5, Paint()..color = const Color(0xFF80D8FF));
    }
  }

  // Model coords -> screen (pane) coords, matching the canvas transform
  // (translate(pan) then scale(zoom)) used for geometry.
  Offset _toScreen(Offset m) =>
      Offset(m.dx * zoom + pan.dx, m.dy * zoom + pan.dy);

  // Anchors are computed in model space then projected to screen via _toScreen,
  // because the badges are drawn after the zoom transform is popped (so they
  // render at a constant size).
  void _drawConstraint(Canvas canvas, ParametricSketch m, SketchConstraint c,
      {Color color = _glyphColor}) {
    switch (c.kind) {
      case ConstraintKind.horizontal:
        _badgeText(canvas, _toScreen(_offsetMid(m, c.segments[0])), 'H', color);
      case ConstraintKind.vertical:
        _badgeText(canvas, _toScreen(_offsetMid(m, c.segments[0])), 'V', color);
      case ConstraintKind.perpendicular:
        final at =
            (_offsetMid(m, c.segments[0]) + _offsetMid(m, c.segments[1])) / 2;
        _badgePaint(canvas, _toScreen(at), color, _drawPerp);
      case ConstraintKind.parallel:
        final at =
            (_offsetMid(m, c.segments[0]) + _offsetMid(m, c.segments[1])) / 2;
        _badgePaint(canvas, _toScreen(at), color, _drawParallel);
      case ConstraintKind.equalLength:
        // Place an "=" badge near each of the two segments so the pairing reads.
        _badgePaint(
            canvas, _toScreen(_offsetMid(m, c.segments[0])), color, _drawEqual);
        _badgePaint(
            canvas, _toScreen(_offsetMid(m, c.segments[1])), color, _drawEqual);
      case ConstraintKind.tangent:
        final line = m.segments[c.segments[0]];
        final arc = m.segments[c.segments[1]];
        final shared = (line.a == arc.a || line.a == arc.b) ? line.a : line.b;
        _badgeText(canvas, _toScreen(m.points[shared]) + const Offset(0, -16),
            'T', color);
    }
  }

  // Glyph anchor: segment midpoint pushed off the line along its normal.
  Offset _offsetMid(ParametricSketch m, int si) =>
      m.segMid(si) + m.segNormal(si) * 16;

  void _badgeBg(Canvas canvas, Offset center, Color color) {
    final r = RRect.fromRectAndRadius(
        Rect.fromCenter(center: center, width: 18, height: 18),
        const Radius.circular(4));
    canvas.drawRRect(r, Paint()..color = const Color(0xCC1A2026));
    canvas.drawRRect(
        r,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
  }

  void _badgeText(Canvas canvas, Offset center, String label, Color color) {
    _badgeBg(canvas, center, color);
    final tp = TextPainter(
      text: TextSpan(
          text: label,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  void _badgePaint(Canvas canvas, Offset center, Color color,
      void Function(Canvas, Offset, Color) sym) {
    _badgeBg(canvas, center, color);
    sym(canvas, center, color);
  }

  void _drawPerp(Canvas canvas, Offset c, Color color) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    // A small right-angle symbol.
    canvas.drawLine(c + const Offset(-4, -5), c + const Offset(-4, 4), p);
    canvas.drawLine(c + const Offset(-4, 4), c + const Offset(5, 4), p);
    canvas.drawLine(c + const Offset(-4, 1), c + const Offset(-1, 1), p);
    canvas.drawLine(c + const Offset(-1, 1), c + const Offset(-1, 4), p);
  }

  void _drawParallel(Canvas canvas, Offset c, Color color) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawLine(c + const Offset(-3, -5), c + const Offset(-3, 5), p);
    canvas.drawLine(c + const Offset(3, -5), c + const Offset(3, 5), p);
  }

  void _drawEqual(Canvas canvas, Offset c, Color color) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawLine(c + const Offset(-5, -2), c + const Offset(5, -2), p);
    canvas.drawLine(c + const Offset(-5, 2), c + const Offset(5, 2), p);
  }

  static const _drivingColor = Color(0xFF4DD0E1); // accent — drives geometry
  static const _drivenColor = Color(0xFF90A4AE); // gray — reference only

  void _dimLabel(Canvas canvas, Offset center, String text, bool driving,
      {bool highlighted = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: highlighted
              ? Colors.white
              : (driving ? _drivingColor : _drivenColor),
          fontSize: 12,
          fontWeight: driving || highlighted ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: center, width: tp.width + 10, height: tp.height + 6),
        const Radius.circular(3));
    // Hover: brighter fill + accent border so it reads as a click target.
    canvas.drawRRect(
        rect, Paint()..color = highlighted ? const Color(0xFF2B3A47) : const Color(0xCC1A2026));
    if (highlighted) {
      canvas.drawRRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = _drivingColor);
    }
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  Path _polyline(List<Offset> pts) {
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    return path;
  }

  @override
  bool shouldRepaint(_SketchPainter old) => true;
}

// --- Dimension editing dialog ---

sealed class _DimAction {}

class _SetLiteral extends _DimAction {
  _SetLiteral(this.value);
  final double value;
}

class _BindParam extends _DimAction {
  _BindParam(this.name);
  final String name;
}

class _MakeDriven extends _DimAction {}

/// Edit a dimension: set a literal length, bind it to a shared parameter
/// (existing or new), or make it a driven (reference) dimension.
class _DimensionDialog extends StatefulWidget {
  const _DimensionDialog({
    required this.initial,
    required this.parameterNames,
    this.valueLabel = 'Length',
  });

  final double initial;
  final List<String> parameterNames;
  final String valueLabel;

  @override
  State<_DimensionDialog> createState() => _DimensionDialogState();
}

class _DimensionDialogState extends State<_DimensionDialog> {
  late final _length =
      TextEditingController(text: widget.initial.toStringAsFixed(1));
  final _newParam = TextEditingController();
  String? _selectedParam;

  @override
  void dispose() {
    _length.dispose();
    _newParam.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Dimension'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _length,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: widget.valueLabel),
            onSubmitted: (_) => _popLiteral(),
          ),
          const SizedBox(height: 16),
          const Text('Bind to shared parameter',
              style: TextStyle(fontSize: 12, color: Colors.white70)),
          if (widget.parameterNames.isNotEmpty)
            Wrap(
              spacing: 6,
              children: [
                for (final name in widget.parameterNames)
                  ChoiceChip(
                    label: Text(name),
                    selected: _selectedParam == name,
                    onSelected: (_) => setState(() => _selectedParam = name),
                  ),
              ],
            ),
          TextField(
            controller: _newParam,
            decoration: const InputDecoration(labelText: 'or new parameter name'),
            onChanged: (_) => setState(() => _selectedParam = null),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _MakeDriven()),
          child: const Text('Make driven'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _bindName == null
              ? null
              : () => Navigator.pop(context, _BindParam(_bindName!)),
          child: const Text('Bind'),
        ),
        FilledButton(
          onPressed: _popLiteral,
          child: const Text('Set'),
        ),
      ],
    );
  }

  String? get _bindName {
    final typed = _newParam.text.trim();
    if (typed.isNotEmpty) return typed;
    return _selectedParam;
  }

  void _popLiteral() {
    final v = double.tryParse(_length.text);
    if (v != null) Navigator.pop(context, _SetLiteral(v));
  }
}
