part of 'chat_room_pane_test.dart';

void _registerDesktopThreadPreviewTests() {
  testWidgets(
    'desktop previews the latest replies under their root while offline',
    (tester) async {
      tester.view
        ..physicalSize = const Size(1000, 1000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<void> insert(
        int id,
        int threadId,
        String text, [
        String token = 'rooma123',
      ]) => _insertCachedMessage(
        database,
        _messageJson(
          id: id,
          actorId: 'author',
          actorDisplayName: 'Author',
          timestamp: 1724300100 + id,
          message: text,
          threadId: threadId,
          isThread: id == threadId,
          threadReplies: id == threadId ? 4 : 0,
        )..['token'] = token,
        displayText: text,
      );
      await insert(71, 71, 'Desktop root');
      for (var id = 72; id <= 75; id++) {
        await insert(id, 71, 'Cached reply $id');
      }
      await insert(76, 70, 'Another thread');
      await database
          .into(database.cachedConversations)
          .insert(conversation.copyWith(token: 'roomb123'));
      await insert(76, 71, 'Another room', 'roomb123');
      await tester.pumpWidget(
        app(home: roomScreen(), overrides: [threadReplyLayout]),
      );
      final toggle = find.byKey(const Key('chat-open-thread-71'));
      final enter = find.byKey(const Key('chat-enter-thread-71'));
      await _pumpUntil(tester, () => toggle.evaluate().isNotEmpty);
      expect(find.text('Cached reply 75'), findsNothing);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await _pumpUntil(
        tester,
        () => find.text('Cached reply 75').evaluate().isNotEmpty,
      );
      expect(find.text('Cached reply 72'), findsNothing);
      expect(find.text('Another thread'), findsNothing);
      expect(find.text('Another room'), findsNothing);
      expect(find.byKey(const Key('chat-thread-screen-71')), findsNothing);
      final latestY = tester.getTopLeft(find.text('Cached reply 75')).dy;
      expect(
        latestY,
        greaterThan(tester.getTopLeft(find.text('Cached reply 73')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Cached reply 73')).dy,
        greaterThan(tester.getBottomLeft(find.text('Desktop root')).dy),
      );
      await _pumpUntil(
        tester,
        () => find
            .descendant(of: enter, matching: find.text('Open thread'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(toggle);
      await tester.pump();
      expect(find.text('Cached reply 75'), findsNothing);
      await tester.tap(toggle);
      await _pumpUntil(tester, () => enter.evaluate().isNotEmpty);
      await tester.ensureVisible(enter);
      await tester.tap(enter);
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('chat-thread-screen-71'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('chat-thread-screen-71')),
          matching: find.byKey(const Key('chat-composer')),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'desktop keeps replies in their chosen chronological layout without duplicating them',
    (tester) async {
      for (final (id, text) in [(71, 'Root'), (72, 'Inline reply')]) {
        await _insertCachedMessage(
          database,
          _messageJson(
            id: id,
            actorId: 'author',
            actorDisplayName: 'Author',
            timestamp: 1724300170 + id,
            message: text,
            threadId: 71,
            isThread: id == 71,
            threadReplies: id == 71 ? 1 : 0,
          ),
          displayText: text,
        );
      }
      await tester.pumpWidget(app(home: roomScreen()));
      final reply = find.text('Inline reply');
      await _pumpUntil(tester, () => reply.evaluate().isNotEmpty);
      final toggle = find.byKey(const Key('chat-open-thread-71'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      final thread = find.byKey(const Key('chat-thread-screen-71'));
      await _pumpUntil(tester, () => thread.evaluate().isNotEmpty);
      expect(find.byKey(const Key('chat-thread-preview-71')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'desktop loads fresh replies into the expanded thread',
    (tester) async {
      final fixture =
          readFixtureJson(
                'conversation-list/fixtures/conversations-full.response.json',
              )!
              as Map;
      final room = Map<String, Object?>.from(
        ((fixture['ocs'] as Map)['data'] as List).first as Map,
      );
      final root = _messageJson(
        id: 38,
        actorId: 'author',
        actorDisplayName: 'Author',
        timestamp: 1724300138,
        message: 'Fresh root',
        threadId: 38,
        isThread: true,
      );
      room['lastMessage'] = {...room['lastMessage']! as Map, ...root};
      room['lastCommonReadMessage'] = 38;
      room['lastReadMessage'] = 38;
      await database
          .update(database.cachedConversations)
          .write(
            CachedConversationsCompanion(rawJson: Value(jsonEncode(room))),
          );
      conversation = await database
          .select(database.cachedConversations)
          .getSingle();
      vault.values[account.id] = 'fixture-app-password';
      await _insertCachedMessage(database, root, displayText: 'Fresh root');
      final fresh = _messageJson(
        id: 40,
        actorId: 'guest',
        actorDisplayName: 'Guest',
        timestamp: 1724300140,
        message: 'Fresh reply',
        threadId: 38,
      );
      final requests = <Uri>[];
      var fetched = false;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          requests.add(request.url);
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(
                capabilitiesJson(
                  talkFeatures: const [
                    'conversation-v4',
                    'chat-v2',
                    'chat-reference-id',
                    'threads',
                    'chat-replies',
                  ],
                ),
              ),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (request.url.queryParameters['threadId'] == '38' &&
              request.url.queryParameters['lookIntoFuture'] == '1' &&
              !fetched) {
            fetched = true;
            return http.Response(
              jsonEncode({
                'ocs': {
                  'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
                  'data': [fresh],
                },
              }),
              200,
              headers: {
                'content-type': 'application/json; charset=utf-8',
                'X-Chat-Last-Given': '40',
                'X-Chat-Last-Common-Read': '0',
              },
            );
          }
          return http.Response(
            '',
            request.url.path.contains('/chat/') ? 304 : 404,
          );
        }),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        app(
          home: roomScreen(),
          overrides: [
            threadReplyLayout,
            nextcloudApiProvider.overrideWithValue(api),
          ],
        ),
      );
      try {
        final toggle = find.byKey(const Key('chat-open-thread-38'));
        await pumpUntilCondition(
          tester,
          () => toggle.evaluate().isNotEmpty,
          reason: 'desktop thread toggle missing',
          timeout: const Duration(seconds: 5),
        );
        expect(fetched, isFalse);
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        final preview = find.byKey(const Key('chat-thread-preview-38'));
        final error = find.descendant(
          of: preview,
          matching: find.text('Try again'),
        );
        await pumpUntilCondition(
          tester,
          () =>
              find.text('Fresh reply').evaluate().isNotEmpty ||
              error.evaluate().isNotEmpty,
          reason: 'scoped sync did not finish',
          timeout: const Duration(seconds: 5),
        );
        expect(fetched, isTrue, reason: requests.join('\n'));
        expect(
          find.text('Fresh reply'),
          findsOneWidget,
          reason: requests.join('\n'),
        );
        expect(find.text('Reply in thread'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await _settleThreadPaneDisposal(tester);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
