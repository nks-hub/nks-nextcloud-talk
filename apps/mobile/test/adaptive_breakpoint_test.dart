import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/conversations/conversation_shell.dart';

/// Narrowing the window hands the open conversation to the navigator. Nothing
/// underneath that route is built while it covers the screen, so the route is
/// the only thing that can notice the window growing back.
void main() {
  Future<void> pumpPushed(WidgetTester tester, {required Size size}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const PopWhenExpanded(
                      child: Scaffold(body: Text('pushed conversation')),
                    ),
                  ),
                ),
                child: const Text('workspace below'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('workspace below'));
    await tester.pumpAndSettle();
  }

  testWidgets('a widened window pops the conversation back to the workspace', (
    tester,
  ) async {
    await pumpPushed(tester, size: const Size(700, 800));
    expect(find.text('pushed conversation'), findsOneWidget);

    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();

    expect(find.text('pushed conversation'), findsNothing);
    expect(find.text('workspace below'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow window leaves the conversation alone', (tester) async {
    await pumpPushed(tester, size: const Size(700, 800));

    tester.view.physicalSize = const Size(719, 800);
    await tester.pumpAndSettle();

    expect(find.text('pushed conversation'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a screen opened on top keeps the conversation in place', (
    tester,
  ) async {
    await pumpPushed(tester, size: const Size(700, 800));

    final pushedContext = tester.element(find.text('pushed conversation'));
    Navigator.of(pushedContext).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('room details')),
      ),
    );
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();

    // Popping here would yank the details screen out from under the user.
    expect(find.text('room details'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
