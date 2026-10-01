import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_sketcher/mcp/host_commands.dart';
import 'package:ai_sketcher/mcp/host_document.dart';
import 'package:ai_sketcher/mcp/part_spec.dart';
import 'package:ai_sketcher/ui/sketch_canvas.dart';
import 'package:flutter_test/flutter_test.dart';

// The editing commands an AI host runs in the live editor. They address the
// document in the model's terms (mm, Y up, part by name, vertex/edge/hole by
// index) and each is one undo step.

SketchController plate() {
  final c = SketchController();
  loadPartSpecs(
      c,
      partSpecsFromJson([
        {
          'name': 'plate',
          'depth': 4,
          'profile': [
            [0, 0],
            [80, 0],
            [80, 40],
            [0, 40],
          ],
          'holes': [
            [20, 20, 3],
          ],
        }
      ]));
  return c;
}

Map<String, dynamic> run(SketchController c, String op,
        [Map<String, dynamic> args = const {}]) =>
    runHostCommand(c, op, args);

Map<String, dynamic> partOf(Map<String, dynamic> result) =>
    result['part'] as Map<String, dynamic>;

({double w, double h}) size(Map<String, dynamic> part) {
  final xs = [for (final v in part['profile'] as List) (v[0] as num).toDouble()];
  final ys = [for (final v in part['profile'] as List) (v[1] as num).toDouble()];
  double span(List<double> v) =>
      v.reduce((a, b) => a > b ? a : b) - v.reduce((a, b) => a < b ? a : b);
  return (w: span(xs), h: span(ys));
}

