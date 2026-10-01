import '../ui/sketch_canvas.dart';

/// Native (iOS, desktop) stand-in for the web host bridge: there is no host to
/// talk to, so attaching is a no-op.
class HostBridge {
  HostBridge._();

  static HostBridge? attach(SketchController controller) => null;

  void dispose() {}
}
