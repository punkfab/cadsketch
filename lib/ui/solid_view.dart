import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../sketch/part.dart';
import '../sketch/solid.dart';
import 'sketch_canvas.dart';

/// Pseudo-3D wireframe view of the active part's extrude. Orthographic
/// projection in CustomPaint — no 3D engine. Drag to orbit, slider sets depth,
/// tap a face to drop a mate connector. Real shaded 3D is deferred to native.
class SolidView extends StatefulWidget {
  const SolidView({super.key, required this.controller});

  final SketchController controller;

  @override
  State<SolidView> createState() => _SolidViewState();
}

class _SolidViewState extends State<SolidView> {
  double _yaw = 0.6;
  double _pitch = -0.5;
  bool _moved = false;
  _Camera? _camera; // last camera built this frame, for hit-testing

  void _orbit(Offset delta) {
    setState(() {
      _moved = true;
      _yaw += delta.dx * 0.01;
      _pitch = (_pitch + delta.dy * 0.01).clamp(-math.pi / 2, math.pi / 2);
    });
  }

  void _tap(Offset p, Solid solid) {
    final cam = _camera;
    if (cam == null) return;
    final face = _faceAt(p, solid, cam);
    if (face != null) widget.controller.addConnector(face);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final part = widget.controller.active;
        final solid = part.buildSolid();
        return Scaffold(
          appBar: AppBar(
            title: Text('${part.name} — wireframe'),
            actions: [
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('${part.connectors.length} connectors',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFFFFC857))),
                ),
              ),
            ],
          ),
          body: solid == null
              ? const Center(
                  child: Text('Active part has no closed profile to extrude.'))
              : Column(
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, c) {
                          final cam = _Camera(
                            size: Size(c.maxWidth, c.maxHeight),
                            solid: solid,
                            yaw: _yaw,
                            pitch: _pitch,
                          );
                          _camera = cam;
                          return Listener(
                            onPointerDown: (_) => _moved = false,
                            onPointerMove: (e) => _orbit(e.delta),
                            onPointerUp: (e) {
                              if (!_moved) _tap(e.localPosition, solid);
                            },
                            child: Container(
                              color: const Color(0xFF101418),
                              child: CustomPaint(
                                painter: _WirePainter(solid, part, cam),
                                size: Size.infinite,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    _depthSlider(part),
                  ],
                ),
        );
      },
    );
  }

  Widget _depthSlider(Part part) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const Text('Depth'),
            Expanded(
              child: Slider(
                min: 10,
                max: 400,
                value: part.depth.clamp(10, 400),
                label: part.depth.toStringAsFixed(0),
                onChanged: widget.controller.setDepth,
              ),
            ),
            Text(part.depth.toStringAsFixed(0)),
          ],
        ),
      );
}

/// Picks the front-most face whose projected polygon contains [p].
int? _faceAt(Offset p, Solid solid, _Camera cam) {
  int? best;
  var bestDepth = -double.infinity;
  for (var f = 0; f < solid.faces.length; f++) {
    final poly = [for (final vi in solid.faces[f]) cam.project(solid.vertices[vi])];
    if (_pointInPolygon(p, poly)) {
      final d = cam.depthOf(solid.faceCentroid(f));
      if (d > bestDepth) {
        bestDepth = d;
        best = f;
      }
    }
  }
  return best;
}

bool _pointInPolygon(Offset p, List<Offset> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if (((a.dy > p.dy) != (b.dy > p.dy)) &&
        (p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx)) {
      inside = !inside;
    }
  }
  return inside;
}

/// Orthographic camera: yaw/pitch rotation + auto-fit scale, shared by the
/// painter and face hit-testing so they agree exactly.
class _Camera {
  _Camera({
    required Size size,
    required this.solid,
    required this.yaw,
    required this.pitch,
  })  : center = solid.centroid,
        origin = Offset(size.width / 2, size.height / 2),
        scale = math.min(size.width, size.height) * 0.38 /
            math.max(solid.boundingRadius, 1e-6);

  final Solid solid;
  final double yaw, pitch, scale;
  final Vec3 center;
  final Offset origin;

  Vec3 _rotate(Vec3 v) {
    final cy = math.cos(yaw), sy = math.sin(yaw);
    final x1 = v.x * cy + v.z * sy;
    final z1 = -v.x * sy + v.z * cy;
    final y1 = v.y;
    final cp = math.cos(pitch), sp = math.sin(pitch);
    final y2 = y1 * cp - z1 * sp;
    final z2 = y1 * sp + z1 * cp;
    return Vec3(x1, y2, z2);
  }

  Offset project(Vec3 v) {
    final r = _rotate(v - center);
    return origin + Offset(r.x * scale, -r.y * scale);
  }

  double depthOf(Vec3 v) => _rotate(v - center).z;
}

class _WirePainter extends CustomPainter {
  _WirePainter(this.solid, this.part, this.cam);

  final Solid solid;
  final Part part;
  final _Camera cam;

  @override
  void paint(Canvas canvas, Size size) {
    final edge = Paint()
      ..color = Colors.cyanAccent.shade400
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    final node = Paint()..color = Colors.cyanAccent.shade100;

    for (final e in solid.edges) {
      canvas.drawLine(
          cam.project(solid.vertices[e[0]]), cam.project(solid.vertices[e[1]]), edge);
    }
    for (final v in solid.vertices) {
      canvas.drawCircle(cam.project(v), 2.5, node);
    }

    // Mate connectors: a marker at the face center + a short normal stub.
    final cPaint = Paint()..color = const Color(0xFFFFC857);
    final cLine = Paint()
      ..color = const Color(0xFFFFC857)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final con in part.connectors) {
      final o = con.origin(solid);
      final n = con.normal(solid);
      final tip = o + n * (solid.boundingRadius * 0.25);
      canvas.drawLine(cam.project(o), cam.project(tip), cLine);
      canvas.drawCircle(cam.project(o), 4, cPaint);
    }
  }

  @override
  bool shouldRepaint(_WirePainter old) => true;
}
