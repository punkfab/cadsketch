@Tags(['screenshots'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/main.dart';
import 'package:ai_sketcher/screenshot_seed.dart';

// Local App Store screenshot renderer. Renders the REAL app UI (SketchHome) at
// the iPad Pro 12.9" native resolution (2048x2732) straight from the Dart VM —
// no simulator, no 10x CI. Set the output dir to run it:
//
//   SCREENSHOT_OUT=/tmp/shots flutter test test/screenshot_render_test.dart \
//     --tags screenshots
//
// Without SCREENSHOT_OUT it no-ops, so a normal `flutter test` never writes files.

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final f = File(p);
    if (f.existsSync()) {
      final bytes = f.readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
    }
  }
  await loader.load();
}

void main() {
  final out = Platform.environment['SCREENSHOT_OUT'];

  testWidgets('render App Store screenshots', (tester) async {
    if (out == null) {
      // No output requested — nothing to do (keeps plain `flutter test` clean).
      return;
    }
    const dejavu = '/usr/share/fonts/truetype/dejavu';
    await _loadFont('AppSans', [
      '$dejavu/DejaVuSans.ttf',
      '$dejavu/DejaVuSans-Bold.ttf',
    ]);
    // Material icon glyphs — without this every IconButton renders as a box.
    final mi = Platform.environment['MATERIAL_ICONS'];
    if (mi != null) await _loadFont('MaterialIcons', [mi]);

    final dir = Directory(out)..createSync(recursive: true);

    // iPad Pro 12.9": 2048x2732 physical = 1024x1366 logical at 2x.
    tester.view.physicalSize = const Size(2048, 2732);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // Render one scene per invocation (SCREENSHOT_SCENE); rendering multiple in
    // one test process hangs on the 2nd toImage. Default: all (may hang after 1).
    final only = Platform.environment['SCREENSHOT_SCENE'];
    final scenes = only != null
        ? screenshotScenes.entries.where((e) => e.key == only)
        : screenshotScenes.entries;

    for (final scene in scenes) {
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData.dark(useMaterial3: true).copyWith(
              textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'AppSans'),
            ),
            home: SketchHome(controller: scene.value()),
          ),
        ),
      );
      // Fixed pumps, not pumpAndSettle: the scene view repaints continuously
      // (never "settles"), so pumpAndSettle would hang.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${dir.path}/${scene.key}.png')
          .writeAsBytesSync(data!.buffer.asUint8List());
      // ignore: avoid_print
      print('WROTE ${dir.path}/${scene.key}.png');
    }
  });
}
