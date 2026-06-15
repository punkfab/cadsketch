import 'package:flutter/material.dart';

import '../sketch/assembly.dart';
import '../sketch/beautify.dart';
import '../sketch/entities.dart';
import '../sketch/model.dart';
import '../sketch/part.dart';

/// Captures strokes; lines feed the parametric model (inferred + solved),
/// everything else is kept as a decorative entity. Constraints are rendered
/// as CAD-style glyphs over the geometry.
class SketchCanvas extends StatefulWidget {
  const SketchCanvas({super.key, required this.controller});

  final SketchController controller;

  @override
  State<SketchCanvas> createState() => _SketchCanvasState();
}

class _SketchCanvasState extends State<SketchCanvas> {
  List<Offset>? _active;

  /// Movement below this (logical px) counts as a tap, not a stroke.
  static const double _tapSlop = 6.0;

  void _start(Offset p) => setState(() => _active = [p]);
  void _extend(Offset p) => setState(() => _active?.add(p));

  void _end() {
    final stroke = _active;
    setState(() => _active = null);
    if (stroke == null || stroke.isEmpty) return;

    // Tap (little movement) → maybe edit a dimension; otherwise it's a stroke.
    final extent =
        stroke.fold(0.0, (m, p) => (p - stroke.first).distance.clamp(m, 1e9));
    if (extent < _tapSlop) {
      _handleTap(stroke.first);
      return;
    }
    if (stroke.length >= 2) {
      widget.controller.addStroke(stroke);
    }
  }

  void _handleTap(Offset p) {
    final si = widget.controller.model.hitTestDimension(p);
    if (si != null) _editDimension(si);
  }

  Future<void> _editDimension(int si) async {
    final model = widget.controller.model;
    final current = model.segments[si].drivingLength ?? model.measuredLength(si);
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
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) => _start(e.localPosition),
      onPointerMove: (e) => _extend(e.localPosition),
      onPointerUp: (e) => _end(),
      onPointerCancel: (e) => _end(),
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) => CustomPaint(
          painter: _SketchPainter(widget.controller, _active),
          size: Size.infinite,
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

  void setActive(int index) {
    if (index < 0 || index >= parts.length || index == activeIndex) return;
    activeIndex = index;
    notifyListeners();
  }

  void addStroke(List<Offset> points) {
    final result = recognizeStroke(points);
    switch (result) {
      case PolylineResult(:final vertices):
        model.addPolyline(vertices);
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

  /// Sets a shared parameter's value and re-solves every part that binds it.
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
    }
    notifyListeners();
  }

  void setDepth(double depth) {
    active.depth = depth;
    notifyListeners();
  }

  void addConnector(int faceIndex) {
    active.connectors.add(MateConnector(faceIndex));
    notifyListeners();
  }

  void addMate(int partA, int connectorA, int partB, int connectorB) {
    mates.add(Mate(partA, connectorA, partB, connectorB));
    notifyListeners();
  }

  void clear() {
    model.clear();
    decorations.clear();
    active.connectors.clear();
    notifyListeners();
  }
}

class _SketchPainter extends CustomPainter {
  _SketchPainter(this.controller, this.active);

  final SketchController controller;
  final List<Offset>? active;

  static const _glyphColor = Color(0xFFFFC857);

  @override
  void paint(Canvas canvas, Size size) {
    final raw = Paint()
      ..color = Colors.blueGrey.shade400
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    final line = Paint()
      ..color = Colors.cyanAccent.shade400
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final node = Paint()..color = Colors.cyanAccent.shade100;
    final junction = Paint()
      ..color = _glyphColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    // Decorative entities (non-line).
    for (final e in controller.decorations) {
      switch (e) {
        case RawStroke(:final points):
          canvas.drawPath(_polyline(points), raw);
        case LineEntity():
          break; // lines live in the model
        case CircleEntity(:final center, :final radius):
          canvas.drawCircle(center, radius, line);
          canvas.drawCircle(center, 3, node);
        case ArcEntity(
            :final center,
            :final radius,
            :final startAngle,
            :final sweepAngle
          ):
          canvas.drawArc(Rect.fromCircle(center: center, radius: radius),
              startAngle, sweepAngle, false, line);
          canvas.drawCircle(center, 3, node);
      }
    }

    final m = controller.model;

    // Solved segments.
    for (final s in m.segments) {
      canvas.drawLine(m.points[s.a], m.points[s.b], line);
    }
    // Point nodes; shared points (degree >= 2) get a coincident ring.
    for (var i = 0; i < m.points.length; i++) {
      final p = m.points[i];
      canvas.drawCircle(p, 3, node);
      if (m.degree(i) >= 2) canvas.drawCircle(p, 6, junction);
    }
    // Constraint glyphs.
    for (final c in m.constraints) {
      _drawConstraint(canvas, m, c);
    }
    // Dimension labels: driving (accent, editable) vs driven (gray reference).
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
      _dimLabel(canvas, m.dimAnchor(si), label, isDriving);
    }

