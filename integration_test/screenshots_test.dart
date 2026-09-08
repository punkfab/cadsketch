import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ai_sketcher/screenshot_seed.dart';

// App Store screenshot capture. Each scene from screenshot_seed pumps the REAL
// app UI (seeded with representative parts, no solver) and is captured at the
// simulator's native resolution. Run on an iPad Pro 12.9"/13" simulator so the
// PNGs come out at an accepted App Store size (2048x2732 / 2064x2752):
//
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/screenshots_test.dart -d <ipad-pro-udid>
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capture App Store screenshots', (tester) async {
    final scenes = screenshotScenes.entries.toList();

    // Pump one scene first so an engine surface exists, then convert it to an
    // image-backed layer once (required on iOS before takeScreenshot).
    await tester.pumpWidget(MaterialApp(home: scenes.first.value.build()));
    await tester.pumpAndSettle();
    await binding.convertFlutterSurfaceToImage();

    for (final scene in scenes) {
      await tester.pumpWidget(MaterialApp(home: scene.value.build()));
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      await binding.takeScreenshot(scene.key);
    }
  });
}
