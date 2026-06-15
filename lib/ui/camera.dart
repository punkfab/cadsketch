import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import '../sketch/solid.dart';

/// Orthographic camera shared by the wireframe views and their hit-testing, so
/// rendering and picking agree exactly. Built from a center + radius (auto-fit).
class Camera {
  Camera({
    required Size size,
    required this.center,
    required double radius,
    required this.yaw,
    required this.pitch,
  })  : origin = Offset(size.width / 2, size.height / 2),
        scale = math.min(size.width, size.height) * 0.38 / math.max(radius, 1e-6);

  final Vec3 center;
  final double yaw, pitch, scale;
  final Offset origin;

  Vec3 rotate(Vec3 v) {
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
    final r = rotate(v - center);
    return origin + Offset(r.x * scale, -r.y * scale);
  }

  double depthOf(Vec3 v) => rotate(v - center).z;
}
