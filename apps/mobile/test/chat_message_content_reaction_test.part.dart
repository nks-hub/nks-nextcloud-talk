part of 'chat_message_content_test.dart';

void _registerReactionSummaryTests() {
  testWidgets('large reaction sets stay bounded and fully interactive', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    String? tappedReaction;
    final reactions = <String, Object?>{
      for (var index = 0; index < 200; index++)
        String.fromCharCode(0x1F300 + index): index + 1,
    };
    final orderedReactions = reactions.keys.toList()..sort();
    final selectedReaction = orderedReactions.last;
    final message = ChatMessage.fromJson(<String, Object?>{
      ..._message.wire,
      'id': 60,
      'referenceId': 'reference-60',
      'reactions': reactions,
      'reactionsSelf': <Object?>[selectedReaction],
    });

    await tester.pumpWidget(
      _app(
        const TextScaler.linear(2),
        message: message,
        mediaSize: const Size(400, 800),
        contentWidth: 320,
        onReactionTap: (reaction) => tappedReaction = reaction,
      ),
    );

    expect(find.byKey(const Key('chat-reaction-60-0')), findsOneWidget);
    expect(find.byKey(const Key('chat-reaction-60-12')), findsNothing);
    expect(find.byKey(const Key('chat-reaction-60-199')), findsNothing);
    await tester.tap(find.byKey(const Key('chat-reaction-more-60')));
    await tester.pumpAndSettle();

    final listFinder = find.byKey(const Key('chat-reaction-list-60'));
    final list = tester.widget<ListView>(listFinder);
    expect(list.childrenDelegate, isA<SliverChildBuilderDelegate>());
    final lastReaction = find.byKey(const Key('chat-reaction-dialog-60-199'));
    expect(
      lastReaction,
      findsNothing,
      reason: 'off-screen reactions must not be built up front',
    );

    await tester.scrollUntilVisible(
      lastReaction,
      500,
      scrollable: find.descendant(
        of: listFinder,
        matching: find.byType(Scrollable),
      ),
    );
    await tester.ensureVisible(lastReaction);
    await tester.pump();
    expect(
      tester.getSemantics(lastReaction),
      matchesSemantics(
        label: '$selectedReaction, ${reactions[selectedReaction]}',
        hasSelectedState: true,
        isSelected: true,
        isButton: true,
        hasTapAction: true,
      ),
    );
    await tester.tap(lastReaction);
    await tester.pumpAndSettle();

    expect(tappedReaction, selectedReaction);
    expect(find.byKey(const Key('chat-reaction-dialog-60')), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
