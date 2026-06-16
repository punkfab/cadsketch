import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/ai/sketch_serializer.dart';
import 'package:ai_sketcher/ai/suggestion.dart';
import 'package:ai_sketcher/sketch/entities.dart';
import 'package:ai_sketcher/sketch/part.dart';

void main() {
  group('sketchToJson', () {
    test('serializes points, segments, constraints, circles, parameters', () {
      final part = Part('Bracket');
      // A square: addPolyline merges corners and infers H/V + equal-length.
      part.sketch.addPolyline(const [
        Offset(0, 0),
        Offset(100, 0),
        Offset(100, 100),
        Offset(0, 100),
        Offset(0, 0),
      ]);
      part.decorations.add(CircleEntity(const Offset(50, 50), 20));

      final json = sketchToJson(part, {'width': 100});

      expect(json['part'], 'Bracket');
      expect((json['points'] as List), isNotEmpty);
      expect((json['segments'] as List).length, part.sketch.segments.length);
      expect((json['constraints'] as List), isNotEmpty);
      expect((json['circles'] as List).length, 1);
      final circle = (json['circles'] as List).first as Map;
      expect(circle['radius'], 20);
      expect((json['parameters'] as Map)['width'], 100);

      // Every segment reports a kind and integer-ish length.
      for (final s in json['segments'] as List) {
        expect((s as Map)['kind'], anyOf('line', 'arc'));
        expect(s['length'], isA<num>());
      }
    });

    test('arc segment carries arc geometry', () {
      final part = Part('Slot');
      part.sketch.addArc(
        const Offset(0, 0),
        const Offset(0, 40),
        const Offset(0, 20),
        20,
        3.14159,
      );
      final json = sketchToJson(part, const {});
      final seg = (json['segments'] as List).first as Map;
      expect(seg['kind'], 'arc');
      expect(seg['arc'], isNotNull);
      expect((seg['arc'] as Map)['radius'], isA<num>());
    });
  });

  group('AiResult.parse', () {
    test('parses a clean JSON object', () {
      final r = AiResult.parse(
          '{"summary":"a square","suggestions":[{"type":"constraint","title":"Add symmetry","detail":"x"}]}');
      expect(r.isError, false);
      expect(r.summary, 'a square');
      expect(r.suggestions.length, 1);
      expect(r.suggestions.first.type, 'constraint');
    });

    test('strips ```json fences and surrounding prose', () {
      const text = 'Here you go:\n```json\n'
          '{"summary":"ok","suggestions":[]}\n```\nHope that helps!';
      final r = AiResult.parse(text);
      expect(r.isError, false);
      expect(r.summary, 'ok');
      expect(r.suggestions, isEmpty);
    });

    test('falls back to a note when reply is not JSON', () {
      final r = AiResult.parse('I cannot do that.');
      expect(r.isError, false);
      expect(r.suggestions.length, 1);
      expect(r.suggestions.first.type, 'note');
      expect(r.suggestions.first.detail, 'I cannot do that.');
    });

    test('handles braces inside strings', () {
      final r = AiResult.parse(
          '{"summary":"has } brace","suggestions":[]}');
      expect(r.summary, 'has } brace');
    });
  });
}
