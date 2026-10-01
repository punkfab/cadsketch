import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/export/featuretree_ir.dart';
import 'package:ai_sketcher/import/featuretree_import.dart';
import 'package:ai_sketcher/sketch/entities.dart';
import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/sketch/part.dart';

// featuretree IR -> CADSketch parts, and back out again. The fixtures are
// featuretree's own sample output (punkfab/featuretree, out/*.ir.json): two
// hand-written parts and two trees RECOVERED from STEP files.

Map<String, dynamic> _sketch(String name,
        {List polys = const [], List circles = const [], List rects = const [], Map? on}) =>
    {
      'kind': 'sketch',
      'name': name,
      'plane': 'XY',
      'on': on,
      'circles': circles,
      'rects': rects,
      'polys': polys,
    };

Map<String, dynamic> _pad(String name, String sketch, num length) =>
    {'kind': 'pad', 'name': name, 'sketch': sketch, 'length': length, 'symmetric': false};

Map<String, dynamic> _pocket(String name, String sketch, {num? length}) => {
      'kind': 'pocket',
      'name': name,
      'sketch': sketch,
      'through': length == null,
      'length': length,
    };

const _square = [
  [0, 0],
  [40, 0],
  [40, 20],
  [0, 20]
];

Map<String, dynamic> _fixture(String name) => jsonDecode(
        File('test/fixtures/featuretree/$name.ir.json').readAsStringSync())
    as Map<String, dynamic>;

