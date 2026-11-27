part of 'conversation_list_filters_test.dart';

void _undeliveredTests() {
  testWidgets(
    'undelivered opens the earliest actionable bubble with its actions and account',
    (tester) async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final account = _account();
      final other = _account(
        id: 'other',
      ).copyWith(selected: false, loginName: 'second');
      final room = _conversation(token: 'rooma123');
      await tester.runAsync(() async {
        await db.into(db.accounts).insert(account);
        await db.into(db.accounts).insert(other);
        await db.into(db.cachedConversations).insert(room);
        await db
            .into(db.cachedChatMessages)
            .insert(_draftParent(account.id, room.token));
        Future<void> put(int i, String state, {String? owner}) => db
            .into(db.textSendOperations)
            .insert(
              TextSendOperationsCompanion.insert(
                accountId: owner ?? account.id,
                operationId: 'op-$i',
                roomToken: room.token,
                referenceId: 'ref-$i',
                message: 'Line $i',
                replayContractRevision: 'fixture',
                enqueueSequence: i,
                outboxState: state,
                attemptCount: 1,
                messageIdsJson: '[]',
                duplicateRiskAcknowledged: false,
                composerThreadId: const Value(42),
                replyTo: const Value(42),
                createdAtMillis: i,
                updatedAtMillis: i,
                automaticResendCount: const Value(3),
              ),
            );
        await put(1, 'completed');
        await put(2, 'skipped');
        await put(3, 'failed', owner: other.id);
        await put(4, 'awaitingConfirmation');
        for (var i = 5; i <= 29; i++) {
          await put(i, 'queued');
        }
        await db
            .into(db.refusedTextDrafts)
            .insert(
              RefusedTextDraft(
                accountId: account.id,
                roomToken: room.token,
                draftId: 'refused',
                message: 'Not accepted',
                silent: false,
                createdAtMillis: 30,
              ),
            );
      });
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          credentialVaultProvider.overrideWithValue(MemoryCredentialVault()),
          conversationAvatarProvider.overrideWith((ref, k) async => null),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: localizedTestApp(
            home: Scaffold(
              body: ConversationListView(
                account: account,
                conversations: [room],
                loading: false,
                onRefresh: () async {},
                onSelect: (_) => fail('expected a thread'),
              ),
            ),
          ),
        ),
      );
      final filter = find.byKey(const Key('conversation-filter-undelivered'));
      await tester.ensureVisible(filter);
      await tester.tap(filter);
      await pumpUntilCondition(
        tester,
        () => find.textContaining('Line 4').evaluate().isNotEmpty,
      );
      expect(find.text('27'), findsOneWidget);
      expect(
        container
            .read(undeliveredMessagesProvider(account.id))
            .requireValue
            .map((e) => e.id),
        isNot(contains('op-3')),
      );
      await tester.tap(find.byKey(const Key('undelivered-room-rooma123')));
      final bubble = find.byKey(const Key('undelivered-target-op-4'));
      await pumpUntilCondition(
        tester,
        () => bubble.hitTestable().evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-thread-screen-42')), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-pending-status-op-4')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-resend-op-4')), findsOneWidget);
      expect(find.byKey(const Key('chat-skip-op-4')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}
