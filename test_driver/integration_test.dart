import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

// Screenshot sink for the capture test. Writes each screenshot as a PNG into
// ios/appstore/screenshots/ipad-13/, where the App Store Connect uploader
// (app-store-release skill) picks them up. Alpha is stripped afterwards in CI
// (`mogrify -alpha off`) because ASC silently fails screenshots with alpha.
Future<void> main() async {
  final dir = Directory('ios/appstore/screenshots/ipad-13')
    ..createSync(recursive: true);
  await integrationDriver(
    onScreenshot: (String name, List<int> bytes, [Map<String, Object?>? args]) async {
      File('${dir.path}/$name.png').writeAsBytesSync(bytes);
      stdout.writeln('wrote ${dir.path}/$name.png (${bytes.length} bytes)');
      return true;
    },
  );
}
