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

    _registerDesktopThreadPreviewTests();

    testWidgets('a reopened thread keeps its newest preview above the edge', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(1080, 2400)
        ..devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final image = await _solidPreview(tester, 808, 121);
      await _insertCachedMessage(
        database,
        _messageJson(
          id: 75,
          actorId: 'thread-author',
          actorDisplayName: 'Thread author',
          timestamp: 1724300175,
          message: 'Preview thread',
          threadId: 75,
          isThread: true,
        ),
        displayText: 'Preview thread',
      );
      await _insertCachedMessage(
        database,
        _layoutImageWire(76, includeDimensions: false)..['threadId'] = 75,
        displayText: 'Image reply',
      );

      final preview = Completer<ChatMediaImage?>();
      final open = find.byKey(const Key('chat-open-thread-75'));
      final thread = find.byKey(const Key('chat-thread-screen-75'));
      final list = find.descendant(
        of: thread,
        matching: find.byKey(const Key('chat-message-list')),
      );
      final newest = find.byKey(const Key('chat-message-target-76'));
      final loading = find.byKey(const Key('chat-image-loading-76-0'));
      final ready = find.byKey(const Key('chat-image-76-0'));

      Future<void> enterThread() async {
        await tester.ensureVisible(open);
        await tester.tap(open);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
      }

      void expectNewestGap() {
        final viewport = tester.getRect(list);
        final message = tester.getRect(newest);
        final position = tester
            .widget<CustomScrollView>(list)
            .controller!
            .position;
        expect(position.pixels, 0);
        expect(message.top, greaterThanOrEqualTo(viewport.top));
        expect(viewport.bottom - message.bottom, closeTo(12, 0.01));
      }

      await tester.pumpWidget(
        app(
          home: roomScreen(),
          overrides: [
            threadReplyLayout,
            chatMediaProvider.overrideWith((ref, key) => preview.future),
          ],
        ),
      );
      try {
        await pumpUntilCondition(tester, () => open.evaluate().isNotEmpty);
        await enterThread();
        await pumpUntilCondition(tester, () => loading.evaluate().isNotEmpty);
        final placeholder = tester.getSize(loading);
        expectNewestGap();

        preview.complete(image);
        await pumpUntilCondition(
          tester,
          () => image.decodedDimensions != null && ready.evaluate().isNotEmpty,
        );
        expect(tester.getSize(ready), isNot(placeholder));
        expectNewestGap();

        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(thread, findsNothing);
        await enterThread();
        await pumpUntilCondition(tester, () => ready.evaluate().isNotEmpty);
        expectNewestGap();
      } finally {
        if (!preview.isCompleted) preview.complete(null);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      }
    });

    for (final replyCount in [0, 2]) {
      testWidgets('a thread with $replyCount replies is closed off under its '
          'root and names its room', (tester) async {
        const rootId = 81;
        await _insertCachedMessage(
          database,
          _messageJson(
            id: rootId,
            actorId: 'thread-author',
            actorDisplayName: 'Thread author',
            timestamp: 1724300181,
            message: 'Root of the thread',
            threadId: rootId,
            isThread: true,
          ),
          displayText: 'Root of the thread',
        );
        for (var reply = 1; reply <= replyCount; reply++) {
          await _insertCachedMessage(
            database,
            _messageJson(
              id: rootId + reply,
              actorId: 'thread-author',
              actorDisplayName: 'Thread author',
              timestamp: 1724300181 + reply,
              message: 'Reply $reply',
              threadId: rootId,
            ),
            displayText: 'Reply $reply',
          );
        }

        await tester.pumpWidget(app(home: roomScreen()));
        await tester.pump();
        await tester.ensureVisible(
          find.byKey(const Key('chat-open-thread-$rootId')),
        );
        await tester.tap(find.byKey(const Key('chat-open-thread-$rootId')));
        await tester.pumpAndSettle();

        final divider = find.byKey(const Key('chat-thread-replies-divider'));
        expect(divider, findsOneWidget);
        expect(
          find.descendant(
            of: divider,
            matching: find.text(
              replyCount == 0 ? 'No replies yet' : '2 replies',
            ),
          ),
          findsOneWidget,
        );
        expect(
          tester
              .widget<Text>(find.byKey(const Key('chat-thread-room-$rootId')))
              .data,
          conversation.displayName,
        );
        // The divider closes the root, so it sits below it and above replies.
        final rootBottom = tester
            .getBottomLeft(find.text('Root of the thread'))
            .dy;
        expect(tester.getTopLeft(divider).dy, greaterThan(rootBottom));
        // Same author within seconds, yet the divider splits the group: the
        // root keeps its avatar and the first reply names its author again.
        expect(find.byKey(const Key('chat-avatar-$rootId')), findsOneWidget);
        expect(
          find.text('Thread author'),
          findsNWidgets(replyCount == 0 ? 1 : 2),
        );
        if (replyCount > 0) {
          expect(
            tester.getBottomLeft(divider).dy,
            lessThanOrEqualTo(tester.getTopLeft(find.text('Reply 1')).dy),
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      });
    }

    testWidgets('the thread header and divider fit 200 % text on a narrow '
        'phone in Czech', (tester) async {
      tester.view
        ..physicalSize = const Size(320, 900)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final wire = _messageJson(
        id: 95,
        actorId: 'thread-author',
        actorDisplayName: 'Thread author',
        timestamp: 1724300195,
        message: 'Root of the thread',
        threadId: 95,
        isThread: true,
      );
      await _insertCachedMessage(database, wire, displayText: 'Root');
      final threadContext = ChatThreadContext.fromCachedRoot(
        accountId: account.id,
        roomToken: conversation.token,
        root: _cachedThreadRoot(wire),
      )!;

      await tester.pumpWidget(
        app(
          locale: const Locale('cs'),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: ChatThreadScreen(
              account: account,
              conversation: conversation,
              threadContext: threadContext,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byKey(const Key('chat-thread-replies-divider')),
          matching: find.text('Zatím bez odpovědí'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('chat-thread-room-95')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('a room timeline has no thread divider', (tester) async {
      await _insertCachedMessage(
        database,
        _messageJson(
          id: 91,
          actorId: 'thread-author',
          actorDisplayName: 'Thread author',
          timestamp: 1724300191,
          message: 'Plain message',
          threadId: 91,
          isThread: true,
        ),
        displayText: 'Plain message',
      );
      await tester.pumpWidget(app(home: roomScreen()));
      await tester.pump();
      expect(find.text('Plain message'), findsOneWidget);
      expect(
        find.byKey(const Key('chat-thread-replies-divider')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('the replies chip on a reply opens the thread of its root', (
      tester,
    ) async {
      final root = _messageJson(
        id: 75,
        actorId: 'thread-author',
        actorDisplayName: 'Thread author',
        timestamp: 1724300175,
        message: 'Named thread root',
        threadId: 75,
        isThread: true,
      );
      final reply = _messageJson(
        id: 76,
        actorId: 'thread-author',
        actorDisplayName: 'Thread author',
        timestamp: 1724300176,
        message: 'Reply in the thread',
        threadId: 75,
        isThread: true,
      );
      await _insertCachedMessage(
        database,
        root,
        displayText: 'Named thread root',
      );
      await _insertCachedMessage(
        database,
        reply,
        displayText: 'Reply in the thread',
      );

      await tester.pumpWidget(app(home: roomScreen()));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('chat-open-thread-76')));
      await tester.tap(find.byKey(const Key('chat-open-thread-76')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('chat-thread-screen-75')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('the replies chip fetches a root that is not cached', (
      tester,
    ) async {
      final fixture =
          readFixtureJson(
                'conversation-list/fixtures/conversations-full.response.json',
              )
              as Map;
      final roomJson = Map<String, Object?>.from(
        ((fixture['ocs'] as Map)['data'] as List).first as Map,
      );
      roomJson['token'] = conversation.token;
      final lastMessage = Map<String, Object?>.from(
        roomJson['lastMessage']! as Map,
      );
      lastMessage['id'] = 78;
      roomJson['lastMessage'] = lastMessage;
      await (database.update(
        database.cachedConversations,
      )..where((row) => row.token.equals(conversation.token))).write(
        CachedConversationsCompanion(rawJson: Value(jsonEncode(roomJson))),
      );
      final root = _messageJson(
        id: 77,
        actorId: 'thread-author',
        actorDisplayName: 'Thread author',
        timestamp: 1724300177,
        message: 'Named thread root',
        threadId: 77,
        isThread: true,
      );
      final reply = _messageJson(
        id: 78,
        actorId: 'thread-author',
        actorDisplayName: 'Thread author',
        timestamp: 1724300178,
        message: 'Reply in the thread',
        threadId: 77,
        isThread: true,
      );
      await _insertCachedMessage(
        database,
        reply,
        displayText: 'Reply in the thread',
      );
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(
                capabilitiesJson(
                  talkFeatures: const [
                    'conversation-v4',
                    'chat-v2',
                    'chat-reference-id',
                  ],
                ),
              ),
              200,
            );
          }
          if (request.url.queryParameters['lastKnownMessageId'] != '77') {
            return http.Response('', 304);
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'ocs': <String, Object?>{
                'meta': <String, Object?>{
                  'status': 'ok',
                  'statuscode': 200,
                  'message': 'OK',
                },
                'data': <Object?>[root],
              },
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
              'X-Chat-Last-Given': '77',
              'X-Chat-Last-Common-Read': '0',
            },
          );
        }),
      );
      final service = ChatService(
        accounts: accounts,
        chat: ChatRepository(database),
        credentials: MemoryCredentialVault()
          ..writeAppPassword(account.id, 'fixture-app-password'),
        api: api,
      );
      addTearDown(service.close);
      addTearDown(api.close);

      await tester.pumpWidget(
        app(
          home: roomScreen(),
          overrides: [chatServiceProvider.overrideWithValue(service)],
        ),
      );
      try {
        final chip = find.byKey(const Key('chat-open-thread-78'));
        await _pumpUntil(tester, () => chip.evaluate().isNotEmpty);
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        final screen = find.byKey(const Key('chat-thread-screen-77'));
        await _pumpUntil(tester, () => screen.evaluate().isNotEmpty);
        expect(screen, findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      }
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

      await tester.pumpWidget(
        app(home: roomScreen(), overrides: [threadReplyLayout]),
      );
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

  final stored = await tester.runAsync(
    () => database.select(database.textSendOperations).getSingle(),
  );
  expect(stored?.composerThreadId, testCase.rootId);
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
