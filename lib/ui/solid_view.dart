import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../sketch/solid.dart';

/// A pseudo-3D wireframe view of an extruded profile. Orthographic projection
/// in CustomPaint — no 3D engine. Drag to orbit, slider to set extrude depth.
/// "Real" shaded 3D is deferred to the native iOS build.
class SolidView extends StatefulWidget {
  const SolidView({super.key, required this.profile});

  /// Closed profile (solved sketch points) to extrude.
  final List<Offset> profile;

  @override
  State<SolidView> createState() => _SolidViewState();
}

class _SolidViewState extends State<SolidView> {
  double _yaw = 0.6; // pleasant default 3/4 view
  double _pitch = -0.5;
  double _depth = 100;

  void _orbit(Offset delta) {
    setState(() {
      _yaw += delta.dx * 0.01;
      _pitch = (_pitch + delta.dy * 0.01).clamp(-math.pi / 2, math.pi / 2);
    });
  }

  @override
  Widget build(BuildContext context) {
    final solid = extrudeProfile(widget.profile, _depth);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Extrude — wireframe'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('depth ${_depth.toStringAsFixed(0)}',
                  style: const TextStyle(fontSize: 12, color: Colors.cyanAccent)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Listener(
              onPointerMove: (e) => _orbit(e.delta),
              child: Container(
                color: const Color(0xFF101418),
                child: CustomPaint(
                  painter: _WirePainter(solid, _yaw, _pitch),
                  size: Size.infinite,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Text('Depth'),
                Expanded(
                  child: Slider(
                    min: 10,
                    max: 400,
                    value: _depth,
                    onChanged: (v) => setState(() => _depth = v),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WirePainter extends CustomPainter {
  _WirePainter(this.solid, this.yaw, this.pitch);

  final Solid solid;
  final double yaw;
  final double pitch;

  @override
  void paint(Canvas canvas, Size size) {
    final center = solid.centroid;
    final radius = solid.boundingRadius;
    if (radius < 1e-6) return;
    final scale = math.min(size.width, size.height) * 0.38 / radius;
    final origin = Offset(size.width / 2, size.height / 2);

    Offset project(Vec3 v) {
      final r = _rotate(v - center);
      // Orthographic: rotation already folds depth into x/y; flip y for screen.
      return origin + Offset(r.x * scale, -r.y * scale);
    }

    final edge = Paint()
      ..color = Colors.cyanAccent.shade400
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    final node = Paint()..color = Colors.cyanAccent.shade100;

    for (final e in solid.edges) {
      canvas.drawLine(project(solid.vertices[e[0]]), project(solid.vertices[e[1]]), edge);
    }
    for (final v in solid.vertices) {
      canvas.drawCircle(project(v), 2.5, node);
    }
  }

  Vec3 _rotate(Vec3 v) {
    // Yaw about Y.
    final cy = math.cos(yaw), sy = math.sin(yaw);
    final x1 = v.x * cy + v.z * sy;
    final z1 = -v.x * sy + v.z * cy;
    final y1 = v.y;
    // Pitch about X.
    final cp = math.cos(pitch), sp = math.sin(pitch);
    final y2 = y1 * cp - z1 * sp;
    final z2 = y1 * sp + z1 * cp;
    return Vec3(x1, y2, z2);
  }

  @override
  bool shouldRepaint(_WirePainter old) =>
      old.yaw != yaw || old.pitch != pitch || old.solid != solid;
}
