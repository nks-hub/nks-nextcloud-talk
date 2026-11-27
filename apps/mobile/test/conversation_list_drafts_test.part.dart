part of 'conversation_list_filters_test.dart';

void _draftTests() {
  test(
    'draft ownership and edit times survive restart and account removal',
    () async {
      final dir = await Directory.systemTemp.createTemp('talk-drafts-');
      final file = File('${dir.path}/drafts.sqlite');
      var db = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(() async {
        await db.close();
        await dir.delete(recursive: true);
      });
      final owner = _account();
      final other = _account(
        id: 'account-b',
      ).copyWith(loginName: 'second', selected: false);
      await db.into(db.accounts).insert(owner);
      await db.into(db.accounts).insert(other);
      var now = DateTime.fromMillisecondsSinceEpoch(100);
      var store = ChatRepository(db, clock: () => now);
      const room = 'rooma123';
      final quote = _draftParent(owner.id, room);
      await store.saveDraft(
        accountId: owner.id,
        roomToken: room,
        text: 'same',
        reply: quote,
      );
      now = DateTime.fromMillisecondsSinceEpoch(200);
      await store.saveDraft(
        accountId: owner.id,
        roomToken: room,
        text: 'same',
        threadId: 73,
      );
      await store.saveDraft(
        accountId: other.id,
        roomToken: room,
        text: 'private',
      );
      now = DateTime.fromMillisecondsSinceEpoch(300);
      await store.saveDraft(
        accountId: owner.id,
        roomToken: room,
        text: 'same',
        reply: quote,
      );
      // Old clients could leave a draft and an unrelated outbox row with identical text.
      await db.customStatement(
        "UPDATE chat_drafts SET composer_context=NULL WHERE scope_key='thread:73'",
      );
      await db
          .into(db.textSendOperations)
          .insert(
            TextSendOperationsCompanion.insert(
              accountId: owner.id,
              operationId: 'pending',
              roomToken: room,
              referenceId: 'ref',
              message: 'same',
              replayContractRevision: 'fixture',
              enqueueSequence: 1,
              outboxState: 'queued',
              attemptCount: 0,
              messageIdsJson: '[]',
              duplicateRiskAcknowledged: false,
              createdAtMillis: 400,
              updatedAtMillis: 400,
            ),
          );
      await db.close();
      db = AppDatabase.forTesting(NativeDatabase(file));
      store = ChatRepository(db);
      final rows = await store.watchDrafts(owner.id).first;
      expect(rows.map((r) => r.scopeKey), ['thread:73', 'root']);
      expect(rows.map((r) => r.updatedAtMillis), [200, 100]);
      expect(
        (await store.readComposerDraft(
          accountId: owner.id,
          roomToken: room,
        ))?.reply,
        quote,
      );
      expect(
        await store.readDraft(
          accountId: owner.id,
          roomToken: room,
          threadId: 73,
        ),
        'same',
      );
      await AccountRepository(db).purgeAccount(owner.id);
      await db.into(db.accounts).insert(owner);
      expect(await store.watchDrafts(owner.id).first, isEmpty);
      expect(
        (await store.watchDrafts(other.id).first).single.draftText,
        'private',
      );
    },
  );

  testWidgets(
    'draft filter opens the stored room and exact thread and excludes the other account',
    (tester) async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final account = _account();
      final room = _conversation(token: 'rooma123');
      final other = _account(
        id: 'account-b',
      ).copyWith(loginName: 'second', selected: false);
      final picks = <String>[];
      await tester.runAsync(() async {
        await db.into(db.accounts).insert(account);
        await db.into(db.accounts).insert(other);
        await db.into(db.cachedConversations).insert(room);
        await db
            .into(db.cachedChatMessages)
            .insert(_draftParent(account.id, room.token));
        final store = ChatRepository(db);
        await store.saveDraft(
          accountId: account.id,
          roomToken: room.token,
          text: 'my room text',
        );
        await store.saveDraft(
          accountId: account.id,
          roomToken: room.token,
          threadId: 42,
          text: 'answer in thread',
        );
        await store.saveDraft(
          accountId: other.id,
          roomToken: room.token,
          text: 'another account',
        );
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            conversationAvatarProvider.overrideWith((ref, key) async => null),
          ],
          child: localizedTestApp(
            home: Scaffold(
              body: ConversationListView(
                account: account,
                conversations: [room],
                loading: false,
                onRefresh: () async {},
                onSelect: (room) => picks.add(room.token),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('conversation-filter-drafts')));
      await pumpUntilCondition(
        tester,
        () => find.text('my room text').evaluate().isNotEmpty,
      );
      expect(find.text('another account'), findsNothing);
      await tester.tap(find.text('my room text'));
      expect(picks, [room.token]);
      await tester.tap(find.text('answer in thread'));
      await pumpUntilCondition(
        tester,
        () => find
            .byKey(const Key('chat-thread-screen-42'))
            .evaluate()
            .isNotEmpty,
      );
      await pumpUntilCondition(
        tester,
        () => find
            .byType(TextField)
            .evaluate()
            .any(
              (e) =>
                  (e.widget as TextField).controller?.text ==
                      'answer in thread' &&
                  (e.widget as TextField).focusNode?.hasFocus == true,
            ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}

CachedChatMessage _draftParent(String account, String token) {
  final wire = Map<String, Object?>.from(_roomWire()['lastMessage']! as Map)
    ..['id'] = 42
    ..['token'] = token;
  return CachedChatMessage(
    accountId: account,
    roomToken: token,
    messageId: 42,
    actorType: 'users',
    actorId: 'other',
    actorDisplayName: 'Other',
    timestamp: 1,
    systemMessage: '',
    messageType: 'comment',
    referenceId: '',
    displayText: 'Source',
    deleted: false,
    rawJson: jsonEncode(wire),
  );
}