    // In-progress stroke.
    final a = active;
    if (a != null && a.length >= 2) canvas.drawPath(_polyline(a), raw);
  }

  void _drawConstraint(Canvas canvas, ParametricSketch m, SketchConstraint c) {
    switch (c.kind) {
      case ConstraintKind.horizontal:
        _badgeText(canvas, _offsetMid(m, c.segments[0]), 'H');
      case ConstraintKind.vertical:
        _badgeText(canvas, _offsetMid(m, c.segments[0]), 'V');
      case ConstraintKind.perpendicular:
        final at = (_offsetMid(m, c.segments[0]) +
                _offsetMid(m, c.segments[1])) /
            2;
        _badgePaint(canvas, at, _drawPerp);
      case ConstraintKind.parallel:
        final at = (_offsetMid(m, c.segments[0]) +
                _offsetMid(m, c.segments[1])) /
            2;
        _badgePaint(canvas, at, _drawParallel);
      case ConstraintKind.equalLength:
        // Place an "=" badge near each of the two segments so the pairing reads.
        _badgePaint(canvas, _offsetMid(m, c.segments[0]), _drawEqual);
        _badgePaint(canvas, _offsetMid(m, c.segments[1]), _drawEqual);
    }
  }

  // Glyph anchor: segment midpoint pushed off the line along its normal.
  Offset _offsetMid(ParametricSketch m, int si) =>
      m.segMid(si) + m.segNormal(si) * 16;

  void _badgeBg(Canvas canvas, Offset center) {
    final r = RRect.fromRectAndRadius(
        Rect.fromCenter(center: center, width: 18, height: 18),
        const Radius.circular(4));
    canvas.drawRRect(r, Paint()..color = const Color(0xCC1A2026));
    canvas.drawRRect(
        r,
        Paint()
          ..color = _glyphColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
  }

  void _badgeText(Canvas canvas, Offset center, String label) {
    _badgeBg(canvas, center);
    final tp = TextPainter(
      text: TextSpan(
          text: label,
          style: const TextStyle(
              color: _glyphColor, fontSize: 11, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  void _badgePaint(Canvas canvas, Offset center, void Function(Canvas, Offset) sym) {
    _badgeBg(canvas, center);
    sym(canvas, center);
  }

  void _drawPerp(Canvas canvas, Offset c) {
    final p = Paint()
      ..color = _glyphColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    // A small right-angle symbol.
    canvas.drawLine(c + const Offset(-4, -5), c + const Offset(-4, 4), p);
    canvas.drawLine(c + const Offset(-4, 4), c + const Offset(5, 4), p);
    canvas.drawLine(c + const Offset(-4, 1), c + const Offset(-1, 1), p);
    canvas.drawLine(c + const Offset(-1, 1), c + const Offset(-1, 4), p);
  }

  void _drawParallel(Canvas canvas, Offset c) {
    final p = Paint()
      ..color = _glyphColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawLine(c + const Offset(-3, -5), c + const Offset(-3, 5), p);
    canvas.drawLine(c + const Offset(3, -5), c + const Offset(3, 5), p);
  }

  void _drawEqual(Canvas canvas, Offset c) {
    final p = Paint()
      ..color = _glyphColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawLine(c + const Offset(-5, -2), c + const Offset(5, -2), p);
    canvas.drawLine(c + const Offset(-5, 2), c + const Offset(5, 2), p);
  }

  static const _drivingColor = Color(0xFF4DD0E1); // accent — drives geometry
  static const _drivenColor = Color(0xFF90A4AE); // gray — reference only

  void _dimLabel(Canvas canvas, Offset center, String text, bool driving) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: driving ? _drivingColor : _drivenColor,
          fontSize: 12,
          fontWeight: driving ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: center, width: tp.width + 8, height: tp.height + 4),
        const Radius.circular(3));
    canvas.drawRRect(rect, Paint()..color = const Color(0xCC1A2026));
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
  const _DimensionDialog({required this.initial, required this.parameterNames});

  final double initial;
  final List<String> parameterNames;

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
            decoration: const InputDecoration(labelText: 'Length'),
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
