import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/solid.dart';
import 'package:ai_sketcher/ui/camera.dart';

// Face picking uses the depth of each candidate face's surface directly under
// the cursor (rayPlaneHit), and selects the greatest depth. This must order
// front-to-back so the visible face wins — fixing the old average-vertex
// heuristic that made caps beat side faces unpredictably.

Camera _cam() => Camera(
      size: const Size(400, 400),
      center: const Vec3(0, 0, 0),
      radius: 10,
      yaw: 0,
      pitch: 0,
    );

void main() {
  test('rayPlaneHit lands on the plane; nearer surface has greater depth', () {
    final cam = _cam();
    const screenCenter = Offset(200, 200); // the camera origin
    final near =
        cam.rayPlaneHit(screenCenter, const Vec3(0, 0, 10), const Vec3(0, 0, 1))!;
    final far =
        cam.rayPlaneHit(screenCenter, const Vec3(0, 0, 0), const Vec3(0, 0, 1))!;

    expect(near.z, closeTo(10, 1e-9)); // on its plane
    expect(far.z, closeTo(0, 1e-9));
    // _hit maximizes depthOf, so the frontmost surface under the cursor wins.
    expect(cam.depthOf(near), greaterThan(cam.depthOf(far)));
  });

  test('rayPlaneHit is null for an edge-on plane (not pickable)', () {
    final cam = _cam();
    final hit =
        cam.rayPlaneHit(const Offset(200, 200), const Vec3(0, 0, 0), const Vec3(1, 0, 0));
    expect(hit, isNull);
  });
}
