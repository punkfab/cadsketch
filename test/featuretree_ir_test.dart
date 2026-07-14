import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/export/featuretree_ir.dart';
import 'package:ai_sketcher/sketch/entities.dart';
import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/sketch/part.dart';

// The bridge to punkfab/featuretree: an ai-sketcher part -> featuretree IR.
// These build sketches by hand (points/segments directly, no solver) so the
// exporter is exercised without the kernel FFI.

/// A closed polygon part: points + a segment ring + an extrude depth.
Part _polyPart(String name, List<Offset> pts, double depth) {
  final p = Part(name);
  p.depth = depth;
  final s = p.sketch;
  s.points.addAll(pts);
  for (var i = 0; i < pts.length; i++) {
    s.segments.add(Segment(i, (i + 1) % pts.length));
  }
  return p;
}

void main() {
  test('a rectangle + interior circle -> profile pad + drilled pocket', () {
    // 40 x 30 plate; a radius-4 hole at its centre -> featuretree's `plate`.
    final part = _polyPart('Plate 1', const [
      Offset(0, 0),
      Offset(40, 0),
      Offset(40, 30),
      Offset(0, 30),
    ], 10);
    part.decorations.add(CircleEntity(const Offset(20, 15), 4));

    final ir = partToIr(part);
    expect(ir['name'], 'plate_1');
    final f = ir['features'] as List;
    expect(f.length, 4);

    expect(f[0]['kind'], 'sketch');
    expect(f[0]['name'], 'profile');
    final wire = (f[0]['polys'] as List).first as List;
    expect(wire.length, 4);
    expect((wire.first as List), [0, 0]); // straight corner, no bulge

    expect(f[1]['kind'], 'pad');
    expect(f[1]['sketch'], 'profile');
    expect(f[1]['length'], 10);

    expect(f[2]['kind'], 'sketch');
    expect(f[2]['circles'], [
      [20, -15, 4] // Y flipped screen->CAD
    ]);

    expect(f[3]['kind'], 'pocket');
    expect(f[3]['sketch'], 'hole0_sketch');
    expect(f[3]['through'], true);
  });

  test('a circle outside the profile is not drilled', () {
    final part = _polyPart('block', const [
      Offset(0, 0),
      Offset(10, 0),
      Offset(10, 10),
      Offset(0, 10),
    ], 5);
    part.decorations.add(CircleEntity(const Offset(50, 50), 2)); // far outside

    final f = partToIr(part)['features'] as List;
    expect(f.length, 2); // profile + pad only, no pocket
    expect(f.every((x) => x['kind'] != 'pocket'), isTrue);
  });

  test('an arc edge is preserved as a DXF bulge, not tessellated', () {
    // Triangle where the p0->p1 edge is a quarter-circle arc.
    final part = _polyPart('wedge', const [
      Offset(0, 0),
      Offset(10, 0),
      Offset(10, 10),
    ], 4);
    // Attach arc data to the first segment (endpoints 0->1).
    part.sketch.segments[0].arc =
        ArcData(const Offset(5, 5), 7.07, math.pi / 2); // sweep 90°

    final f = partToIr(part)['features'] as List;
    final wire = (f[0]['polys'] as List).first as List;
    // The arc's start vertex carries a third element (the bulge); straight ones don't.
    expect((wire[0] as List).length, 3);
    expect((wire[1] as List).length, 2);
    // |bulge| == tan(sweep/4) for a 90° arc.
    final bulge = (wire[0] as List)[2] as num;
    expect(bulge.abs(), closeTo(math.tan(math.pi / 8), 1e-4));
  });

  test('a lone circle (no contour) becomes a padded cylinder', () {
    final part = Part('boss');
    part.depth = 12;
    part.decorations.add(CircleEntity(const Offset(0, 0), 6));

    final f = partToIr(part)['features'] as List;
    expect(f.length, 2);
    expect(f[0]['circles'], [
      [0, 0, 6]
    ]);
    expect(f[1]['kind'], 'pad');
    expect(f[1]['length'], 12);
  });

  test('scale multiplies all lengths', () {
    final part = _polyPart('mm', const [
      Offset(0, 0),
      Offset(4, 0),
      Offset(4, 3),
      Offset(0, 3),
    ], 1);
    final f = partToIr(part, scale: 10)['features'] as List;
    final wire = (f[0]['polys'] as List).first as List;
    expect((wire[1] as List), [40, 0]);
    expect(f[1]['length'], 10);
  });

  // Emits a real IR file so the cross-repo round-trip (build123d volume) can be
  // proven against featuretree outside the Dart VM. Writes to a stable temp path.
  test('emits a plate IR that renders to the known build123d volume', () {
    final part = _polyPart('plate', const [
      Offset(0, 0),
      Offset(40, 0),
      Offset(40, 30),
      Offset(0, 30),
    ], 10);
    part.decorations.add(CircleEntity(const Offset(20, 15), 4));

    final ir = partToIr(part);
    final dir = Directory('${Directory.systemTemp.path}/ai_sketcher_ir')
      ..createSync(recursive: true);
    final file = File('${dir.path}/plate.ir.json');
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(ir));
    // ignore: avoid_print
    print('WROTE_IR ${file.path}');
    expect(file.existsSync(), isTrue);
  });
}
