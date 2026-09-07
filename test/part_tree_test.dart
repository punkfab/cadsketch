import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/sketch/model.dart';
import 'package:ai_sketcher/sketch/plane.dart';
import 'package:ai_sketcher/ui/part_tree.dart';
import 'package:ai_sketcher/ui/sketch_canvas.dart';

Widget _host(SketchController c) => MaterialApp(
      home: Scaffold(
        body: Row(children: [
          PartTree(controller: c),
          const Expanded(child: SizedBox()),
        ]),
      ),
    );

SketchController _seed() {
  final c = SketchController();
  // Base body with a 2-segment sketch and a mate point.
  c.model.points.addAll(const [Offset(0, 0), Offset(10, 0), Offset(10, 10)]);
  c.model.segments
    ..add(Segment(0, 1))
    ..add(Segment(1, 2));
  c.addConnector(0);
  final base = c.active;
  // A face feature (a boss) nested on the base body.
  c.addPlaneSketch(
    SketchPlane.xy,
    name: 'Boss',
    reference: const [Offset(0, 0), Offset(10, 0), Offset(10, 10), Offset(0, 10)],
    parent: base,
  );
  c.setActive(0); // start with the base active
  return c;
}

void main() {
  testWidgets('renders parts hierarchically with sketch + mate nodes',
      (tester) async {
    await tester.pumpWidget(_host(_seed()));
    await tester.pumpAndSettle();

    expect(find.text('Part 1'), findsOneWidget);
    expect(find.text('Boss'), findsOneWidget); // the nested feature
    expect(find.textContaining('2 lines'), findsOneWidget); // base sketch node
    expect(find.textContaining('mate point'), findsOneWidget); // mate node
  });

  testWidgets('tapping a part row makes it active', (tester) async {
    final c = _seed();
    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();
    expect(c.activeIndex, 0);

    await tester.tap(find.text('Boss'));
    await tester.pumpAndSettle();
    expect(c.activeIndex, 1);
  });

  testWidgets('collapsing a part hides its children', (tester) async {
    await tester.pumpWidget(_host(_seed()));
    await tester.pumpAndSettle();
    expect(find.text('Boss'), findsOneWidget);

    // The base is the only expandable node (its Boss child).
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    expect(find.text('Boss'), findsNothing);
  });

  testWidgets('the panel collapses to a rail and back', (tester) async {
    await tester.pumpWidget(_host(_seed()));
    await tester.pumpAndSettle();
    expect(find.text('Parts'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_left)); // hide
    await tester.pumpAndSettle();
    expect(find.text('Parts'), findsNothing);
    expect(find.byIcon(Icons.account_tree_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.account_tree_outlined)); // show
    await tester.pumpAndSettle();
    expect(find.text('Parts'), findsOneWidget);
  });
}
