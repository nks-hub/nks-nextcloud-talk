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

  testWidgets(
    'Ctrl+V reads clipboard files, preserves text paste and leaves the '
    'bitmap of copied text alone',
    (tester) async {
      staleModifierRepair.attach();
      final calls = <String>[];
      var files = <String>[];
      String? text;
      const channel = MethodChannel('pasteboard');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        return call.method == 'files' ? files : null;
      });
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => switch (call.method) {
          'Clipboard.getData' => text == null ? null : {'text': text},
          'Clipboard.hasStrings' => {'value': text != null},
          _ => null,
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });
      await pumpRoom(tester);
      final field = find.byKey(const Key('chat-composer'));
      // A spreadsheet range comes with a bitmap of itself beside its text.
      for (final (selection, copied, asked) in [
        (<String>[], 'Pasted text', ['files']),
        (<String>[], null, ['files', 'image']),
        (['slides.pptx', 'document.docx'], 'Pasted text', ['files']),
      ]) {
        files = selection;
        text = copied;
        calls.clear();
        tester.widget<TextField>(field).controller!.clear();
        await tester.tap(field);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(calls, asked);
        expect(tester.widget<TextField>(field).controller!.text, copied ?? '');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'a pointer over a message says the bubble is a target',
    (tester) async {
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
    },
    variant: TargetPlatformVariant.desktop(),
  );

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

  testWidgets('leaving and reopening a quoted draft restores the same parent', (
    tester,
  ) async {
    await pumpRoom(tester);
    final composer = find.byKey(const Key('chat-composer'));
    await tester.enterText(composer, 'Reply to this message');
    await tester.longPress(find.byKey(const Key('chat-message-target-10')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('message-action-reply')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => database.select(database.chatDrafts).get());

    await pumpRoom(tester);
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('chat-reply-banner')).evaluate().isNotEmpty,
    );
    expect(
      tester.widget<TextField>(composer).controller!.text,
      'Reply to this message',
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('chat-reply-banner')),
        matching: find.textContaining('Cached hello'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('chat-cancel-reply')));
    await tester.pumpWidget(const SizedBox.shrink());
    final stored = await tester.runAsync(
      () => ChatRepository(
        database,
      ).readComposerDraft(accountId: account.id, roomToken: conversation.token),
    );
    expect(stored?.text, 'Reply to this message');
    expect(stored?.reply, isNull);
    await tester.pump(const Duration(milliseconds: 1));
  });

  for (final (name, sentAfterDraft, sentBeforeDraft) in const [
    ('a draft whose send is already in the outbox', true, false),
    ('a draft whose send never reached the outbox', false, false),
    ('a draft typed again after the same text was sent', false, true),
  ]) {
    testWidgets(
      '$name ${sentAfterDraft ? 'is not offered again' : 'is back in the field'}',
      (tester) async {
        // What a killed process leaves behind: the text of a send kept as the
        // draft until its admission, and the outbox row if admission made it.
        await tester.runAsync(() async {
          if (sentBeforeDraft) {
            await _insertPendingOperation(
              database,
              account,
              conversation,
              operationId: 'op-earlier',
              outboxState: 'completed',
              message: 'kill-s1',
            );
          }
          await database
              .into(database.chatDrafts)
              .insert(
                ChatDraftsCompanion.insert(
                  accountId: account.id,
                  roomToken: conversation.token,
                  scopeKey: 'root',
                  draftText: 'kill-s1',
                  updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
                ),
              );
          if (sentAfterDraft) {
            await _insertPendingOperation(
              database,
              account,
              conversation,
              operationId: 'op-admitted',
              outboxState: 'queued',
              message: 'kill-s1',
              createdAtMillis: DateTime.now().millisecondsSinceEpoch + 1000,
            );
          }
        });

        await pumpRoom(tester);
        String composerText() => tester
            .widget<TextField>(find.byKey(const Key('chat-composer')))
            .controller!
            .text;
        await _pumpUntil(
          tester,
          () => sentAfterDraft
              ? find
                    .byKey(const Key('chat-pending-op-admitted'))
                    .evaluate()
                    .isNotEmpty
              : composerText() == 'kill-s1',
        );
        // Room for a draft that should not come back to come back.
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 10));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
        }

        expect(composerText(), sentAfterDraft ? isEmpty : 'kill-s1');
        if (sentAfterDraft) {
          expect(find.text('kill-s1'), findsOneWidget);
        }
        final stored = await tester.runAsync(
          () => database.select(database.chatDrafts).get(),
        );
        expect(stored!.map((row) => row.draftText), [
          if (!sentAfterDraft) 'kill-s1',
        ]);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      },
      variant: TargetPlatformVariant.desktop(),
    );
  }

  testWidgets(
    'leaving straight after typing still keeps the draft',
    (tester) async {
      // The draft is written half a second after the last keystroke, and
      // leaving the room only cancelled that timer: typing and pressing back
      // in the same breath lost the text.
      await pumpRoom(tester);
      await tester.tap(find.byKey(const Key('chat-composer')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('chat-composer')),
        'rozepsany text',
      );
      await tester.pump();

      // Gone before the debounce could fire.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      // The write is started by the disposal and not awaited by it, so it
      // needs a turn of the loop before the row is there.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 1));

      expect(
        await ChatRepository(
          database,
        ).readDraft(accountId: 'account-a', roomToken: 'rooma123'),
        'rozepsany text',
      );
    },
    variant: TargetPlatformVariant.desktop(),
  );

  testWidgets(
    'Enter in the composer stays a message, not a menu',
    (tester) async {
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
    },
    variant: TargetPlatformVariant.desktop(),
  );

  testWidgets(
    'a reaction chip lets the hover ink through',
    (tester) async {
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
    },
    variant: TargetPlatformVariant.desktop(),
  );
}