void main() {
  test('profile + pad + through pocket -> one part with a hole', () {
    final r = importFeatureIr(_fixture('lbracket'));
    expect(r.parts.length, 1);
    final p = r.parts.single;
    expect(p.name, 'lbracket');
    expect(p.depth, 6);
    expect(p.sketch.points.length, 6);
    expect(p.sketch.points[1], const Offset(40, 0));
    expect(p.sketch.points[2], const Offset(40, -14)); // Y flipped to the canvas
    final hole = p.decorations.single as CircleEntity;
    expect(hole.center, const Offset(8, -8));
    expect(hole.radius, 2.6);
    expect(r.imported, ['body', 'hole']);
    expect(r.skipped, isEmpty);
    expect(p.buildSolid(), isNotNull);
    expect(p.hasHoles, isTrue);
  });

  test('axis-aligned edges get horizontal / vertical constraints', () {
    final p = importFeatureIr(_fixture('lbracket')).parts.single;
    final kinds = p.sketch.constraints.map((c) => c.kind).toList();
    expect(kinds.where((k) => k == ConstraintKind.horizontal).length, 3);
    expect(kinds.where((k) => k == ConstraintKind.vertical).length, 3);
  });

  test('a rect is a four-line outline', () {
    final p = importFeatureIr(_fixture('plate')).parts.single;
    expect(p.sketch.points.length, 4);
    expect(p.sketch.points.first, const Offset(-20, 15));
    expect((p.decorations.single as CircleEntity).radius, 4);
  });

  test('a bulge becomes a true arc and exports back as the same bulge', () {
    final spec = {
      'name': 'tab',
      'features': [
        _sketch('profile', polys: [
          [
            [0, 0],
            [20, 0, 1], // featuretree: positive bulge is to the LEFT of the edge
            [20, 10],
            [0, 10]
          ]
        ]),
        _pad('body', 'profile', 3),
      ]
    };
    final p = importFeatureIr(spec).parts.single;
    final arc = p.sketch.segments[1].arc!;
    expect(arc.radius, closeTo(5, 1e-9));
    expect(arc.center.dx, closeTo(20, 1e-9));
    expect(arc.center.dy, closeTo(-5, 1e-9));
    expect(arc.sweep.abs(), closeTo(math.pi, 1e-9));
    // The half circle is a notch INTO the plate (to x = 15), not a bump out of
    // it: the volume featuretree's build123d backend gives is 160.7, not 239.3.
    final outline = p.sketch.allProfiles().single;
    final xs = outline.map((o) => o.dx);
    expect(xs.reduce(math.min), 0);
    expect(xs.reduce(math.max), closeTo(20, 1e-9));
    expect(outline.any((o) => (o.dx - 15).abs() < 0.2 && (o.dy + 5).abs() < 0.7), isTrue);

    final wire = ((partToIr(p)['features'] as List).first['polys'] as List).first as List;
    expect(wire[1], [20, 0, 1]);
    expect(wire[2], [20, 10]);
  });

  test('a loop of two arcs is split so the sketch can close it', () {
    final spec = {
      'name': 'lens',
      'features': [
        _sketch('profile', polys: [
          [
            [-5, 0, 0.5],
            [5, 0, 0.5]
          ]
        ]),
        _pad('body', 'profile', 2),
      ]
    };
    final p = importFeatureIr(spec).parts.single;
    expect(p.sketch.points.length, 4);
    expect(p.sketch.segments.every((s) => s.isArc), isTrue);
    expect(p.buildSolid(), isNotNull);
  });

  test('a loop of arcs on one circle comes in as a circle', () {
    final spec = {
      'name': 'block',
      'features': [
        _sketch('profile', polys: [_square]),
        _pad('body', 'profile', 10),
        {
          'kind': 'prism_cut',
          'name': 'bore',
          'origin': [0, 0, 0],
          'normal': [0, 0, 1],
          'xdir': [1, 0, 0],
          'depth': 10,
          'polys': [
            [
              [14, 10, 1],
              [6, 10, 1]
            ]
          ],
        },
      ]
    };
    final r = importFeatureIr(spec);
    final hole = r.parts.single.decorations.single as CircleEntity;
    expect(hole.center.dx, closeTo(10, 1e-9));
    expect(hole.center.dy, closeTo(-10, 1e-9));
    expect(hole.radius, closeTo(4, 1e-9));
    // ...and goes back out as a drilled hole.
    final f = bodyToIr(r.parts.first, r.parts).ir['features'] as List;
    expect(f.last['kind'], 'pocket');
    expect(f.last['through'], true);
    expect(f[2]['circles'], [
      [10, 10, 4]
    ]);
  });

  test('polys nested in the profile are holes, and export back as holes', () {
    final spec = {
      'name': 'frame',
      'features': [
        _sketch('profile', polys: [
          _square,
          [
            [10, 5],
            [30, 5],
            [30, 15],
            [10, 15]
          ]
        ]),
        _pad('body', 'profile', 4),
      ]
    };
    final p = importFeatureIr(spec).parts.single;
    expect(p.sketch.allClosedLoops().length, 2);
    expect(p.profileWithHoles()!.holes.length, 1);
    final polys = (partToIr(p)['features'] as List).first['polys'] as List;
    expect(polys.length, 2);
    expect(polys[1], [
      [10, 5],
      [30, 5],
      [30, 15],
      [10, 15]
    ]);
  });

  test('a blind pocket on the top face is a difference feature on that face', () {
    final spec = {
      'name': 'block',
      'features': [
        _sketch('profile', polys: [_square]),
        _pad('body', 'profile', 10),
        _sketch('recess_sk', circles: [
          [10, 10, 4]
        ], on: {'face_of': 'body', 'side': 'top'}),
        _pocket('recess', 'recess_sk', length: 3),
      ]
    };
    final r = importFeatureIr(spec);
    expect(r.parts.length, 2);
    final f = r.parts[1];
    expect(f.name, 'recess');
    expect(identical(f.parent, r.parts[0]), isTrue);
    expect(f.operation, FeatureOp.difference);
    expect(f.depth, 3);
    expect(f.plane.origin.z, 10);
    expect(f.plane.normal.z, closeTo(1, 1e-12)); // out of the body
    expect(f.referenceLoop, isNotNull);
    // The cut occupies z 7..10.
    final zs = f.displaySolid()!.vertices.map((v) => v.z);
    expect(zs.reduce(math.min), closeTo(7, 1e-9));
    expect(zs.reduce(math.max), closeTo(10, 1e-9));
  });

  test('a pad on the bottom face is a union feature growing down', () {
    final spec = {
      'name': 'block',
      'features': [
        _sketch('profile', polys: [_square]),
        _pad('body', 'profile', 10),
        _sketch('foot_sk', polys: [
          [
            [2, 2],
            [8, 2],
            [8, 12],
            [2, 12]
          ]
        ], on: {'face_of': 'body', 'side': 'bottom'}),
        _pad('foot', 'foot_sk', 5),
      ]
    };
    final r = importFeatureIr(spec);
    final f = r.parts[1];
    expect(f.operation, FeatureOp.union);
    expect(f.plane.normal.z, closeTo(-1, 1e-12));
    final solid = f.displaySolid()!;
    final zs = solid.vertices.map((v) => v.z);
    expect(zs.reduce(math.min), closeTo(-5, 1e-9));
    // Same place in the world as the base draws y: the canvas mirror of CAD y.
    final ys = solid.vertices.map((v) => v.y);
    expect(ys.reduce(math.min), closeTo(-12, 1e-9));
    expect(ys.reduce(math.max), closeTo(-2, 1e-9));
  });

  test('what CADSketch cannot show is skipped by name, not dropped silently', () {
    final spec = {
      'name': 'block',
      'features': [
        _sketch('profile', polys: [_square]),
        _pad('body', 'profile', 10),
        {'kind': 'fillet', 'name': 'soften', 'radius': 1, 'select': {'circles': 'top_outer'}},
        {
          'kind': 'prism_cut',
          'name': 'cross_hole',
          'origin': [0, 10, 5],
          'normal': [1, 0, 0],
          'xdir': [0, 1, 0],
          'depth': 40,
          'polys': [
            [
              [-2, 0, 1],
              [2, 0, 1]
            ]
          ],
        },
        {
          'kind': 'prism_cut',
          'name': 'cavity',
          'origin': [0, 0, 3],
          'normal': [0, 0, 1],
          'xdir': [1, 0, 0],
          'depth': 2,
          'polys': [
            [
              [5, 5],
              [10, 5],
              [10, 10],
              [5, 10]
            ]
          ],
        },
      ]
    };
    final r = importFeatureIr(spec);
    expect(r.parts.length, 1);
    expect(r.skipped.map((s) => s.feature), ['soften', 'cross_hole', 'cavity']);
    expect(r.summary(), contains('3 skipped'));
  });

  test('refuses when the first solid cannot be built', () {
    final spec = {
      'name': 'wheel',
      'features': [
        {..._sketch('section', polys: [_square]), 'plane': 'XZ'},
        {'kind': 'revolve', 'name': 'rim', 'sketch': 'section', 'angle': 360},
      ]
    };
    expect(
        () => importFeatureIr(spec),
        throwsA(isA<IrImportException>()
            .having((e) => e.message, 'message', contains('revolve'))));
  });

  test('malformed input is refused with a readable message', () {
    expect(() => importFeatureIr([1, 2]), throwsA(isA<IrImportException>()));
    expect(() => importFeatureIr({'name': 'x'}), throwsA(isA<IrImportException>()));
    expect(
        () => importFeatureIr({
              'name': 'x',
              'features': [_pad('body', 'nope', 3)]
            }),
        throwsA(isA<IrImportException>()
            .having((e) => e.message, 'message', contains('not an earlier sketch'))));
    expect(
        () => importFeatureIr({
              'name': 'x',
              'features': [
                _sketch('a', polys: [
                  [
                    [0, 0],
                    [double.nan, 0],
                    [1, 1]
                  ]
                ])
              ]
            }),
        throwsA(isA<IrImportException>()));
  });

  test('prism cuts along the extrude axis: through -> hole, from the top -> pocket', () {
    final r = importFeatureIr(_fixture('mx_freecad'));
    // mx: a 60 x 40 x 30 block, two drilled holes, a stepped pocket from the
    // top (30 x 24 to z 22 with an island, 18 x 12 down to z 10) and one more cut.
    expect(r.parts.first.depth, 30);
    expect(r.parts.first.decorations.whereType<CircleEntity>().length, 2);
    final features = r.parts.skip(1).toList();
    expect(features.every((f) => f.operation == FeatureOp.difference), isTrue);
    final byName = {for (final f in features) f.name: f};
    expect(byName['pocket0']!.depth, 8);
    expect(byName['pocket1']!.depth, 20);
    expect(byName['pocket0']!.plane.origin.z, 30);
  });

  // The divergence report: every fixture in, back out, and what was lost on the
  // way. Writes the round-tripped IR next to a report so featuretree's own
  // build123d backend can compare volumes outside the Dart VM
  // (tool/ir_roundtrip_volumes.py).
  test('round trip of featuretree fixtures', () {
    final outDir = Directory(Platform.environment['CADSKETCH_IR_OUT'] ??
        '${Directory.systemTemp.path}/cadsketch_ir_roundtrip')
      ..createSync(recursive: true);
    final report = <String, dynamic>{};
    for (final name in ['plate', 'lbracket', 'mx_freecad', 'nist_recovered']) {
      final source = _fixture(name);
      final r = importFeatureIr(source);
      final back = bodyToIr(r.parts.first, r.parts);
      File('${outDir.path}/$name.roundtrip.ir.json')
          .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(back.ir));

      final cuts = (source['features'] as List)
          .where((f) => f['kind'] != 'sketch')
          .length;
      report[name] = {
        'sourceFeatures': cuts,
        'imported': r.imported.length,
        'skipped': [for (final s in r.skipped) s.toString()],
        'notes': r.notes,
        'droppedOnExport': back.dropped,
      };
      // Every source feature is either represented or named as skipped.
      // (A feature with several regions can be both, region by region.)
      final accounted = {...r.imported, ...r.skipped.map((s) => s.feature.split(' ').first)};
      for (final f in source['features'] as List) {
        if (f['kind'] == 'sketch') continue;
        expect(accounted, contains(f['name']), reason: '$name: ${f['name']} vanished');
      }
      expect(back.dropped, isEmpty, reason: name);
    }
    File('${outDir.path}/report.json')
        .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(report));

    // The hand-written parts survive whole.
    expect(report['plate']['skipped'], isEmpty);
    expect(report['lbracket']['skipped'], isEmpty);
  });
}
