part of 'chat_room_pane_test.dart';

void _registerChatRoomPaneThreadContextTests() {
  group('thread pane context', () {
    test('canonical root creates one exclusive send binding', () {
      final namedRoot = _cachedThreadRoot(
        _messageJson(
          id: 69,
          actorId: 'thread-author',
          actorDisplayName: 'Thread author',
          timestamp: 1724300169,
          message: 'Named root',
          threadId: 69,
          isThread: true,
        ),
      );
      final ordinaryWire = _messageJson(
        id: 70,
        actorId: 'thread-author',
        actorDisplayName: 'Thread author',
        timestamp: 1724300170,
        message: 'Ordinary root',
        threadId: 70,
        threadReplies: 1,
      )..['threadTitle'] = 'Title alone is not canonical';
      final ordinaryRoot = _cachedThreadRoot(ordinaryWire);

      final named = ChatThreadContext.fromCachedRoot(
        accountId: account.id,
        roomToken: conversation.token,
        root: namedRoot,
      );
      final ordinary = ChatThreadContext.fromCachedRoot(
        accountId: account.id,
        roomToken: conversation.token,
        root: ordinaryRoot,
      );

      expect(named?.kind, ChatThreadKind.named);
      expect(named?.title, 'Fixture thread');
      expect(named?.replyTo, isNull);
      expect(named?.networkThreadId, 69);
      expect(ordinary?.kind, ChatThreadKind.ordinary);
      expect(ordinary?.title, isNull);
      expect(ordinary?.replyTo, 70);
      expect(ordinary?.networkThreadId, isNull);
    });

    test('cached account and room scope mismatches fail closed', () {
      final root = _cachedThreadRoot(
        _messageJson(
          id: 68,
          actorId: 'thread-author',
          actorDisplayName: 'Thread author',
          timestamp: 1724300168,
          message: 'Scoped root',
          threadId: 68,
          isThread: true,
        ),
      );

      expect(
        ChatThreadContext.fromCachedRoot(
          accountId: 'account-b',
          roomToken: conversation.token,
          root: root,
        ),
        isNull,
      );
      expect(
        ChatThreadContext.fromCachedRoot(
          accountId: account.id,
          roomToken: 'roomb123',
          root: root,
        ),
        isNull,
      );
    });

    testWidgets('named thread route shows its canonical title', (tester) async {
      final root = _messageJson(
        id: 71,
        actorId: 'thread-author',
        actorDisplayName: 'Thread author',
        timestamp: 1724300171,
        message: 'Named thread root',
        threadId: 71,
        isThread: true,
      );
      await _insertCachedMessage(
        database,
        root,
        displayText: 'Named thread root',
      );

      await tester.pumpWidget(app(home: roomScreen()));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('chat-open-thread-71')));
      await tester.tap(find.byKey(const Key('chat-open-thread-71')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('chat-thread-screen-71')), findsOneWidget);
      expect(find.byKey(const Key('chat-background-surface')), findsOneWidget);
      expect(find.text('Fixture thread'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('title alone does not classify an ordinary thread as named', (
      tester,
    ) async {
      final root = _messageJson(
        id: 72,
        actorId: 'thread-author',
        actorDisplayName: 'Thread author',
        timestamp: 1724300172,
        message: 'Ordinary thread root',
        threadId: 72,
        threadReplies: 1,
      )..['threadTitle'] = 'Misleading title';
      await _insertCachedMessage(
        database,
        root,
        displayText: 'Ordinary thread root',
      );

      await tester.pumpWidget(app(home: roomScreen()));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('chat-open-thread-72')));
      await tester.tap(find.byKey(const Key('chat-open-thread-72')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('chat-thread-screen-72')), findsOneWidget);
      expect(find.text('Thread'), findsOneWidget);
      expect(find.text('Misleading title'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('invalid named roots fail closed before navigation', (
      tester,
    ) async {
      final invalidRoots = <Map<String, Object?>>[
        _messageJson(
          id: 73,
          actorId: 'thread-author',
          actorDisplayName: 'Thread author',
          timestamp: 1724300173,
          message: 'Mismatched thread root',
          threadId: 999,
          isThread: true,
        ),
        _messageJson(
          id: 74,
          actorId: 'thread-author',
          actorDisplayName: 'Thread author',
          timestamp: 1724300174,
          message: 'Untitled named thread root',
          threadId: 74,
          isThread: true,
        )..['threadTitle'] = '  ',
      ];
      for (final root in invalidRoots) {
        await _insertThreadRouteRoot(root);
      }

      await tester.pumpWidget(app(home: roomScreen()));
      await tester.pump();

      for (final id in const <int>[73, 74]) {
        final open = find.byKey(Key('chat-open-thread-$id'));
        await tester.ensureVisible(open);
        tester.widget<TextButton>(open).onPressed!();
        await tester.pumpAndSettle();
        expect(find.byKey(Key('chat-thread-screen-$id')), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    for (final testCase in const <({int rootId, bool named})>[
      (rootId: 81, named: false),
      (rootId: 82, named: true),
    ]) {
      testWidgets(
        '${testCase.named ? 'named' : 'ordinary'} text send uses only its '
        'context wire field',
        (tester) => _verifyTextThreadWireField(tester, testCase),
      );
    }

    for (final testCase
        in const <({int rootId, bool initiallyNamed, bool finallyNamed})>[
          (rootId: 83, initiallyNamed: false, finallyNamed: true),
          (rootId: 84, initiallyNamed: true, finallyNamed: false),
        ]) {
      testWidgets(
        'open thread follows a live '
        '${testCase.initiallyNamed ? 'named-to-ordinary' : 'ordinary-to-named'} '
        'root transition',
        (tester) => _verifyTextThreadWireField(
          tester,
          (rootId: testCase.rootId, named: testCase.initiallyNamed),
          expectedNamed: testCase.finallyNamed,
          beforeSend: () async {
            final updatedRoot = _messageJson(
              id: testCase.rootId,
              actorId: 'thread-author',
              actorDisplayName: 'Thread author',
              timestamp: 1724300180 + testCase.rootId,
              message: 'Text routing root',
              threadId: testCase.rootId,
              isThread: testCase.finallyNamed,
              threadReplies: testCase.finallyNamed ? 0 : 1,
            );
            if (testCase.finallyNamed) {
              updatedRoot['threadTitle'] = 'Renamed while open';
            }
            await (database.update(database.cachedChatMessages)..where(
                  (row) =>
                      row.accountId.equals(account.id) &
                      row.roomToken.equals(conversation.token) &
                      row.messageId.equals(testCase.rootId),
                ))
                .write(
                  CachedChatMessagesCompanion(
                    threadId: Value(testCase.rootId),
                    rawJson: Value(jsonEncode(updatedRoot)),
                  ),
                );
            await _pumpUntil(
              tester,
              () => find
                  .text(testCase.finallyNamed ? 'Renamed while open' : 'Thread')
                  .evaluate()
                  .isNotEmpty,
            );
          },
        ),
      );
    }
  });
}

Future<void> _verifyTextThreadWireField(
  WidgetTester tester,
  ({int rootId, bool named}) testCase, {
  bool? expectedNamed,
  Future<void> Function()? beforeSend,
}) async {
  final roomFixture =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final roomOcs = roomFixture['ocs']! as Map<String, Object?>;
  final room = (roomOcs['data']! as List<Object?>).first!;
  await (database.update(database.cachedConversations)..where(
        (row) =>
            row.accountId.equals(account.id) &
            row.token.equals(conversation.token),
      ))
      .write(CachedConversationsCompanion(rawJson: Value(jsonEncode(room))));
  conversation = await database
      .select(database.cachedConversations)
      .getSingle();
  vault.values[account.id] = 'fixture-app-password';

  final wire = _messageJson(
    id: testCase.rootId,
    actorId: 'thread-author',
    actorDisplayName: 'Thread author',
    timestamp: 1724300180 + testCase.rootId,
    message: 'Text routing root',
    threadId: testCase.rootId,
    isThread: testCase.named,
    threadReplies: testCase.named ? 0 : 1,
  );
  await _insertCachedMessage(database, wire, displayText: 'Text routing root');
  final root =
      await (database.select(database.cachedChatMessages)..where(
            (row) =>
                row.accountId.equals(account.id) &
                row.roomToken.equals(conversation.token) &
                row.messageId.equals(testCase.rootId),
          ))
          .getSingle();
  final threadContext = ChatThreadContext.fromCachedRoot(
    accountId: account.id,
    roomToken: conversation.token,
    root: root,
  )!;
  final posts = <Map<String, String>>[];
  final requests = <String>[];
  final api = HttpNextcloudApi(
    client: MockClient((request) async {
      requests.add('${request.method} ${request.url.path}');
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return http.Response(
          jsonEncode(
            capabilitiesJson(
              talkFeatures: const <String>[
                'chat-v2',
                'chat-reference-id',
                'chat-replies',
                'threads',
              ],
            ),
          ),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }
      if (request.method == 'POST') {
        posts.add(Map<String, String>.from(request.bodyFields));
        return http.Response('', 400);
      }
      if (request.url.path.contains('/avatar/')) {
        return http.Response('', 404);
      }
      if (request.method == 'GET' &&
          request.url.path.contains('/apps/spreed/api/v1/chat/')) {
        return http.Response('', 304);
      }
      return http.Response('', 404);
    }),
  );

  await tester.pumpWidget(
    app(
      home: ChatThreadScreen(
        account: account,
        conversation: conversation,
        threadContext: threadContext,
      ),
      overrides: <Override>[nextcloudApiProvider.overrideWithValue(api)],
    ),
  );
  await _pumpUntil(
    tester,
    () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
  );
  await beforeSend?.call();
  await tester.enterText(
    find.byKey(const Key('chat-composer')),
    'Context-specific send ${testCase.rootId}',
  );
  tester.widget<IconButton>(find.byKey(const Key('send-message'))).onPressed!();
  for (var attempt = 0; attempt < 100 && posts.isEmpty; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  expect(posts, isNotEmpty, reason: 'Requests: ${requests.join(', ')}');
  await tester.pump();
  await _pumpUntil(
    tester,
    () =>
        tester
            .widget<IconButton>(find.byKey(const Key('send-message')))
            .onPressed !=
        null,
  );

  if (expectedNamed ?? testCase.named) {
    expect(posts.single['threadId'], '${testCase.rootId}');
    expect(posts.single.containsKey('replyTo'), isFalse);
  } else {
    expect(posts.single['replyTo'], '${testCase.rootId}');
    expect(posts.single.containsKey('threadId'), isFalse);
  }
  await tester.pumpWidget(const SizedBox.shrink());
  await _settleThreadPaneDisposal(tester);
  api.close();
}

Future<void> _settleThreadPaneDisposal(WidgetTester tester) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
}

CachedChatMessage _cachedThreadRoot(Map<String, Object?> wire) {
  return CachedChatMessage(
    accountId: account.id,
    roomToken: conversation.token,
    messageId: wire['id']! as int,
    actorType: wire['actorType']! as String,
    actorId: wire['actorId']! as String,
    actorDisplayName: wire['actorDisplayName']! as String,
    timestamp: wire['timestamp']! as int,
    systemMessage: wire['systemMessage']! as String,
    messageType: wire['messageType']! as String,
    referenceId: wire['referenceId']! as String,
    displayText: wire['message']! as String,
    deleted: false,
    threadId: wire['threadId'] as int?,
    rawJson: jsonEncode(wire),
  );
}

Future<void> _insertThreadRouteRoot(Map<String, Object?> wire) {
  return database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: account.id,
          roomToken: conversation.token,
          messageId: wire['id']! as int,
          actorType: wire['actorType']! as String,
          actorId: wire['actorId']! as String,
          actorDisplayName: wire['actorDisplayName']! as String,
          timestamp: wire['timestamp']! as int,
          systemMessage: wire['systemMessage']! as String,
          messageType: wire['messageType']! as String,
          referenceId: wire['referenceId']! as String,
          displayText: wire['message']! as String,
          deleted: false,
          threadId: Value(wire['id']! as int),
          rawJson: jsonEncode(wire),
        ),
      );
}
