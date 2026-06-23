import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/plane.dart';
import 'package:ai_sketcher/sketch/solid.dart';
import 'package:ai_sketcher/ui/camera.dart';

// Camera.unprojectToPlane must invert project() for points that lie on the
// target plane — that round trip is what turns a stroke drawn in the 3D scene
// back into sketch coordinates. Holds for any orientation and any base plane.

void main() {
  const size = Size(400, 300);
  final samples = [
    const Offset(0, 0),
    const Offset(30, -15),
    const Offset(-42, 60),
    const Offset(80, 80),
  ];

  void roundTrip(SketchPlane plane, Vec3 center, double yaw, double pitch) {
    final cam = Camera(
        size: size, center: center, radius: 120, yaw: yaw, pitch: pitch);
    for (final p in samples) {
      final screen = cam.project(plane.to3d(p));
      final back = cam.unprojectToPlane(screen, plane);
      expect(back.dx, closeTo(p.dx, 1e-6), reason: 'x for $p @ yaw=$yaw');
      expect(back.dy, closeTo(p.dy, 1e-6), reason: 'y for $p @ yaw=$yaw');
    }
  }

  test('face-on XY round-trips exactly', () {
    roundTrip(SketchPlane.xy, const Vec3(0, 0, 0), 0, 0);
  });

  test('orbited XY round-trips (off-plane camera center too)', () {
    roundTrip(SketchPlane.xy, const Vec3(10, 5, 25), 0.6, -0.4);
  });

  test('orbited XZ and YZ planes round-trip', () {
    roundTrip(SketchPlane.xz, const Vec3(3, -7, 2), 0.9, 0.3);
    roundTrip(SketchPlane.yz, const Vec3(-4, 8, 1), -0.7, 0.5);
  });
}
