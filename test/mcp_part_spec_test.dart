import 'dart:math' as math;

import 'package:ai_sketcher/mcp/host_document.dart';
import 'package:ai_sketcher/mcp/part_spec.dart';
import 'package:ai_sketcher/ui/sketch_canvas.dart';
import 'package:flutter_test/flutter_test.dart';

// The contract between the app and an AI host (ChatGPT / Claude via MCP Apps):
// a model writes parts in, the app reports the document back out, and the two
// directions use the same shape so the model can round-trip its own output.

Map<String, dynamic> bracket() => {
      'name': 'bracket',
      'depth': 5,
      'profile': [
        [0, 0],
        [40, 0],
        [40, 20],
        [0, 20],
      ],
      'holes': [
        [8, 10, 2.1],
        [32, 10, 2.1],
      ],
    };

void main() {
  test('a model-drawn part loads as an ordinary extrudable part', () {
    final c = SketchController();
    loadPartSpecs(c, partSpecsFromJson([bracket()]));

    expect(c.parts, hasLength(1), reason: 'placeholder part is dropped');
    expect(c.active.name, 'bracket');
    expect(c.active.depth, 5);
    expect(c.active.sketch.closedLoop(), isNotNull);
    expect(c.active.buildSolid(), isNotNull, reason: 'profile extrudes');
  });

  test('loading a host part asks the canvas to frame it', () {
    final c = SketchController();
    expect(c.activeBounds(), isNull, reason: 'empty document has no bounds');
    final before = c.fitViewRequests;
    loadPartSpecs(c, partSpecsFromJson([bracket()]));
    expect(c.fitViewRequests, before + 1);
    // 40 x 20 mm outline; Y is flipped into screen space, so it spans -20..0.
    final b = c.activeBounds()!;
    expect(b.width, closeTo(40, 1e-6));
    expect(b.height, closeTo(20, 1e-6));
    expect(b.top, closeTo(-20, 1e-6));
  });

  test('what the app reports back is the shape the model sent', () {
    final c = SketchController();
    loadPartSpecs(c, partSpecsFromJson([bracket()]));
    final ctx = modelContextOf(c);
    final part = (ctx.structured['parts'] as List).single as Map;

    expect(part['name'], 'bracket');
    expect(part['depth'], 5);
    expect(part['closed'], true);
    expect(part['holes'], hasLength(2));

    // Same rectangle, Y still up (the screen-space flip is undone on the way out).
    final xs = [for (final v in part['profile'] as List) (v[0] as num).toDouble()];
    final ys = [for (final v in part['profile'] as List) (v[1] as num).toDouble()];
    expect(xs.reduce(math.min), closeTo(0, 1e-6));
    expect(xs.reduce(math.max), closeTo(40, 1e-6));
    expect(ys.reduce(math.min), closeTo(0, 1e-6));
    expect(ys.reduce(math.max), closeTo(20, 1e-6));
    final hole = (part['holes'] as List).first as List;
    expect((hole[0] as num).toDouble(), closeTo(8, 1e-6));
    expect((hole[1] as num).toDouble(), closeTo(10, 1e-6));
    expect((hole[2] as num).toDouble(), closeTo(2.1, 1e-6));

    // And the reported part parses straight back in.
    final again = partSpecsFromJson([part]);
    expect(again.single.profile, hasLength(4));

    expect(ctx.text, contains('bracket'));
    expect(ctx.text, contains('40 x 20 mm'));
    expect(ctx.text, contains('2 holes'));
  });

  test('a bulged edge becomes an arc on the correct side', () {
    // A 20 mm wide slot end: bulge 1 = a CCW semicircle from (20,0) to (20,20),
    // so it must bulge to +x, reaching x = 30.
    final spec = PartSpec.fromJson({
      'name': 'tab',
      'depth': 3,
      'profile': [
        [0, 0],
        [20, 0, 1],
        [20, 20],
        [0, 20],
      ],
    });
    final pts = spec.tessellatedProfile();
    final maxX = pts.map((p) => p.dx).reduce(math.max);
    expect(maxX, closeTo(30, 0.2));
    expect(pts.length, greaterThan(10));
    // Negative bulge goes the other way (a notch into the part).
    final notch = PartSpec.fromJson({
      'name': 'notch',
      'depth': 3,
      'profile': [
        [0, 0],
        [20, 0, -1],
        [20, 20],
        [0, 20],
      ],
    });
    final minArcX = notch
        .tessellatedProfile()
        .where((p) => p.dy > 1 && p.dy < 19)
        .map((p) => p.dx)
        .reduce(math.min);
    expect(minArcX, closeTo(10, 0.2));
  });

  test('a round body uses circle instead of a profile', () {
    final c = SketchController();
    loadPartSpecs(
        c,
        partSpecsFromJson([
          {
            'name': 'spacer',
            'depth': 8,
            'circle': [0, 0, 6],
          }
        ]));
    final part = (modelContextOf(c).structured['parts'] as List).single as Map;
    expect(part['circle'], isNotNull);
    expect(modelContextOf(c).text, contains('diameter 12 mm'));
  });

  test('a washer: the largest circle is the body, the inner one a hole', () {
    final c = SketchController();
    loadPartSpecs(
        c,
        partSpecsFromJson([
          {
            'name': 'washer',
            'depth': 2,
            'circle': [0, 0, 6],
            'holes': [
              [0, 0, 2.75]
            ],
          }
        ]));
    final ctx = modelContextOf(c);
    final part = (ctx.structured['parts'] as List).single as Map;
    expect(part['circle'], [0, 0, 6]);
    expect(part['holes'], [
      [0, 0, 2.75]
    ]);
    expect(ctx.text, contains('diameter 12 mm'));
    expect(ctx.text, contains('1 hole'));
    // And what is reported parses straight back in.
    expect(partSpecsFromJson([part]).single.holes, hasLength(1));
  });

  test('several parts load in order and an empty list clears the canvas', () {
    final c = SketchController();
    loadPartSpecs(
        c,
        partSpecsFromJson([
          bracket(),
          {...bracket(), 'name': 'plate', 'depth': 2},
        ]));
    expect([for (final p in c.parts) p.name], ['bracket', 'plate']);

    loadPartSpecs(c, const []);
    expect(c.parts, hasLength(1));
    expect(c.hasWork, isFalse);
  });

  test('an unclosed hand sketch is reported as open, not as a part', () {
    final c = SketchController();
    c.addSegmentBetween(const Offset(0, 0), const Offset(50, 0));
    final ctx = modelContextOf(c);
    final part = (ctx.structured['parts'] as List).single as Map;
    expect(part['closed'], false);
    expect(part.containsKey('profile'), isFalse);
    expect(ctx.text, contains('OPEN sketch'));
  });

  test('a DXF file opened by the host loads like an imported DXF', () {
    const dxf = '0\nSECTION\n2\nENTITIES\n'
        '0\nLWPOLYLINE\n90\n4\n70\n1\n'
        '10\n0\n20\n0\n10\n50\n20\n0\n10\n50\n20\n25\n10\n0\n20\n25\n'
        '0\nCIRCLE\n10\n25\n20\n12.5\n40\n4\n'
        '0\nENDSEC\n0\nEOF\n';
    final c = SketchController();
    final before = c.fitViewRequests;
    loadDxfText(c, 'plate', dxf);
    expect(c.parts, hasLength(1));
    expect(c.active.name, 'plate');
    expect(c.fitViewRequests, before + 1);
    final part = (modelContextOf(c).structured['parts'] as List).single as Map;
    expect(part['closed'], true);
    expect(part['holes'], hasLength(1));
    expect(() => loadDxfText(c, 'empty', '0\nEOF\n'),
        throwsA(isA<PartSpecException>()));
  });

  test('malformed host input is rejected with a clear message', () {
    expect(() => partSpecsFromJson('nope'), throwsA(isA<PartSpecException>()));
    expect(() => PartSpec.fromJson({'name': 'x', 'depth': 5}),
        throwsA(isA<PartSpecException>()));
    expect(
        () => PartSpec.fromJson({
              'name': 'x',
              'depth': -1,
              'profile': [
                [0, 0],
                [1, 0],
                [0, 1]
              ]
            }),
        throwsA(isA<PartSpecException>()));
    expect(
        () => PartSpec.fromJson({
              'name': 'x',
              'depth': 5,
              'profile': [
                [0, 0],
                [1, double.nan],
                [0, 1]
              ]
            }),
        throwsA(isA<PartSpecException>()));
    expect(
        () => PartSpec.fromJson({
              'name': 'x',
              'depth': 5,
              'profile': [
                [0, 0],
                [1, 0]
              ]
            }),
        throwsA(isA<PartSpecException>()));
  });
}
