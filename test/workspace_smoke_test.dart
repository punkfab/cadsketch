import 'package:flutter_test/flutter_test.dart';

import 'package:ai_sketcher/main.dart';
import 'package:ai_sketcher/ui/scene_view.dart';

// Smoke test for the unified workspace as the app home: it builds without error
// and the base-plane menu adds a new plane-sketch (Part). Guards the home
// wiring that the unit tests don't cover.

void main() {
  testWidgets('home renders the workspace and adds a base-plane sketch',
      (tester) async {
    await tester.pumpWidget(const AiSketcherApp());
    await tester.pumpAndSettle();

    // The workspace is the home body.
    expect(find.byType(SceneView), findsOneWidget);
    // Seeded with one part.
    expect(find.text('Part 1'), findsOneWidget);

    // Open the "new sketch on a base plane" menu and pick XZ.
    await tester.tap(find.byTooltip('New sketch on a base plane'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sketch on XZ'));
    await tester.pumpAndSettle();

    // A second part now exists (the new plane-sketch).
    expect(find.text('Part 2'), findsOneWidget);
  });
}
