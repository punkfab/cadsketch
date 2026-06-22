import 'suggestion.dart';

/// Web stub for [AiClient]. The real assistant (ai_client_io.dart) shells out to
/// the local `claude` CLI, which only exists in the desktop harness — and no API
/// key ships in any build. On web it's unavailable by design; calls return a
/// clear message rather than failing to compile.
class AiClient {
  AiClient({
    this.binary = 'claude',
    this.model = 'claude-opus-4-8',
    this.timeout = const Duration(seconds: 120),
  });

  final String binary;
  final String model;
  final Duration timeout;

  Future<AiResult> ask({
    required Map<String, dynamic> sketch,
    String? question,
  }) async {
    return AiResult.error(
      'The AI assistant runs in the desktop harness only (it drives your local '
      'Claude CLI). It is not available in the web build.',
    );
  }
}
