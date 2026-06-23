import 'package:flutter/material.dart';

import '../sketch/decomposition.dart';
import '../sketch/model.dart';
import '../sketch/plane.dart';
import '../sketch/solid.dart';
import 'camera.dart';
import 'sketch_canvas.dart';

// The unified 3D scene: sketch on a plane while orbiting, watch it extrude, and
// "Decompose" the massing into one part per enclosed region with auto-captured
// mating surfaces. Two input modes share the orbit camera:
//   • Sketch mode — camera snaps face-on to the active plane; strokes are
//     unprojected onto the plane and fed to the master sketch (recognized +
//     solved by the existing 2D pipeline, kernel unchanged).
//   • Orbit mode — drag to rotate, drag the explode slider to inspect parts.
// The decomposition is recomputed from the live sketch every build, so drawing
// (or editing a dimension/parameter) reflows the parts — associative by
// recompute, no stored derived geometry.
class SceneView extends StatefulWidget {
  const SceneView({super.key, required this.controller});

  final SketchController controller;

  @override
  State<SceneView> createState() => _SceneViewState();
}

class _SceneViewState extends State<SceneView> {
  // Master sketch plane (region-partition Phase 1 sketches on base XY).
  static const _plane = SketchPlane.xy;

  double _yaw = 0.6;
  double _pitch = -0.5;
  double _explode = 0;
  bool _sketchMode = true;

  // In-progress stroke (screen-space points) while drawing.
  List<Offset>? _stroke;

  static const double _tapSlop = 10.0;

  static const _palette = [
    Color(0xFF4DD0E1),
    Color(0xFFFFC857),
    Color(0xFFE57373),
    Color(0xFF81C784),
    Color(0xFFBA68C8),
    Color(0xFF64B5F6),
    Color(0xFFFFB74D),
    Color(0xFF4DB6AC),
  ];

  void _orbit(Offset d) => setState(() {
        _yaw += d.dx * 0.01;
        _pitch = (_pitch + d.dy * 0.01).clamp(-1.5, 1.5);
      });

  // Face-on angles for sketching on the base XY plane (looking down +Z).
  void _toggleSketch() => setState(() {
        _sketchMode = !_sketchMode;
        if (_sketchMode) {
          _yaw = 0;
          _pitch = 0;
        }
      });

  Camera _camera(Size size, Decomposition decomp) {
    final empty = decomp.isEmpty;
    return Camera(
      size: size,
      center: empty ? const Vec3(0, 0, 0) : decomp.center,
      radius: empty ? 150 : decomp.radius * (1 + _explode * 1.4) + 1,
      yaw: _sketchMode ? 0 : _yaw,
      pitch: _sketchMode ? 0 : _pitch,
    );
  }

