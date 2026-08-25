part of 'chat_room_pane_test.dart';

void _registerChatRoomPaneInteractionTests() {
  testWidgets('composer text survives losing the pane', (tester) async {
    // A send can be refused before the outbox admits it, for example while
    // offline, so the typed text must not depend on the widget staying alive.
    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
      ),
    );
    await tester.pump();

    await tester.enterText(
      find.byKey(const Key('chat-composer')),
      'Draft that must not be lost',
    );
    await tester.pump(const Duration(milliseconds: 600));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Draft that must not be lost'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('chat header and composer remain accessible at 200% text', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(900, 800),
            textScaler: TextScaler.linear(2),
          ),
          child: ChatRoomPane(
            account: account,
            conversation: conversation.copyWith(
              description: 'Accessible room description',
            ),
            showHeader: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.getSize(find.byKey(const Key('chat-room-header'))).height,
      greaterThan(72),
    );
    await tester.enterText(
      find.byKey(const Key('chat-composer')),
      'Draft message',
    );
    await tester.pump();
    expect(find.text('Write a message'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('composer exposes one named editable semantics node', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
      ),
    );
    await tester.pump();

    final composer = find.byKey(const Key('chat-composer'));
    final composerNodes = find.semantics
        .byPredicate(
          (node) => node.getSemanticsData().flagsCollection.isTextField,
        )
        .evaluate()
        .toList();
    expect(composerNodes, hasLength(1));

    final namedComposerNodes = find.semantics
        .byLabel('Write a message')
        .evaluate()
        .where((node) => node.getSemanticsData().flagsCollection.isTextField)
        .toList();
    expect(namedComposerNodes, hasLength(1));
    expect(namedComposerNodes.single, same(composerNodes.single));

    final data = namedComposerNodes.single.getSemanticsData();
    expect(data.label, 'Write a message');
    expect(data.flagsCollection.isTextField, isTrue);
    expect(data.flagsCollection.isReadOnly, isFalse);
    expect(data.hasAction(ui.SemanticsAction.tap), isTrue);

    await tester.tap(composer);
    await tester.pump();
    expect(
      namedComposerNodes.single.getSemanticsData().hasAction(
        ui.SemanticsAction.setText,
      ),
      isTrue,
    );

    await tester.enterText(composer, 'Accessible draft');
    await tester.pump();
    expect(
      namedComposerNodes.single.getSemanticsData().value,
      'Accessible draft',
    );
    expect(
      find.semantics
          .byLabel('Write a message')
          .evaluate()
          .where((node) => node.getSemanticsData().flagsCollection.isTextField),
      hasLength(1),
    );

    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('incoming avatar is decorative beside its author label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
      ),
    );
    await tester.pump();

    final avatarSemantics = tester
        .getSemantics(find.byKey(const Key('chat-avatar-10')))
        .getSemanticsData();
    expect(avatarSemantics.flagsCollection.isImage, isFalse);
    expect(avatarSemantics.label, isEmpty);
    expect(
      tester
          .getSemantics(find.byKey(const Key('chat-message-semantics-10')))
          .getSemanticsData()
          .label,
      'Other person',
    );

    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'every grouped incoming and outgoing message exposes its author',
    (tester) async {
      final semantics = tester.ensureSemantics();
      const firstTimestamp = 1724300000;
      await _insertCachedMessage(
        database,
        _messageJson(
          id: 11,
          actorId: 'someone-else',
          actorDisplayName: 'Other person',
          timestamp: firstTimestamp + 60,
          message: 'Grouped follow-up',
        ),
        displayText: 'Grouped follow-up',
      );
      await _insertCachedMessage(
        database,
        _messageJson(
          id: 12,
          actorId: account.loginName,
          actorDisplayName: 'Fixture User',
          timestamp: firstTimestamp + 120,
          message: 'Outgoing follow-up',
        ),
        displayText: 'Outgoing follow-up',
      );

      await tester.pumpWidget(
        app(
          home: ChatRoomScreen(account: account, conversation: conversation),
        ),
      );
      await tester.pump();

      expect(
        tester
            .getSemantics(find.byKey(const Key('chat-message-semantics-10')))
            .getSemanticsData()
            .label,
        'Other person',
      );
      expect(
        tester
            .getSemantics(find.byKey(const Key('chat-message-semantics-11')))
            .getSemanticsData()
            .label,
        'Other person',
      );
      expect(
        tester
            .getSemantics(find.byKey(const Key('chat-message-semantics-12')))
            .getSemanticsData()
            .label,
        'Fixture User',
      );

      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('ambiguous send requires duplicate-risk confirmation', (
    tester,
  ) async {
    await database
        .into(database.textSendOperations)
        .insert(
          TextSendOperationsCompanion.insert(
            accountId: account.id,
            operationId: 'operation-a',
            roomToken: conversation.token,
            referenceId: 'reference-a',
            message: 'Possibly $_giphyResourceUrl sent',
            replayContractRevision: 'fixture-revision',
            enqueueSequence: 1,
            outboxState: 'awaitingConfirmation',
            attemptCount: 1,
            messageIdsJson: '[]',
            duplicateRiskAcknowledged: false,
            createdAtMillis: 1,
            updatedAtMillis: 1,
          ),
        );

    await tester.pumpWidget(
      app(
        home: ChatRoomPane(account: account, conversation: conversation),
      ),
    );
    await tester.pump();
    expect(find.text('Possibly GIF sent'), findsOneWidget);
    expect(find.textContaining(_giphyResourceUrl), findsNothing);
    await tester.tap(find.byKey(const Key('chat-resend-operation-a')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('duplicate-risk-dialog')), findsOneWidget);
    expect(find.byKey(const Key('confirm-duplicate-risk')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('cancelling a queued send clears the outbox row and bubble', (
    tester,
  ) async {
    await _insertPendingOperation(
      database,
      account,
      conversation,
      operationId: 'operation-q',
      outboxState: 'queued',
      message: 'Queued fixture text',
    );

    await tester.pumpWidget(
      app(
        home: ChatRoomPane(account: account, conversation: conversation),
      ),
    );
    await tester.pump();
    expect(find.text('Queued fixture text'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-cancel-operation-q')));
    await _pumpUntil(
      tester,
      () => find.text('Queued fixture text').evaluate().isEmpty,
    );

    expect(
      await (database.select(database.textSendOperations)
            ..where((operation) => operation.operationId.equals('operation-q')))
          .getSingleOrNull(),
      isNull,
    );
    expect(find.byKey(const Key('chat-cancel-operation-q')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('cancelling an ambiguous send keeps it and says why', (
    tester,
  ) async {
    await _insertPendingOperation(
      database,
      account,
      conversation,
      operationId: 'operation-x',
      outboxState: 'awaitingConfirmation',
      message: 'Maybe sent fixture text',
      attemptCount: 1,
    );

    // The refusal is a snackbar, so this needs the screen that owns a
    // Scaffold rather than the bare pane.
    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('chat-cancel-operation-x')));
    await _pumpUntil(
      tester,
      () => find
          .text(
            'This message may already have reached the server, so it can no '
            'longer be cancelled.',
          )
          .evaluate()
          .isNotEmpty,
    );

    final row =
        await (database.select(database.textSendOperations)..where(
              (operation) => operation.operationId.equals('operation-x'),
            ))
            .getSingleOrNull();
    expect(row?.outboxState, 'awaitingConfirmation');
    expect(find.text('Maybe sent fixture text'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('the actions menu offers edit, delete and react only when both '
      'ownership and capability allow it', (tester) async {
    await _insertCachedMessage(
      database,
      _messageJson(
        id: 70,
        actorId: account.loginName,
        actorDisplayName: 'Fixture User',
        timestamp: 1724300400,
        message: 'My own message',
      ),
      displayText: 'My own message',
    );

    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
        overrides: [
          chatMessageActionsProfileProvider.overrideWith(
            (ref, key) async => _capabilityProfile(
              reply: true,
              edit: true,
              delete: true,
              react: true,
            ),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.longPress(find.byKey(const Key('chat-message-target-70')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('message-action-reply')), findsOneWidget);
    expect(find.byKey(const Key('message-action-copy')), findsOneWidget);
    expect(find.byKey(const Key('message-action-edit')), findsOneWidget);
    expect(find.byKey(const Key('message-action-delete')), findsOneWidget);
    expect(find.byKey(const Key('message-action-react')), findsOneWidget);
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();

    // Message 10 belongs to someone else: edit/delete stay hidden even
    // though this account is fully capable of both.
    await tester.longPress(find.byKey(const Key('chat-message-target-10')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('message-action-edit')), findsNothing);
    expect(find.byKey(const Key('message-action-delete')), findsNothing);
    expect(find.byKey(const Key('message-action-react')), findsOneWidget);
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('without a resolved capability profile reply stays hidden', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.longPress(find.byKey(const Key('chat-message-target-10')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('message-action-reply')), findsNothing);
    expect(find.byKey(const Key('message-action-copy')), findsOneWidget);
    expect(find.byKey(const Key('message-action-edit')), findsNothing);
    expect(find.byKey(const Key('message-action-delete')), findsNothing);
    expect(find.byKey(const Key('message-action-react')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a resolved profile without chat-replies keeps reply hidden', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
        overrides: [
          chatMessageActionsProfileProvider.overrideWith(
            (ref, key) async => _capabilityProfile(),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.longPress(find.byKey(const Key('chat-message-target-10')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('message-action-reply')), findsNothing);
    expect(find.byKey(const Key('message-action-copy')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('copy puts the message text on the clipboard', (tester) async {
    final copiedTexts = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final arguments = Map<Object?, Object?>.from(
            call.arguments as Map<Object?, Object?>,
          );
          copiedTexts.add(arguments['text'] as String?);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
      ),
    );
    await tester.pump();

    await tester.longPress(find.byKey(const Key('chat-message-target-10')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('message-action-copy')));
    await tester.pumpAndSettle();

    expect(copiedTexts, ['Cached hello']);
    expect(find.text('Copied to clipboard'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('the edit dialog survives its own closing transition', (
    tester,
  ) async {
    // Regression: the controller used to be disposed as soon as showDialog
    // returned, while the text field was still mounted for the exit
    // animation. That tripped the framework assertion `_dependents.isEmpty`
    // and crashed the running app, not just the test.
    await _insertCachedMessage(
      database,
      _messageJson(
        id: 91,
        actorId: account.loginName,
        actorDisplayName: 'Fixture User',
        timestamp: 1724300700,
        message: 'Before edit',
      ),
      displayText: 'Before edit',
    );

    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
        overrides: [
          chatMessageActionsProfileProvider.overrideWith(
            (ref, key) async => _capabilityProfile(edit: true),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.longPress(find.byKey(const Key('chat-message-target-91')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('message-action-edit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('edit-message-dialog')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('edit-message-field')),
      'After edit',
    );
    await tester.tap(find.byKey(const Key('confirm-edit-message')));

    // Pump the whole closing transition frame by frame; the crash happened
    // while the dialog was still on its way out.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('edit-message-dialog')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('cancelling delete leaves the message untouched', (tester) async {
    await _insertCachedMessage(
      database,
      _messageJson(
        id: 90,
        actorId: account.loginName,
        actorDisplayName: 'Fixture User',
        timestamp: 1724300600,
        message: 'Editable text',
      ),
      displayText: 'Editable text',
    );

    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
        overrides: [
          // Cancelling never reaches the network, so the menu only needs a
          // capability profile pinned; the default unmocked API (as used by
          // every other test in this file) is left untouched.
          chatMessageActionsProfileProvider.overrideWith(
            (ref, key) async => _capabilityProfile(delete: true),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.longPress(find.byKey(const Key('chat-message-target-90')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('message-action-delete')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('delete-message-dialog')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Editable text'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'shows the load-older control while history remains, and hides it '
    'once the scope reports it is exhausted',
    (tester) async {
      await database
          .into(database.chatScopes)
          .insert(
            ChatScopesCompanion.insert(
              accountId: account.id,
              roomToken: conversation.token,
              scopeKey: 'root',
              historyCursor: '10',
              futureCursor: '10',
              lastCommonRead: '10',
              lastReadMessage: 0,
              unreadMessages: 0,
              hasHistory: true,
              futureConverged: true,
              blocksJson: '[["10","10"]]',
            ),
          );

      await tester.pumpWidget(
        app(
          home: ChatRoomScreen(account: account, conversation: conversation),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('chat-load-older')), findsOneWidget);
      expect(find.text('Load older messages'), findsOneWidget);

      // A real page fetch that flips `hasHistory` to false is already
      // covered end-to-end by chat_service_integration_test.dart and the
      // talk_protocol merge fixtures; this only has to prove the pane reacts
      // to that scope change, so it writes the resulting state directly.
      await (database.update(database.chatScopes)..where(
            (scope) =>
                scope.accountId.equals(account.id) &
                scope.roomToken.equals(conversation.token) &
                scope.scopeKey.equals('root'),
          ))
          .write(const ChatScopesCompanion(hasHistory: Value(false)));
      await tester.pump();

      expect(find.byKey(const Key('chat-load-older')), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets(
    'tapping load older surfaces a retry-able error without leaving the '
    'control stuck spinning',
    (tester) async {
      await database
          .into(database.chatScopes)
          .insert(
            ChatScopesCompanion.insert(
              accountId: account.id,
              roomToken: conversation.token,
              scopeKey: 'root',
              historyCursor: '10',
              futureCursor: '10',
              lastCommonRead: '10',
              lastReadMessage: 0,
              unreadMessages: 0,
              hasHistory: true,
              futureConverged: true,
              blocksJson: '[["10","10"]]',
            ),
          );

      await tester.pumpWidget(
        app(
          home: ChatRoomScreen(account: account, conversation: conversation),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('chat-load-older')), findsOneWidget);

      // No app password is stored for this account (the vault is empty, as
      // in every other test in this file), so the real ChatService fails
      // fast with a credential error instead of reaching the network -
      // deterministic, and it exercises the exact catch/retry path a real
      // failed page fetch would take.
      await tester.tap(find.byKey(const Key('chat-load-older')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('retry-chat-sync')), findsOneWidget);
      // hasHistory was never touched by the failed attempt, so the control
      // must still be there, enabled, ready for the user to retry directly.
      final loadOlderButton = tester.widget<TextButton>(
        find.descendant(
          of: find.byKey(const Key('chat-load-older')),
          matching: find.byType(TextButton),
        ),
      );
      expect(loadOlderButton.onPressed != null, isTrue);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('retry-chat-sync')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('keeps two disjoint cached ranges visibly separated instead of '
      'gluing them into one history', (tester) async {
    await _insertCachedMessage(
      database,
      _messageJson(
        id: 20,
        actorId: 'someone-else',
        actorDisplayName: 'Other person',
        timestamp: 1724300100,
        message: 'Older block message',
      ),
      displayText: 'Older block message',
    );
    await _insertCachedMessage(
      database,
      _messageJson(
        id: 50,
        actorId: 'someone-else',
        actorDisplayName: 'Other person',
        timestamp: 1724300200,
        message: 'Boundary before the gap',
      ),
      displayText: 'Boundary before the gap',
    );
    // Falls inside the gap (51-69): never confirmed by a fetch, so it
    // must never render even though the row happens to be cached, for
    // example a leftover from a state the client no longer stands behind.
    await _insertCachedMessage(
      database,
      _messageJson(
        id: 60,
        actorId: 'someone-else',
        actorDisplayName: 'Other person',
        timestamp: 1724300250,
        message: 'Ghost message inside the gap',
      ),
      displayText: 'Ghost message inside the gap',
    );
    await _insertCachedMessage(
      database,
      _messageJson(
        id: 80,
        actorId: 'someone-else',
        actorDisplayName: 'Other person',
        timestamp: 1724300300,
        message: 'First message after the gap',
      ),
      displayText: 'First message after the gap',
    );
    await database
        .into(database.chatScopes)
        .insert(
          ChatScopesCompanion.insert(
            accountId: account.id,
            roomToken: conversation.token,
            scopeKey: 'root',
            historyCursor: '10',
            futureCursor: '100',
            lastCommonRead: '10',
            lastReadMessage: 0,
            unreadMessages: 0,
            hasHistory: false,
            futureConverged: true,
            blocksJson: '[["10","50"],["70","100"]]',
          ),
        );

    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
      ),
    );
    await tester.pump();

    expect(find.text('Cached hello'), findsOneWidget);
    expect(find.text('Older block message'), findsOneWidget);
    expect(find.text('Boundary before the gap'), findsOneWidget);
    expect(find.text('First message after the gap'), findsOneWidget);
    expect(find.text('Ghost message inside the gap'), findsNothing);
    expect(find.byKey(const Key('chat-history-gap')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
