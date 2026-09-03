part of 'chat_room_pane_test.dart';

/// Desktop reaches a chat with a pointer that hovers and a keyboard that
/// traverses. Both used to stop at the bubble: the action sheet answered only
/// to a long press and a right click, and nothing in the timeline could take
/// focus at all.
void _registerChatRoomPaneDesktopInputTests() {
  /// The ring colour the affordance is currently painting, or null when the
  /// bubble is not wrapped in one at all.
  Color? affordanceRing(WidgetTester tester, int messageId) {
    final finder = find.byKey(Key('chat-message-ring-$messageId'));
    if (finder.evaluate().isEmpty) {
      return null;
    }
    final decoration =
        tester.widget<DecoratedBox>(finder).decoration as BoxDecoration;
    return decoration.border?.top.color;
  }

  /// Walks Tab until the focused node sits inside [key], and says how many
  /// presses that took so a caller can assert on the order.
  Future<int?> tabTo(WidgetTester tester, String key, {int limit = 40}) async {
    for (var press = 1; press <= limit; press++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) {
        continue;
      }
      var found = false;
      context.visitAncestorElements((element) {
        final widgetKey = element.widget.key;
        if (widgetKey is ValueKey<String> && widgetKey.value == key) {
          found = true;
          return false;
        }
        return true;
      });
      if (found) {
        return press;
      }
    }
    return null;
  }

  Future<void> pumpRoom(WidgetTester tester) async {
    await tester.pumpWidget(
      app(
        home: roomScreen(),
        overrides: [
          chatMessageActionsProfileProvider.overrideWith(
            (ref, key) async => _capabilityProfile(reply: true, react: true),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a pointer over a message says the bubble is a target', (
    tester,
  ) async {
    await pumpRoom(tester);
    expect(
      affordanceRing(tester, 10),
      Colors.transparent,
      reason: 'an untouched bubble must draw no ring',
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();

    await mouse.moveTo(
      tester.getCenter(find.byKey(const Key('chat-message-target-10'))),
    );
    await tester.pumpAndSettle();
    expect(
      affordanceRing(tester, 10),
      isNot(Colors.transparent),
      reason: 'hovering a bubble must show that it can be acted on',
    );

    // And it has to go away again: a ring left behind points at a message the
    // pointer is no longer on.
    await mouse.moveTo(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(affordanceRing(tester, 10), Colors.transparent);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('a keyboard reaches the message actions and the composer after '
      'them', (tester) async {
    await pumpRoom(tester);

    final toMessage = await tabTo(tester, 'chat-message-affordance-10');
    expect(toMessage, isNot(null), reason: 'Tab must reach the message');
    // Focus has to be visible, not merely present: a ring nobody can see is
    // the same as no focus at all for anyone driving this by keyboard.
    expect(affordanceRing(tester, 10), isNot(Colors.transparent));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('message-action-reply')),
      findsOneWidget,
      reason: 'the sheet the mouse gets on a right click',
    );
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();

    // Reading order: the composer sits below the timeline, so it comes after
    // the messages and focus must not stop dead at the last bubble.
    final toComposer = await tabTo(tester, 'chat-composer');
    expect(
      toComposer,
      isNot(null),
      reason: 'Tab must carry on from the message to the composer',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('Enter in the composer stays a message, not a menu', (
    tester,
  ) async {
    await pumpRoom(tester);

    // Focus in a text field means the key belongs to the text field. The
    // bubble binding must not reach across and open its sheet instead.
    await tester.tap(find.byKey(const Key('chat-composer')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('chat-composer')), 'typed');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('message-action-reply')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('a reaction chip lets the hover ink through', (tester) async {
    await _insertCachedMessage(
      database,
      _messageJson(
        id: 71,
        actorId: 'someone-else',
        actorDisplayName: 'Other person',
        timestamp: 1724300500,
        message: 'Reacted to',
        reactions: const {'👍': 2},
      ),
      displayText: 'Reacted to',
    );
    await pumpRoom(tester);

    final chip = find.byKey(const Key('chat-reaction-71-0'));
    expect(chip, findsOneWidget);
    // Ink paints between a Material and its child, so an opaque box inside
    // the InkWell hides the hover highlight and the chip looks dead under a
    // pointer. The colour belongs on the Material above the ink instead.
    expect(
      find.descendant(
        of: find.descendant(of: chip, matching: find.byType(InkWell)),
        matching: find.byType(DecoratedBox),
      ),
      findsNothing,
      reason: 'an opaque box under the ink swallows the hover highlight',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }, variant: TargetPlatformVariant.desktop());
}