  void _endStroke(Size size, Decomposition decomp) {
    final stroke = _stroke;
    setState(() => _stroke = null);
    if (stroke == null || stroke.length < 2) return;
    final extent =
        stroke.fold(0.0, (m, p) => (p - stroke.first).distance.clamp(m, 1e9));
    if (extent < _tapSlop) return; // tap: dimension editing on-plane is future
    final cam = _camera(size, decomp);
    final planePts = [for (final s in stroke) cam.unprojectToPlane(s, _plane)];
    widget.controller.addStroke(planePts);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sketch & decompose'),
        actions: [
          IconButton(
            tooltip: _sketchMode ? 'Sketch mode (drawing)' : 'Orbit mode',
            isSelected: _sketchMode,
            icon: Icon(_sketchMode ? Icons.edit : Icons.threed_rotation),
            onPressed: _toggleSketch,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final part = widget.controller.active;
          final decomp = decompose(part.sketch,
              depth: part.depth, depthOverrides: widget.controller.regionDepths);
          return Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final size = constraints.biggest;
                    final painter = _ScenePainter(
                        decomp, part.sketch, _plane, _camera(size, decomp),
                        _explode, _stroke, _palette);
                    final canvas = CustomPaint(painter: painter, size: Size.infinite);
                    return _sketchMode
                        ? Listener(
                            behavior: HitTestBehavior.opaque,
                            onPointerDown: (e) =>
                                setState(() => _stroke = [e.localPosition]),
                            onPointerMove: (e) =>
                                setState(() => _stroke?.add(e.localPosition)),
                            onPointerUp: (e) => _endStroke(size, decomp),
                            onPointerCancel: (e) => _endStroke(size, decomp),
                            child: canvas,
                          )
                        : GestureDetector(
                            onPanUpdate: (e) => _orbit(e.delta),
                            child: canvas,
                          );
                  },
                ),
              ),
              _controls(decomp),
            ],
          );
        },
      ),
    );
  }

  Widget _controls(Decomposition decomp) {
    return Container(
      color: const Color(0xFF161C22),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            _sketchMode
                ? 'Draw on the plane'
                : '${decomp.parts.length} part${decomp.parts.length == 1 ? '' : 's'}'
                    ' · ${decomp.mates.length} mate${decomp.mates.length == 1 ? '' : 's'}',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(width: 16),
          const Icon(Icons.open_in_full, size: 16, color: Colors.white54),
          Expanded(
            child: Slider(
              value: _explode,
              onChanged:
                  _sketchMode ? null : (v) => setState(() => _explode = v),
            ),
          ),
          const Text('Depth', style: TextStyle(color: Colors.white54, fontSize: 12)),
          SizedBox(
            width: 160,
            child: Slider(
              value: widget.controller.active.depth.clamp(5, 400),
              min: 5,
              max: 400,
              onChanged: (v) => widget.controller.setDepth(v),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScenePainter extends CustomPainter {
  _ScenePainter(this.decomp, this.sketch, this.plane, this.cam, this.explode,
      this.stroke, this.palette);

  final Decomposition decomp;
  final ParametricSketch sketch;
  final SketchPlane plane;
  final Camera cam;
  final double explode;
  final List<Offset>? stroke;
  final List<Color> palette;

  @override
  void paint(Canvas canvas, Size size) {
    _drawPlaneAxes(canvas);

    // Live master sketch on the plane (so drawing shows immediately, even
    // before it closes into extrudable regions).
    final sketchPaint = Paint()
      ..color = Colors.cyanAccent.shade400
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final node = Paint()..color = Colors.cyanAccent.shade100;
    for (final seg in sketch.segments) {
      canvas.drawLine(cam.project(plane.to3d(sketch.points[seg.a])),
          cam.project(plane.to3d(sketch.points[seg.b])), sketchPaint);
    }
    for (final p in sketch.points) {
      canvas.drawCircle(cam.project(plane.to3d(p)), 3, node);
    }

    // Decomposed parts: per-part wireframe shifted by its explode offset.
    for (var pi = 0; pi < decomp.parts.length; pi++) {
      final solid = decomp.parts[pi].solid;
      final shift = decomp.explodeOffset(pi, explode);
      final paint = Paint()
        ..color = palette[pi % palette.length]
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round;
      for (final e in solid.edges) {
        canvas.drawLine(cam.project(solid.vertices[e[0]] + shift),
            cam.project(solid.vertices[e[1]] + shift), paint);
      }
    }

    // Auto-captured mating surfaces: a white stub (centroid + normal) per side.
    final mateDot = Paint()..color = Colors.white;
    final mateLine = Paint()
      ..color = Colors.white70
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final m in decomp.mates) {
      _drawConnector(canvas, m.partA, m.faceA, mateDot, mateLine);
      _drawConnector(canvas, m.partB, m.faceB, mateDot, mateLine);
    }

    // In-progress stroke (raw screen space).
    final s = stroke;
    if (s != null && s.length >= 2) {
      final raw = Paint()
        ..color = Colors.blueGrey.shade300
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round;
      final path = Path()..moveTo(s.first.dx, s.first.dy);
      for (var i = 1; i < s.length; i++) {
        path.lineTo(s[i].dx, s[i].dy);
      }
      canvas.drawPath(path, raw);
    }
  }

  // Faint origin axes of the active plane for orientation while orbiting.
  void _drawPlaneAxes(Canvas canvas) {
    final ext = decomp.isEmpty ? 120.0 : decomp.radius;
    final axis = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    canvas.drawLine(cam.project(plane.to3d(Offset(-ext, 0))),
        cam.project(plane.to3d(Offset(ext, 0))), axis);
    canvas.drawLine(cam.project(plane.to3d(Offset(0, -ext))),
        cam.project(plane.to3d(Offset(0, ext))), axis);
  }

  void _drawConnector(Canvas canvas, int part, int face, Paint dot, Paint line) {
    final solid = decomp.parts[part].solid;
    final shift = decomp.explodeOffset(part, explode);
    final origin = solid.faceCentroid(face) + shift;
    final tip = origin + solid.faceNormal(face) * (decomp.radius * 0.12);
    final o = cam.project(origin);
    canvas.drawCircle(o, 3, dot);
    canvas.drawLine(o, cam.project(tip), line);
  }

  @override
  bool shouldRepaint(_ScenePainter old) => true;
}
