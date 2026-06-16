import 'dart:convert';

import 'package:flutter/material.dart';

import '../ai/ai_client.dart';
import '../ai/sketch_serializer.dart';
import '../ai/suggestion.dart';
import 'sketch_canvas.dart';

/// Right-side AI harness. Serializes the active part (via lib/ai), shows that
/// JSON so prompt iteration is transparent, calls Claude through the terminal
/// session (lib/ai/AiClient → `claude -p`), and lists the suggestions. This is
/// the M5 experimentation surface — deliberately a "look under the hood" panel,
/// not polished product UI.
class AiPanel extends StatefulWidget {
  const AiPanel({super.key, required this.controller});

  final SketchController controller;

  @override
  State<AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<AiPanel> {
  final _client = AiClient();
  final _question = TextEditingController();
  bool _busy = false;
  bool _showJson = false;
  AiResult? _result;

  @override
  void initState() {
    super.initState();
    // Re-render the JSON preview as the sketch changes.
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    _question.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Map<String, dynamic> get _sketchJson =>
      sketchToJson(widget.controller.active, widget.controller.parameters);

  Future<void> _ask() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    final result = await _client.ask(
      sketch: _sketchJson,
      question: _question.text,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 340,
      decoration: const BoxDecoration(
        color: Color(0xFF161C22),
        border: Border(left: BorderSide(color: Color(0xFF2A333C))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          Expanded(child: _body()),
          _composer(),
        ],
      ),
    );
  }

  Widget _header() => Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 8, 8),
        child: Row(
          children: [
            const Icon(Icons.auto_awesome, size: 18, color: Color(0xFFFFC857)),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('AI assistant',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            TextButton.icon(
              onPressed: () => setState(() => _showJson = !_showJson),
              icon: Icon(_showJson ? Icons.visibility_off : Icons.data_object,
                  size: 16),
              label: Text(_showJson ? 'Hide JSON' : 'JSON',
                  style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );

  Widget _body() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: [
        if (_showJson) _jsonPreview(),
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_result != null)
          ..._resultViews(_result!)
        else
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'Ask for constraint suggestions and design-rule flags on the '
              'active part. Runs through your terminal Claude session — no API '
              'key needed.',
              style: TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _jsonPreview() {
    final pretty = const JsonEncoder.withIndent('  ').convert(_sketchJson);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF0E1318),
        borderRadius: BorderRadius.circular(4),
      ),
      child: SelectableText(
        pretty,
        style: const TextStyle(
            fontFamily: 'monospace', fontSize: 10.5, color: Color(0xFF9DB2C0)),
      ),
    );
  }

  List<Widget> _resultViews(AiResult r) {
    if (r.isError) {
      return [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0x33FF5252),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(r.error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
        ),
      ];
    }
    return [
      if (r.summary.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(r.summary,
              style: const TextStyle(
                  fontSize: 13, fontStyle: FontStyle.italic, color: Colors.white70)),
        ),
      if (r.suggestions.isEmpty)
        const Text('No suggestions.',
            style: TextStyle(color: Colors.white60, fontSize: 12)),
      for (final s in r.suggestions) _SuggestionCard(s),
    ];
  }

  Widget _composer() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFF2A333C))),
      ),
      child: Column(
        children: [
          TextField(
            controller: _question,
            minLines: 1,
            maxLines: 3,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Optional: ask something specific…',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _busy ? null : _ask(),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _ask,
              icon: const Icon(Icons.send, size: 16),
              label: const Text('Suggest'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard(this.s);

  final AiSuggestion s;

  Color get _accent => switch (s.type) {
        'constraint' => const Color(0xFF4DD0E1),
        'dimension' => const Color(0xFFFFC857),
        'rule' => const Color(0xFFFF8A65),
        _ => const Color(0xFF90A4AE),
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1B232B),
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: _accent, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(s.type,
                    style: TextStyle(
                        fontSize: 10,
                        color: _accent,
                        fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(s.title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          if (s.detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(s.detail,
                  style: const TextStyle(fontSize: 12, color: Colors.white70)),
            ),
        ],
      ),
    );
  }
}
