import 'dart:convert';
import 'dart:io';

import 'suggestion.dart';

/// Drives Claude for the design assistant by shelling out to the `claude` CLI
/// in headless print mode (`claude -p`). This deliberately reuses the terminal
/// session's auth (~/.claude) — no API key, billed against your existing
/// subscription. It's the throwaway-harness shortcut; the native build will
/// point [AiClient] at a real backend proxy instead (same call shape).
///
/// The full prompt (instructions + sketch JSON) is piped over stdin so large
/// sketches never hit argv length limits.
class AiClient {
  AiClient({
    this.binary = 'claude',
    this.model = 'claude-opus-4-8',
    this.timeout = const Duration(seconds: 120),
  });

  /// Path to the `claude` executable. Override if it isn't on PATH.
  final String binary;
  final String model;
  final Duration timeout;

  static const _systemPrompt = '''
You are a CAD design assistant embedded in a 2D parametric sketch tool. You are
given the active part as JSON: points (pixel coords), segments (lines/arcs with
optional driving-length dimensions and shared-parameter bindings), inferred
geometric constraints, circles, and shared parameters.

Reason about the design and reply. Suggest geometric constraints that are likely
intended but missing (e.g. equal-length, perpendicular, symmetry, concentric,
tangent), dimensions that are under- or over-specified, and design-rule flags
(e.g. unconstrained degrees of freedom, a fillet with no radius dimension,
sharp internal corners, parts that won't fully constrain).

Respond with ONLY a JSON object, no prose, in exactly this shape:
{
  "summary": "one short sentence on what you see",
  "suggestions": [
    {"type": "constraint|dimension|rule|note", "title": "short imperative", "detail": "one or two sentences"}
  ]
}
Keep it to the few highest-value suggestions. If nothing stands out, return an
empty suggestions array with a summary saying so.''';

  /// Sends the sketch JSON and an optional user question, returns the parsed
  /// result. Never throws — failures come back as [AiResult.error] so the
  /// harness can display them.
  Future<AiResult> ask({
    required Map<String, dynamic> sketch,
    String? question,
  }) async {
    final userContent = StringBuffer()
      ..writeln(question?.trim().isNotEmpty == true
          ? question!.trim()
          : 'Review this sketch and suggest constraints and design-rule flags.')
      ..writeln()
      ..writeln('Active part JSON:')
      ..writeln('```json')
      ..writeln(const JsonEncoder.withIndent('  ').convert(sketch))
      ..writeln('```');

    Process proc;
    try {
      proc = await Process.start(binary, [
        '-p',
        '--output-format', 'json',
        '--model', model,
        '--append-system-prompt', _systemPrompt,
      ]);
    } on ProcessException catch (e) {
      return AiResult.error(
        'Could not launch "$binary": ${e.message}. Is the Claude CLI on PATH '
        'and logged in (run `claude` once in a terminal)?',
      );
    }

    proc.stdin.write(userContent.toString());
    await proc.stdin.close();

    final stdoutF = proc.stdout.transform(utf8.decoder).join();
    final stderrF = proc.stderr.transform(utf8.decoder).join();

    final int code;
    try {
      code = await proc.exitCode.timeout(timeout);
    } on Object {
      proc.kill();
      return AiResult.error('Timed out after ${timeout.inSeconds}s.');
    }

    final out = await stdoutF;
    final err = await stderrF;

    if (code != 0) {
      return AiResult.error(
        'claude exited $code: ${err.trim().isEmpty ? out.trim() : err.trim()}',
        raw: out,
      );
    }

    // `--output-format json` wraps the reply: {"result": "...", "is_error": ...}
    try {
      final wrapper = jsonDecode(out) as Map<String, dynamic>;
      if (wrapper['is_error'] == true) {
        return AiResult.error(
          (wrapper['result'] ?? 'unknown error').toString(),
          raw: out,
        );
      }
      return AiResult.parse((wrapper['result'] ?? '').toString());
    } catch (_) {
      // Not the wrapper we expected (older CLI / text mode) — parse directly.
      return AiResult.parse(out);
    }
  }
}
