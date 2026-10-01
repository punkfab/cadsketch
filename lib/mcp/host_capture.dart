import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Key of the RepaintBoundary wrapped around the whole app (lib/main.dart), so a
/// host can ask for a picture of what the user is looking at.
final GlobalKey hostCaptureKey = GlobalKey(debugLabel: 'hostCapture');

/// A PNG of the app as currently painted, base64-encoded, no larger than
/// [maxSide] logical pixels on its long side. Null when nothing is mounted.
Future<({String base64, int width, int height})?> captureApp(
    {double maxSide = 1400}) async {
  final object = hostCaptureKey.currentContext?.findRenderObject();
  if (object is! RenderRepaintBoundary) return null;
  final size = object.size;
  if (size.isEmpty) return null;
  final longest = size.longestSide;
  final ratio = longest > maxSide ? maxSide / longest : 1.0;
  final image = await object.toImage(pixelRatio: ratio);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return null;
    return (
      base64: base64Encode(data.buffer.asUint8List()),
      width: image.width,
      height: image.height,
    );
  } finally {
    image.dispose();
  }
}
