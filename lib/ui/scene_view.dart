import 'package:flutter/material.dart';

import '../sketch/decomposition.dart';
import '../sketch/model.dart';
import '../sketch/plane.dart';
import '../sketch/solid.dart';
import 'camera.dart';
import 'sketch_canvas.dart';

// The unified workspace: a split view with the 3D assembly (orbit) on one side
// and the 2D sketch on the active plane on the other — no orbit/sketch mode
// toggle. You draw with the full 2D tooling on the right; the left orbits the
// extruded massing and its region-partition decomposition, recomputed from the
// live sketch every build (associative). Tap a part in 3D to drill in and edit
// its own depth.
//
// Phase: the active plane is the base XY plane. Selecting a body FACE to set the
// sketch plane (true multi-plane / "rough 3D by construction") is the next
// increment — it needs the multi-sketch SketchOnPlane model.
class SceneView extends StatefulWidget {
  const SceneView({super.key, required this.controller});

  final SketchController controller;

  @override
  State<SceneView> createState() => _SceneViewState();
}

class _SceneViewState extends State<SceneView> {
  static const _plane = SketchPlane.xy;

  double _yaw = 0.6;
  double _pitch = -0.5;
  double _explode = 0;
  int? _selected; // part drilled into

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

  Camera _camera(Size size, Decomposition decomp) {
    final empty = decomp.isEmpty;
    return Camera(
      size: size,
      center: empty ? const Vec3(0, 0, 0) : decomp.center,
      radius: empty ? 150 : decomp.radius * (1 + _explode * 1.4) + 1,
      yaw: _yaw,
      pitch: _pitch,
    );
  }

  /// Front-most part whose projected solid contains [p], or null (deselect).
  int? _partAt(Offset p, Decomposition decomp, Camera cam) {
    int? best;
    var bestDepth = -double.infinity;
    for (var pi = 0; pi < decomp.parts.length; pi++) {
      final solid = decomp.parts[pi].solid;
      final shift = decomp.explodeOffset(pi, _explode);
      for (final ring in solid.faces) {
        final poly = [for (final i in ring) cam.project(solid.vertices[i] + shift)];
        if (!_pointInPoly(p, poly)) continue;
        var d = 0.0;
        for (final i in ring) {
          d += cam.depthOf(solid.vertices[i] + shift);
        }
        d /= ring.length;
        if (d > bestDepth) {
          bestDepth = d;
          best = pi;
        }
      }
    }
    return best;
  }

  static bool _pointInPoly(Offset p, List<Offset> poly) {
    var inside = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final a = poly[i], b = poly[j];
      if ((a.dy > p.dy) != (b.dy > p.dy) &&
          p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
        inside = !inside;
      }
    }
    return inside;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Workspace · sketch + assembly')),
      body: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final part = widget.controller.active;
          final decomp = decompose(part.sketch,
              depth: part.depth, depthOverrides: widget.controller.regionDepths);
          return LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 720;
              final pane3d = _pane3d(decomp);
              final pane2d = _pane2d();
              return Column(
                children: [
                  Expanded(
                    child: wide
                        ? Row(
                            children: [
                              Expanded(flex: 11, child: pane3d),
                              const VerticalDivider(width: 1),
                              Expanded(flex: 9, child: pane2d),
                            ],
                          )
                        : Column(
                            children: [
                              Expanded(child: pane3d),
                              const Divider(height: 1),
                              Expanded(child: pane2d),
                            ],
                          ),
                  ),
                  _controls(decomp),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _pane3d(Decomposition decomp) {
    return Container(
      color: const Color(0xFF0E1216),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final cam = _camera(size, decomp);
          return GestureDetector(
            onPanUpdate: (e) => _orbit(e.delta),
            onTapUp: (e) =>
                setState(() => _selected = _partAt(e.localPosition, decomp, cam)),
            child: CustomPaint(
              painter: _ScenePainter(decomp, widget.controller.active.sketch,
                  _plane, cam, _explode, _selected, _palette),
              size: Size.infinite,
            ),
          );
        },
      ),
    );
  }

  Widget _pane2d() {
    return Container(
      color: const Color(0xFF101418),
      child: Stack(
        children: [
          SketchCanvas(controller: widget.controller),
          const Positioned(
            left: 8,
            top: 6,
            child: Text('Sketch · base plane',
                style: TextStyle(color: Colors.white38, fontSize: 11)),
          ),
        ],
      ),
    );
  }

  Widget _controls(Decomposition decomp) {
    final sel = _selected;
    final c = widget.controller;
    final body = sel != null && sel < decomp.parts.length
        ? Row(
            children: [
              IconButton(
                tooltip: 'Back to assembly',
                icon: const Icon(Icons.arrow_back, size: 18),
                onPressed: () => setState(() => _selected = null),
              ),
              Text(decomp.parts[sel].name,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
              const SizedBox(width: 12),
              const Text('Depth',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              Expanded(
                child: Slider(
                  value: (c.regionDepths[sel] ?? c.active.depth).clamp(5, 400),
                  min: 5,
                  max: 400,
                  onChanged: (v) => c.setRegionDepth(sel, v),
                ),
              ),
              if (c.regionDepths.containsKey(sel))
                IconButton(
                  tooltip: 'Reset to base depth',
                  icon: const Icon(Icons.restart_alt, size: 18),
                  onPressed: () => c.clearRegionDepth(sel),
                ),
            ],
          )
        : Row(
            children: [
              Text(
                '${decomp.parts.length} part${decomp.parts.length == 1 ? '' : 's'}'
                ' · ${decomp.mates.length} mate${decomp.mates.length == 1 ? '' : 's'}'
                '${decomp.parts.isEmpty ? '' : ' · tap a part'}',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(width: 16),
              const Icon(Icons.open_in_full, size: 16, color: Colors.white54),
              Expanded(
                child: Slider(
                  value: _explode,
                  onChanged: (v) => setState(() => _explode = v),
                ),
              ),
              const Text('Depth',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              SizedBox(
                width: 160,
                child: Slider(
                  value: c.active.depth.clamp(5, 400),
                  min: 5,
                  max: 400,
                  onChanged: (v) => c.setDepth(v),
                ),
              ),
            ],
          );
    return Container(
      color: const Color(0xFF161C22),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: body,
    );
  }
}

class _ScenePainter extends CustomPainter {
  _ScenePainter(this.decomp, this.sketch, this.plane, this.cam, this.explode,
      this.selected, this.palette);

  final Decomposition decomp;
  final ParametricSketch sketch;
  final SketchPlane plane;
  final Camera cam;
  final double explode;
  final int? selected;
  final List<Color> palette;

  @override
  void paint(Canvas canvas, Size size) {
    _drawPlaneAxes(canvas);

    // Live master sketch on the plane (context alongside the 3D result).
    final sketchPaint = Paint()
      ..color = Colors.cyanAccent.shade700
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    for (final seg in sketch.segments) {
      canvas.drawLine(cam.project(plane.to3d(sketch.points[seg.a])),
          cam.project(plane.to3d(sketch.points[seg.b])), sketchPaint);
    }

    // Decomposed parts: per-part wireframe shifted by its explode offset.
    for (var pi = 0; pi < decomp.parts.length; pi++) {
      final solid = decomp.parts[pi].solid;
      final shift = decomp.explodeOffset(pi, explode);
      final isSel = pi == selected;
      final paint = Paint()
        ..color = isSel ? Colors.white : palette[pi % palette.length]
        ..style = PaintingStyle.stroke
        ..strokeWidth = isSel ? 2.6 : 1.6
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
  }

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
