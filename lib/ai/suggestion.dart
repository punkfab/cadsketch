import 'dart:convert';

/// One thing the assistant suggests: a constraint to add, a design-rule flag,
/// or a free-form note. Kept loose on purpose — this is a prototyping harness,
/// so we display whatever the model returns rather than enforcing a strict
/// taxonomy.
class AiSuggestion {
  AiSuggestion(this.type, this.title, this.detail);

  /// "constraint", "rule", "note", … — used only for the chip label/colour.
  final String type;
  final String title;
  final String detail;

  static AiSuggestion fromJson(Map<String, dynamic> j) => AiSuggestion(
        (j['type'] ?? 'note').toString(),
        (j['title'] ?? '').toString(),
        (j['detail'] ?? '').toString(),
      );
}

/// The parsed assistant reply plus the raw text (the harness shows raw output
/// so prompt iteration is transparent).
class AiResult {
  AiResult({
    required this.summary,
    required this.suggestions,
    required this.raw,
    this.error,
  });

  final String summary;
  final List<AiSuggestion> suggestions;
  final String raw;
  final String? error;

  bool get isError => error != null;

  factory AiResult.error(String message, {String raw = ''}) => AiResult(
        summary: '',
        suggestions: const [],
        raw: raw,
        error: message,
      );

  /// Parses the model's text. Tolerates ```json fences and leading/trailing
  /// prose by extracting the outermost {...} object. Falls back to showing the
  /// text as a single note if it isn't the JSON we asked for.
  factory AiResult.parse(String text) {
    final obj = _extractJsonObject(text);
    if (obj == null) {
      return AiResult(
        summary: '',
        suggestions: [AiSuggestion('note', 'Model reply', text.trim())],
        raw: text,
      );
    }
    try {
      final map = jsonDecode(obj) as Map<String, dynamic>;
      final list = (map['suggestions'] as List?) ?? const [];
      return AiResult(
        summary: (map['summary'] ?? '').toString(),
        suggestions: [
          for (final s in list)
            if (s is Map<String, dynamic>) AiSuggestion.fromJson(s),
        ],
        raw: text,
      );
    } catch (_) {
      return AiResult(
        summary: '',
        suggestions: [AiSuggestion('note', 'Model reply', text.trim())],
        raw: text,
      );
    }
  }
}

/// Returns the substring from the first '{' to its matching '}', or null.
String? _extractJsonObject(String text) {
  final start = text.indexOf('{');
  if (start < 0) return null;
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < text.length; i++) {
    final ch = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
    } else if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) return text.substring(start, i + 1);
    }
  }
  return null;
}
