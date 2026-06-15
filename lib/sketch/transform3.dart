import 'dart:math' as math;

import 'solid.dart';

// Minimal 3D rigid-transform math for assembly placement. A part's world
// placement is a rotation + translation; mates are solved by closed-form
// alignment of connector frames (see assembly.dart).

class Mat3 {
  /// Row-major 3x3.
  const Mat3(this.m);
  final List<double> m;

  static const identity = Mat3([1, 0, 0, 0, 1, 0, 0, 0, 1]);

  Vec3 apply(Vec3 v) => Vec3(
        m[0] * v.x + m[1] * v.y + m[2] * v.z,
        m[3] * v.x + m[4] * v.y + m[5] * v.z,
        m[6] * v.x + m[7] * v.y + m[8] * v.z,
      );

  /// Rotation by [angle] (radians) about unit axis [k] (Rodrigues).
  factory Mat3.axisAngle(Vec3 k, double angle) {
    final c = math.cos(angle), s = math.sin(angle), t = 1 - c;
    final x = k.x, y = k.y, z = k.z;
    return Mat3([
      t * x * x + c, t * x * y - s * z, t * x * z + s * y,
      t * x * y + s * z, t * y * y + c, t * y * z - s * x,
      t * x * z - s * y, t * y * z + s * x, t * z * z + c,
    ]);
  }
}

class Transform3 {
  const Transform3(this.rot, this.t);
  final Mat3 rot;
  final Vec3 t;

  static const identity = Transform3(Mat3.identity, Vec3(0, 0, 0));

  Vec3 apply(Vec3 v) => rot.apply(v) + t;

  /// Pure translation.
  factory Transform3.translation(Vec3 t) => Transform3(Mat3.identity, t);
}

Vec3 cross(Vec3 a, Vec3 b) => Vec3(
      a.y * b.z - a.z * b.y,
      a.z * b.x - a.x * b.z,
      a.x * b.y - a.y * b.x,
    );

double dot(Vec3 a, Vec3 b) => a.x * b.x + a.y * b.y + a.z * b.z;

/// Rotation matrix taking unit vector [from] to unit vector [to].
Mat3 rotationFromTo(Vec3 from, Vec3 to) {
  final u = from.normalized, v = to.normalized;
  final c = dot(u, v);
  if (c > 1 - 1e-9) return Mat3.identity; // already aligned
  if (c < -1 + 1e-9) {
    // Opposite: 180° about any axis perpendicular to u.
    final perp = (u.x.abs() < 0.9 ? cross(u, const Vec3(1, 0, 0)) : cross(u, const Vec3(0, 1, 0))).normalized;
    return Mat3.axisAngle(perp, math.pi);
  }
  return Mat3.axisAngle(cross(u, v).normalized, math.acos(c.clamp(-1.0, 1.0)));
}
