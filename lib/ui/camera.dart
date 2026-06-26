import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import '../sketch/plane.dart';
import '../sketch/solid.dart';
import '../sketch/transform3.dart';

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

  /// World point where the view ray through screen point [s] meets the plane
  /// (planeOrigin, planeNormal). Orthographic, so the ray is the camera +z axis
  /// in world cast through s. Null if the ray is parallel to the plane. Shared
  /// by stroke unprojection and face picking so both agree with what's drawn.
  Vec3? rayPlaneHit(Offset s, Vec3 planeOrigin, Vec3 planeNormal) {
    final rx = (s.dx - origin.dx) / scale;
    final ry = -(s.dy - origin.dy) / scale;
    // Columns of the rotation matrix R (rotate of each world basis vector).
    final c0 = rotate(const Vec3(1, 0, 0));
    final c1 = rotate(const Vec3(0, 1, 0));
    final c2 = rotate(const Vec3(0, 0, 1));
    // World delta = Rᵀ·(rx, ry, t) = A + t·B (R orthonormal ⇒ R⁻¹ = Rᵀ).
    final a = Vec3(c0.x * rx + c0.y * ry, c1.x * rx + c1.y * ry,
        c2.x * rx + c2.y * ry);
    final b = Vec3(c0.z, c1.z, c2.z); // view direction in world
    final denom = dot(b, planeNormal);
    if (denom.abs() < 1e-9) return null;
    final t = -dot(center + a - planeOrigin, planeNormal) / denom;
    return center + a + b * t;
  }

  /// Inverse of [project] for a chosen target plane: the [plane] 2D coordinate
  /// that projects to screen point [s]. Turns a stroke drawn in the 3D scene
  /// into sketch coordinates on the active plane.
  Offset unprojectToPlane(Offset s, SketchPlane plane) {
    final hit = rayPlaneHit(s, plane.origin, plane.normal);
    return plane.to2d(hit ?? plane.origin);
  }
}
