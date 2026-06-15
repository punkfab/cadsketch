import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/assembly.dart';
import 'package:ai_sketcher/sketch/part.dart';
import 'package:ai_sketcher/sketch/transform3.dart';

Part _prism(String n) {
  final p = Part(n);
  p.sketch.addPolyline(const [
    Offset(0, 0),
    Offset(40, 0),
    Offset(40, 40),
    Offset(0, 40),
    Offset(0, 0),
  ]);
  p.depth = 20;
  return p;
}

void main() {
  test('fasten mate: connector origins coincide and normals oppose', () {
    final a = _prism('A')..connectors.add(MateConnector(1));
    final b = _prism('B')..connectors.add(MateConnector(0));
    final parts = [a, b];

    final xf = solveAssembly(parts, [Mate(0, 0, 1, 0)]);
    expect(xf.containsKey(1), isTrue);

    final sa = a.buildSolid()!, sb = b.buildSolid()!;
    final oa = xf[0]!.apply(a.connectors[0].origin(sa));
    final ob = xf[1]!.apply(b.connectors[0].origin(sb));
    final na = xf[0]!.rot.apply(a.connectors[0].normal(sa)).normalized;
    final nb = xf[1]!.rot.apply(b.connectors[0].normal(sb)).normalized;

    expect((oa - ob).length, lessThan(1e-6));
    expect(dot(na, nb), closeTo(-1, 1e-6));
  });

  test('part 0 grounded; unmated parts parked along +x', () {
    final xf = solveAssembly([_prism('A'), _prism('B')], const []);
    expect(xf[0]!.t.length, 0);
    expect(xf[1]!.t.x, greaterThan(0));
  });

  test('orphaned mate (bad connector index) is skipped, not crashed', () {
    final a = _prism('A'); // no connectors
    final b = _prism('B');
    final xf = solveAssembly([a, b], [Mate(0, 5, 1, 9)]);
    expect(xf.containsKey(0), isTrue); // still solves, mate ignored
  });
}
