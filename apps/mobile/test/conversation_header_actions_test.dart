import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/conversations/conversation_header_actions.dart';

/// Build 62 on a Galaxy S9+ (1080 px, 420 dpi) showed a conversation header
/// with an avatar and five icons and no conversation name at all. The name has
/// a floor now, and these assert that the floor holds and that nothing is
/// silently dropped when it does.
void main() {
  final tapped = <String>[];

  List<ConversationHeaderAction> actions() => [
    for (final name in ['call', 'video', 'search', 'threads', 'details'])
      ConversationHeaderAction(
        id: Key(name),
        icon: Icons.circle,
        label: name,
        onPressed: () => tapped.add(name),
      ),
  ];

  setUp(tapped.clear);

  Widget host(List<Widget> children) => MaterialApp(
    home: Scaffold(appBar: AppBar(title: Row(children: children))),
  );

  testWidgets('a wide header shows every action as an icon', (tester) async {
    await tester.pumpWidget(
      host(
        conversationHeaderActions(actions(), width: 700, titleFloor: 142),
      ),
    );

    expect(find.byType(IconButton), findsNWidgets(5));
    expect(find.byKey(const Key('conversation-header-overflow')), findsNothing);
  });

  testWidgets('a phone-width header keeps the name and folds the rest', (
    tester,
  ) async {
    // 411 logical pixels wide less the back button, which is what the S9+ gave
    // the title area.
    await tester.pumpWidget(
      host(
        conversationHeaderActions(actions(), width: 355, titleFloor: 142),
      ),
    );

    // Three icons and the overflow: four slots of 48 leave 163 for the name,
    // comfortably above the 142 floor.
    expect(find.byKey(const Key('call')), findsOneWidget);
    expect(find.byKey(const Key('video')), findsOneWidget);
    expect(find.byKey(const Key('search')), findsOneWidget);
    expect(find.byKey(const Key('threads')), findsNothing);
    expect(find.byKey(const Key('details')), findsNothing);

    await tester.tap(find.byKey(const Key('conversation-header-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('details')));
    await tester.pumpAndSettle();

    expect(tapped, ['details']);
  });

  testWidgets('a header with room for nothing still offers every action', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(conversationHeaderActions(actions(), width: 150, titleFloor: 142)),
    );

    // The overflow button is itself an `IconButton`, so what proves nothing
    // stayed outside the menu is that no action key is on screen yet.
    expect(find.byKey(const Key('call')), findsNothing);
    await tester.tap(find.byKey(const Key('conversation-header-overflow')));
    await tester.pumpAndSettle();
    for (final name in ['call', 'video', 'search', 'threads', 'details']) {
      expect(find.byKey(Key(name)), findsOneWidget);
    }
  });
}