void main() {
  test('get_sketch reports edges and constraints the host can address', () {
    final c = plate();
    final doc = run(c, 'get_sketch');
    expect(doc['activePart'], 'plate');
    final part = (doc['parts'] as List).single as Map;
    expect(part['edges'], hasLength(4));
    final lengths = [for (final e in part['edges'] as List) e['length']]..sort();
    expect(lengths, [40, 40, 80, 80]);
    // A drawn rectangle arrives with its intent: two horizontal, two vertical.
    final kinds = [for (final k in part['constraintList'] as List) k['kind']]..sort();
    expect(kinds, ['horizontal', 'horizontal', 'vertical', 'vertical']);
    expect(doc['summary'], contains('80 x 40 mm'));
  });

  test('add_hole, move_hole and remove_hole work in model coordinates', () {
    final c = plate();
    var part = partOf(run(c, 'add_hole', {'center': [60, 20], 'radius': 2.25}));
    expect(part['holes'], hasLength(2));
    final added = (part['holes'] as List)[1] as List;
    expect([added[0], added[1], added[2]], [60, 20, 2.25]);

    part = partOf(run(c, 'move_hole', {'hole': 1, 'center': [70, 30], 'radius': 3}));
    final moved = (part['holes'] as List)[1] as List;
    expect([moved[0], moved[1], moved[2]], [70, 30, 3]);

    part = partOf(run(c, 'remove_hole', {'hole': 0}));
    expect(part['holes'], hasLength(1));
    expect(((part['holes'] as List).single as List)[0], 70);
  });

  test('a hole placed outside the profile comes back with a warning', () {
    final c = plate();
    final result = run(c, 'add_hole', {'center': [200, 20], 'radius': 2});
    expect(result['warning'], contains('outside the profile'));
  });

  test('move_vertex moves that corner; one call is one undo step', () {
    final c = plate();
    final before = size(partOf(run(c, 'select_part', {'part': 'plate'})));
    expect(before.w, closeTo(80, 1e-6));

    // Find the corner at (80, 0) and pull it out to (100, 0).
    final profile = (run(c, 'get_sketch')['parts'] as List).single['profile'] as List;
    final vi = profile.indexWhere((v) => v[0] == 80 && v[1] == 0);
    // The constraints stay in force, so the corner above follows and the plate
    // is still a rectangle (the solver lands within a micron or so).
    final after = size(partOf(run(c, 'move_vertex', {'vertex': vi, 'to': [100, 0]})));
    expect(after.w, closeTo(100, 0.01));
    expect(after.h, closeTo(40, 0.01));

    run(c, 'undo');
    final undone = size((run(c, 'get_sketch')['parts'] as List).single as Map<String, dynamic>);
    expect(undone.w, closeTo(80, 0.01));
    run(c, 'redo');
    expect(size((run(c, 'get_sketch')['parts'] as List).single as Map<String, dynamic>).w,
        closeTo(100, 0.01));
  });

  test('set_dimension drives an edge to an exact length', () {
    final c = plate();
    final edges = (run(c, 'get_sketch')['parts'] as List).single['edges'] as List;
    final long = edges.firstWhere((e) => e['length'] == 80)['edge'] as int;
    final part = partOf(run(c, 'set_dimension', {'edge': long, 'length': 95}));
    final edge = (part['edges'] as List).firstWhere((e) => e['edge'] == long) as Map;
    expect((edge['length'] as num).toDouble(), closeTo(95, 0.01));
    expect(edge['driving'], 95);
    expect(part['dimensionedSegments'], 1);
    // The plate got wider; it did not skew. Still a 95 x 40 rectangle.
    final s = size(part);
    expect(s.w, closeTo(95, 0.01));
    expect(s.h, closeTo(40, 0.01));
    final lengths = [for (final e in part['edges'] as List) (e['length'] as num).toDouble()]..sort();
    expect(lengths[0], closeTo(40, 0.01));
    expect(lengths[1], closeTo(40, 0.01));
    expect(lengths[2], closeTo(95, 0.01));
    expect(lengths[3], closeTo(95, 0.01));

    final cleared = partOf(run(c, 'set_dimension', {'edge': long, 'length': null}));
    expect(((cleared['edges'] as List)[long] as Map).containsKey('driving'), isFalse);
  });

  test('add_constraint and remove_constraint, addressed by edge index', () {
    final c = plate();
    // The rectangle starts with its four inferred horizontal/vertical ones.
    var part = partOf(run(c, 'add_constraint', {'kind': 'equal', 'edges': [0, 2]}));
    expect(part['constraintList'], hasLength(5));
    expect((part['constraintList'] as List).last,
        {'constraint': 4, 'kind': 'equal', 'edges': [0, 2]});
    // Adding it again is a no-op, not a duplicate.
    final again = run(c, 'add_constraint', {'kind': 'equal', 'edges': [0, 2]});
    expect(again['did'], contains('already there'));
    expect(partOf(again)['constraintList'], hasLength(5));
    part = partOf(run(c, 'remove_constraint', {'constraint': 4}));
    expect(part['constraintList'], hasLength(4));
  });

  test('set_depth, add_part, select_part and delete_part', () {
    final c = plate();
    expect(partOf(run(c, 'set_depth', {'depth': 6}))['depth'], 6);

    run(c, 'add_part', {
      'part': {'name': 'spacer', 'depth': 8, 'circle': [0, 0, 6]}
    });
    expect([for (final p in c.parts) p.name], ['plate', 'spacer']);
    expect(c.active.name, 'spacer');

    // Commands default to the active part; naming one targets (and selects) it.
    expect(partOf(run(c, 'set_depth', {'part': 'plate', 'depth': 5}))['name'], 'plate');
    run(c, 'select_part', {'part': 'plate'});
    expect(c.active.name, 'plate');

    final doc = run(c, 'delete_part', {'part': 'spacer'});
    expect((doc['parts'] as List), hasLength(1));
  });

  test('add_part into an untouched editor replaces the placeholder', () {
    final c = SketchController();
    run(c, 'add_part', {
      'part': {
        'name': 'tab',
        'depth': 3,
        'profile': [
          [0, 0],
          [10, 0],
          [10, 10],
        ]
      }
    });
    expect([for (final p in c.parts) p.name], ['tab']);
  });

  test('export_stl returns a binary STL of the active part', () {
    final c = plate();
    final result = run(c, 'export_stl');
    expect(result['fileName'], 'plate.stl');
    final bytes = base64Decode(result['stlBase64'] as String);
    // Binary STL: 80-byte header, uint32 count, 50 bytes per triangle.
    final count = bytes.buffer.asByteData().getUint32(80, Endian.little);
    expect(count, result['triangles']);
    expect(bytes.length, 84 + 50 * count);
    expect(count, greaterThan(12), reason: 'a plate with a hole');
  });

  test('mistakes come back as instructions, not crashes', () {
    final c = plate();
    expect(() => run(c, 'move_vertex', {'vertex': 9, 'to': [0, 0]}),
        throwsA(isA<HostCommandException>().having((e) => e.message, 'message',
            contains('index from 0 to 3'))));
    expect(() => run(c, 'set_depth', {'part': 'nope', 'depth': 5}),
        throwsA(isA<HostCommandException>().having((e) => e.message, 'message',
            contains('Parts: "plate"'))));
    expect(() => run(c, 'add_constraint', {'kind': 'parallel', 'edges': [0]}),
        throwsA(isA<HostCommandException>()));
    expect(() => run(c, 'add_hole', {'center': [1], 'radius': 2}),
        throwsA(isA<HostCommandException>()));
    expect(() => run(c, 'remove_hole', {'hole': 3}),
        throwsA(isA<HostCommandException>()));
    expect(() => run(c, 'frobnicate'), throwsA(isA<HostCommandException>()));

    // An open sketch has no vertices to address, and can't be exported.
    final open = SketchController()
      ..addSegmentBetween(const Offset(0, 0), const Offset(50, 0));
    expect(() => run(open, 'move_vertex', {'vertex': 0, 'to': [1, 1]}),
        throwsA(isA<HostCommandException>().having((e) => e.message, 'message',
            contains('does not have a closed profile'))));
    expect(() => run(open, 'export_stl'), throwsA(isA<HostCommandException>()));
    expect(() => run(SketchController(), 'undo'),
        throwsA(isA<HostCommandException>()));
  });
}
