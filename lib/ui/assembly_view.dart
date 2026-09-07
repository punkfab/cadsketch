import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../sketch/assembly.dart';
import '../sketch/solid.dart';
import 'camera.dart';
import 'sketch_canvas.dart';

/// Shared 3D scene: every part's extrude rendered in world space (per-part
/// color), assembled by mates. Tap two connectors (on different parts) to
/// fasten them; the assembly re-solves and snaps together.
class AssemblyView extends StatefulWidget {
  const AssemblyView({super.key, required this.controller});

  final SketchController controller;

  @override
  State<AssemblyView> createState() => _AssemblyViewState();
}

class _AssemblyViewState extends State<AssemblyView> {
  double _yaw = 0.6;
  double _pitch = -0.5;
  double _zoom = 1; // scroll-wheel / pinch zoom (shrinks the fit radius)
  bool _moved = false;
  Camera? _camera;
  ({int part, int connector})? _selected;

  static const _palette = [
    Color(0xFF4DD0E1),
    Color(0xFFFFB74D),
    Color(0xFF81C784),
    Color(0xFFE57373),
    Color(0xFFBA68C8),
  ];

  void _orbit(Offset d) {
    setState(() {
      _moved = true;
      _yaw += d.dx * 0.01;
      _pitch = (_pitch + d.dy * 0.01).clamp(-math.pi / 2, math.pi / 2);
    });
  }

  // Scroll up (negative delta) zooms in. Clamped so the model can't be lost.
  void _zoomBy(double dy) => setState(() {
        _zoom = (_zoom * (dy > 0 ? 1 / 1.12 : 1.12)).clamp(0.2, 12.0);
      });

  void _tap(Offset p, List<_PartScene> scenes) {
    final cam = _camera;
    if (cam == null) return;
    ({int part, int connector})? hit;
    var bestDist = 16.0;
    for (final s in scenes) {
      for (var j = 0; j < s.connectors.length; j++) {
        final d = (cam.project(s.connectors[j]) - p).distance;
        if (d < bestDist) {
          bestDist = d;
          hit = (part: s.partIndex, connector: j);
        }
      }
    }
    if (hit == null) return;
    // Tapping an already-mated point unmates it.
    final existing = widget.controller.mateIndexFor(hit.part, hit.connector);
    if (existing != null) {
      widget.controller.removeMate(existing);
      setState(() => _selected = null);
      return;
    }
    final sel = _selected;
    if (sel == null) {
      setState(() => _selected = hit);
    } else if (sel.part != hit.part) {
      widget.controller.addMate(sel.part, sel.connector, hit.part, hit.connector);
      setState(() => _selected = null);
    } else {
      setState(() => _selected = hit); // re-pick on same part
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final scenes = _buildScenes();
        return Scaffold(
          appBar: AppBar(
            title: const Text('Assembly'),
            actions: [
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('${widget.controller.mates.length} mates',
                      style: const TextStyle(fontSize: 12, color: Color(0xFFFFC857))),
                ),
              ),
              if (widget.controller.mates.isNotEmpty)
                IconButton(
                  tooltip: 'Clear all mates',
                  icon: const Icon(Icons.link_off),
                  onPressed: () => widget.controller.clearMates(),
                ),
            ],
          ),
          body: scenes.isEmpty
              ? const Center(
                  child: Text('No parts with a closed profile to assemble.'))
              : Column(
                  children: [
                    Expanded(
                      child: LayoutBuilder(builder: (context, c) {
                        final cam = _fitCamera(Size(c.maxWidth, c.maxHeight), scenes);
                        _camera = cam;
                        return Listener(
                          onPointerDown: (_) => _moved = false,
                          onPointerMove: (e) => _orbit(e.delta),
                          onPointerUp: (e) {
                            if (!_moved) _tap(e.localPosition, scenes);
                          },
                          onPointerSignal: (e) {
                            if (e is PointerScrollEvent) {
                              _zoomBy(e.scrollDelta.dy);
                            }
                          },
                          child: Container(
                            color: const Color(0xFF101418),
                            child: CustomPaint(
                              painter: _ScenePainter(scenes, cam, _selected),
                              size: Size.infinite,
                            ),
                          ),
                        );
                      }),
                    ),
                    const Padding(
                      padding: EdgeInsets.all(10),
                      child: Text('Tap two mate points on different parts to fasten; '
                          'tap a mated point to unmate.',
                          style: TextStyle(fontSize: 12, color: Colors.white54)),
                    ),
                  ],
                ),
        );
      },
    );
  }

  List<_PartScene> _buildScenes() {
    final parts = widget.controller.parts;
    final transforms = solveAssembly(parts, widget.controller.mates);
    final scenes = <_PartScene>[];
    for (var i = 0; i < parts.length; i++) {
      final solid = parts[i].buildSolid();
      if (solid == null) continue;
      final xf = transforms[i]!;
      scenes.add(_PartScene(
        partIndex: i,
        color: _palette[i % _palette.length],
        verts: [for (final v in solid.vertices) xf.apply(v)],
        edges: solid.edges,
        connectors: [for (final con in parts[i].connectors) xf.apply(con.origin(solid))],
      ));
    }
    return scenes;
  }

  Camera _fitCamera(Size size, List<_PartScene> scenes) {
    final all = [for (final s in scenes) ...s.verts];
    var c = const Vec3(0, 0, 0);
    for (final v in all) {
      c = c + v;
    }
    c = c * (1.0 / all.length);
    var r = 0.0;
    for (final v in all) {
      r = math.max(r, (v - c).length);
    }
    return Camera(
        size: size, center: c, radius: r / _zoom, yaw: _yaw, pitch: _pitch);
  }
}

class _PartScene {
  _PartScene({
    required this.partIndex,
    required this.color,
    required this.verts,
    required this.edges,
    required this.connectors,
  });
  final int partIndex;
  final Color color;
  final List<Vec3> verts;
  final List<List<int>> edges;
  final List<Vec3> connectors;
}

class _ScenePainter extends CustomPainter {
  _ScenePainter(this.scenes, this.cam, this.selected);

  final List<_PartScene> scenes;
  final Camera cam;
  final ({int part, int connector})? selected;

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in scenes) {
      final edge = Paint()
        ..color = s.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6;
      for (final e in s.edges) {
        canvas.drawLine(cam.project(s.verts[e[0]]), cam.project(s.verts[e[1]]), edge);
      }
      for (var j = 0; j < s.connectors.length; j++) {
        final isSel = selected?.part == s.partIndex && selected?.connector == j;
        final p = cam.project(s.connectors[j]);
        canvas.drawCircle(p, isSel ? 7 : 4,
            Paint()..color = isSel ? Colors.white : const Color(0xFFFFC857));
      }
    }
  }

  @override
  bool shouldRepaint(_ScenePainter old) => true;
}
