import 'package:flutter/material.dart';

import '../sketch/decomposition.dart';
import 'camera.dart';
import 'sketch_canvas.dart';

// The unified 3D scene for top-down decomposition: orbit the active sketch's
// extruded massing, "Decompose" it into one part per enclosed region, and
// explode to inspect the auto-captured mating surfaces. The decomposition is
// recomputed from the live sketch on every build, so editing a dimension or a
// shared parameter and returning here reflows the parts — associativity by
// recompute, no stored derived geometry.
class SceneView extends StatefulWidget {
  const SceneView({super.key, required this.controller});

  final SketchController controller;

  @override
  State<SceneView> createState() => _SceneViewState();
}

class _SceneViewState extends State<SceneView> {
  double _yaw = 0.6;
  double _pitch = -0.5;
  double _explode = 0;

  void _orbit(Offset d) => setState(() {
        _yaw += d.dx * 0.01;
        _pitch = (_pitch + d.dy * 0.01).clamp(-1.5, 1.5);
      });

  // Distinct per-part colors so the decomposition reads at a glance.
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Decompose')),
      body: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final part = widget.controller.active;
          final decomp = decompose(part.sketch, depth: part.depth);
          return Column(
            children: [
              Expanded(
                child: decomp.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Draw a closed master profile (optionally with '
                            'internal dividing lines), then it splits into one '
                            'part per region.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white60),
                          ),
                        ),
                      )
                    : GestureDetector(
                        onPanUpdate: (e) => _orbit(e.delta),
                        child: CustomPaint(
                          painter: _ScenePainter(decomp, _explode, _yaw, _pitch,
                              _palette),
                          size: Size.infinite,
                        ),
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
            '${decomp.parts.length} part${decomp.parts.length == 1 ? '' : 's'}'
            ' · ${decomp.mates.length} mate${decomp.mates.length == 1 ? '' : 's'}',
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
  _ScenePainter(this.decomp, this.explode, this.yaw, this.pitch, this.palette);

  final Decomposition decomp;
  final double explode;
  final double yaw, pitch;
  final List<Color> palette;

  @override
  void paint(Canvas canvas, Size size) {
    final cam = Camera(
      size: size,
      center: decomp.center,
      radius: decomp.radius * (1 + explode * 1.4) + 1,
      yaw: yaw,
      pitch: pitch,
    );

    // Per-part wireframe, each shifted by its explode offset.
    for (var pi = 0; pi < decomp.parts.length; pi++) {
      final solid = decomp.parts[pi].solid;
      final shift = decomp.explodeOffset(pi, explode);
      final paint = Paint()
        ..color = palette[pi % palette.length]
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round;
      for (final e in solid.edges) {
        canvas.drawLine(
          cam.project(solid.vertices[e[0]] + shift),
          cam.project(solid.vertices[e[1]] + shift),
          paint,
        );
      }
    }

    // Auto-captured mating surfaces: a stub (centroid dot + normal) on each side
    // of every derived mate, drawn white so the shared faces stand out.
    final mateDot = Paint()..color = Colors.white;
    final mateLine = Paint()
      ..color = Colors.white70
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final m in decomp.mates) {
      _drawConnector(canvas, cam, decomp, m.partA, m.faceA, mateDot, mateLine);
      _drawConnector(canvas, cam, decomp, m.partB, m.faceB, mateDot, mateLine);
    }
  }

  void _drawConnector(Canvas canvas, Camera cam, Decomposition decomp, int part,
      int face, Paint dot, Paint line) {
    final solid = decomp.parts[part].solid;
    final shift = decomp.explodeOffset(part, explode);
    final origin = solid.faceCentroid(face) + shift;
    final tip = origin + solid.faceNormal(face) * (decomp.radius * 0.12);
    final o = cam.project(origin);
    canvas.drawCircle(o, 3, dot);
    canvas.drawLine(o, cam.project(tip), line);
  }

  @override
  bool shouldRepaint(_ScenePainter old) =>
      old.explode != explode ||
      old.yaw != yaw ||
      old.pitch != pitch ||
      !identical(old.decomp, decomp);
}
