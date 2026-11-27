part of 'chat_service_integration_test.dart';

extension _ChatServiceNonBlockingCases on _ChatServiceIntegrationSuite {
  void registerNonBlockingCases() {
    test('an unanswered send does not hold the next admission', () async {
      final held = Completer<void>();
      addTearDown(() {
        if (!held.isCompleted) held.complete();
      });
      final started = <String>[];
      final answered = <String>[];
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(jsonEncode(_chatCapabilities()), 200);
          }
          if (request.method == 'GET') {
            return http.Response('', 304);
          }
          final message = request.bodyFields['message']!;
          started.add(message);
          if (started.length == 1) {
            await held.future;
          }
          answered.add(message);
          return http.Response(
            jsonEncode(_sentMessage(request, id: 120 + answered.length)),
            201,
            headers: const <String, String>{'X-Chat-Last-Common-Read': '110'},
          );
        }),
      );
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );

      // Both admissions answer while the first request is still open. A send
      // that only returned once its own request had been answered held the
      // composer for the whole round trip, and the next message could not even
      // be queued until the first one had finished.
      await service
          .sendText(
            accountId: 'account-a',
            roomToken: 'rooma123',
            message: 'first in line',
          )
          .timeout(const Duration(seconds: 5));
      await _waitForChatCondition(() => started.isNotEmpty);
      await service
          .sendText(
            accountId: 'account-a',
            roomToken: 'rooma123',
            message: 'second in line',
          )
          .timeout(const Duration(seconds: 5));

      final admitted = await _operationsInOrder();
      expect(admitted.map((row) => row.message), [
        'first in line',
        'second in line',
      ]);
      expect(admitted.map((row) => row.enqueueSequence), [1, 2]);
      // The second message is durable, but it must not be on the wire yet: the
      // first one is unresolved and overtaking it would reorder the room.
      expect(started, ['first in line']);

      held.complete();
      await _waitForChatCondition(() => answered.length == 2);

      expect(started, ['first in line', 'second in line']);
      final settled = await _operationsInOrder();
      expect(settled.map((row) => row.outboxState), ['completed', 'completed']);
      expect(settled.map((row) => row.attemptCount), everyElement(1));
      expect(await chat.roomsWithPendingTextSends(), isEmpty);
    });

    test(
      'a rapid send cannot pass a composer draft whose checkpoint is still writing',
      () async {
        final writes = Completer<void>();
        final sent = <String>[];
        final api = HttpNextcloudApi(
          client: _sendServer((request) {
            sent.add(request.bodyFields['message']!);
            return _acceptedSend(request, 120 + sent.length);
          }),
        );
        addTearDown(api.close);
        final service = ChatService(
          accounts: accounts,
          chat: chat,
          credentials: credentials,
          api: api,
        );
        addTearDown(service.close);
        await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
        final ready = writes.future.then((_) async {
          await database
              .into(database.refusedTextDrafts)
              .insert(
                const RefusedTextDraft(
                  accountId: 'account-a',
                  roomToken: 'rooma123',
                  draftId: 'held',
                  message: 'first',
                  silent: false,
                  createdAtMillis: 1,
                ),
              );
        });
        final first = service.sendText(
          accountId: 'account-a',
          roomToken: 'rooma123',
          message: 'first',
          recoverableDraft: (id: 'held', checkpoint: ready),
        );
        final second = service.sendText(
          accountId: 'account-a',
          roomToken: 'rooma123',
          message: '👍',
        );
        await pumpEventQueue();
        expect(sent, isEmpty);
        writes.complete();
        await Future.wait([first, second]);
        await _waitForChatCondition(() => sent.length == 2);
        expect(sent, ['first', '👍']);
        expect(
          await database.select(database.refusedTextDrafts).get(),
          isEmpty,
        );
      },
    );

    test(
      'retrying a refused reply as plain text preserves the draft without posting',
      () async {
        final api = HttpNextcloudApi(
          client: _sendServer(
            (_) => fail('Mismatched reply reached the server'),
          ),
        );
        addTearDown(api.close);
        final service = ChatService(
          accounts: accounts,
          chat: chat,
          credentials: credentials,
          api: api,
        );
        addTearDown(service.close);
        await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
        const saved = RefusedTextDraft(
          accountId: 'account-a',
          roomToken: 'rooma123',
          draftId: 'answer',
          message: 'saved answer',
          replyTo: 109,
          silent: false,
          createdAtMillis: 1,
        );
        await database.into(database.refusedTextDrafts).insert(saved);
        await expectLater(
          service.sendText(
            accountId: 'account-a',
            roomToken: 'rooma123',
            message: 'saved answer',
            recoverableDraft: (id: 'answer', checkpoint: null),
          ),
          throwsA(isA<Object>()),
        );
        expect(
          await database.select(database.refusedTextDrafts).getSingle(),
          saved,
        );
        expect(
          await database.select(database.textSendOperations).get(),
          isEmpty,
        );
      },
    );

    for (final lostResponse in [false, true]) {
      test('two quick sends settle when the second receipt is '
          '${lostResponse ? 'lost' : 'empty'}', () async {
        final releaseFirst = Completer<void>();
        addTearDown(() {
          if (!releaseFirst.isCompleted) releaseFirst.complete();
        });
        final posts = <String>[];
        final saved = <Map<String, Object?>>[];
        final api = HttpNextcloudApi(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              return http.Response(jsonEncode(_chatCapabilities()), 200);
            }
            if (request.method == 'GET') {
              final anchor = int.parse(
                request.url.queryParameters['lastKnownMessageId']!,
              );
              final newer = saved
                  .where((message) => (message['id']! as int) > anchor)
                  .toList();
              if (newer.isEmpty) return http.Response('', 304);
              return http.Response(
                jsonEncode({
                  'ocs': {
                    'meta': {'status': 'ok', 'statuscode': 200},
                    'data': newer,
                  },
                }),
                200,
                headers: {'X-Chat-Last-Given': '${newer.last['id']}'},
              );
            }
            posts.add(request.bodyFields['message']!);
            if (posts.length == 1) await releaseFirst.future;
            final receipt = _acceptedSend(request, 120 + posts.length);
            final body = jsonDecode(receipt.body) as Map<String, Object?>;
            final ocs = body['ocs']! as Map<String, Object?>;
            saved.add(ocs['data']! as Map<String, Object?>);
            if (posts.length == 1) return receipt;
            if (lostResponse) {
              throw http.ClientException(
                'Receipt lost after save',
                request.url,
              );
            }
            ocs['data'] = null;
            return http.Response(jsonEncode(body), 201);
          }),
        );
        addTearDown(api.close);
        final service = ChatService(
          accounts: accounts,
          chat: chat,
          credentials: credentials,
          api: api,
        );
        addTearDown(service.close);
        final reader = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        addTearDown(reader.close);
        await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');

        Future<String> send(String message) => service.sendText(
          accountId: 'account-a',
          roomToken: 'rooma123',
          message: message,
        );
        await send('first');
        await _waitForChatCondition(() => posts.isNotEmpty);
        await send('second');
        expect(posts, ['first']);
        releaseFirst.complete();

        final settled = await _waitForTextSends(
          database,
          (rows) =>
              rows.length == 2 &&
              rows.every((row) => row.outboxState == 'completed'),
        );
        expect(settled.map((row) => row.messageIdsJson), ['[121]', '[122]']);
        expect(settled.map((row) => row.attemptCount), [1, 1]);
        expect(posts, ['first', 'second']);
      });
    }

    test(
      'a reply admitted behind an unanswered send keeps its parent',
      () async {
        final held = Completer<void>();
        addTearDown(() {
          if (!held.isCompleted) held.complete();
        });
        final bodies = <Map<String, String>>[];
        final answered = <String>[];
        final api = HttpNextcloudApi(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              return http.Response(
                jsonEncode(
                  _chatCapabilities(
                    talkFeatures: const <String>[
                      'conversation-v4',
                      'chat-v2',
                      'chat-reference-id',
                      'chat-replies',
                    ],
                  ),
                ),
                200,
              );
            }
            if (request.method == 'GET') {
              return http.Response('', 304);
            }
            bodies.add(Map<String, String>.from(request.bodyFields));
            if (bodies.length == 1) {
              await held.future;
            }
            answered.add(request.bodyFields['message']!);
            return http.Response(
              jsonEncode(_sentMessage(request, id: 130 + answered.length)),
              201,
              headers: const <String, String>{'X-Chat-Last-Common-Read': '110'},
            );
          }),
        );
        addTearDown(api.close);
        final service = ChatService(
          accounts: accounts,
          chat: chat,
          credentials: credentials,
          api: api,
        );

        await service
            .sendText(
              accountId: 'account-a',
              roomToken: 'rooma123',
              message: 'plain line',
            )
            .timeout(const Duration(seconds: 5));
        await _waitForChatCondition(() => bodies.isNotEmpty);
        await service
            .sendText(
              accountId: 'account-a',
              roomToken: 'rooma123',
              message: 'answering the root',
              replyTo: 109,
            )
            .timeout(const Duration(seconds: 5));

        final admitted = await _operationsInOrder();
        expect(admitted.map((row) => row.replyTo), [isNull, 109]);
        expect(admitted.map((row) => row.parentRoomToken), [
          isNull,
          'rooma123',
        ]);

        held.complete();
        await _waitForChatCondition(() => answered.length == 2);

        // The reply context travels with the row, not with the tap, so waiting
        // behind an unresolved message cannot strip it.
        expect(bodies.map((body) => body['message']), [
          'plain line',
          'answering the root',
        ]);
        expect(bodies.first.containsKey('replyTo'), isFalse);
        expect(bodies.last['replyTo'], '109');
      },
    );

    test(
      'a held send in one room delays neither another room nor another account',
      () async {
        const secondHost = 'second.example.invalid';
        final second = await accounts.upsertAccount(
          accountId: 'account-b',
          serverUrl: 'https://$secondHost',
          loginName: 'fixture-user-b',
          serverProductName: 'Nextcloud',
          createdAt: DateTime.utc(2026, 1, 1),
        );
        credentials.values[second.id] = 'fixture-app-password-never-use';
        await _cacheConversation(database, accountId: second.id);
        await _cacheConversation(
          database,
          accountId: 'account-a',
          token: 'roomb456',
        );

        final held = Completer<void>();
        addTearDown(() {
          if (!held.isCompleted) held.complete();
        });
        final posts = <({String host, String room, String message})>[];
        final answered = <String>[];
        final api = HttpNextcloudApi(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              return http.Response(jsonEncode(_chatCapabilities()), 200);
            }
            if (request.method == 'GET') {
              return http.Response('', 304);
            }
            final room = request.url.path.split('/').last;
            final message = request.bodyFields['message']!;
            posts.add((host: request.url.host, room: room, message: message));
            if (room == 'rooma123' && request.url.host != secondHost) {
              await held.future;
            }
            answered.add(message);
            return http.Response(
              jsonEncode(_sentMessage(request, id: 140 + answered.length)),
              201,
              headers: const <String, String>{'X-Chat-Last-Common-Read': '110'},
            );
          }),
        );
        addTearDown(api.close);
        final service = ChatService(
          accounts: accounts,
          chat: chat,
          credentials: credentials,
          api: api,
        );

        await service
            .sendText(
              accountId: 'account-a',
              roomToken: 'rooma123',
              message: 'held room',
            )
            .timeout(const Duration(seconds: 5));
        await _waitForChatCondition(() => posts.isNotEmpty);
        await service
            .sendText(
              accountId: 'account-a',
              roomToken: 'roomb456',
              message: 'other room',
            )
            .timeout(const Duration(seconds: 5));
        await service
            .sendText(
              accountId: 'account-b',
              roomToken: 'rooma123',
              message: 'other account',
            )
            .timeout(const Duration(seconds: 5));
        await _waitForChatCondition(() => answered.length == 2);

        // The other room and the other account are delivered while the first
        // room still waits for its answer, and every row stays where it was
        // typed.
        expect(answered, unorderedEquals(['other room', 'other account']));
        final rows = await _operationsInOrder();
        expect(
          {
            for (final row in rows)
              row.message: (account: row.accountId, room: row.roomToken),
          },
          {
            'held room': (account: 'account-a', room: 'rooma123'),
            'other room': (account: 'account-a', room: 'roomb456'),
            'other account': (account: 'account-b', room: 'rooma123'),
          },
        );
        expect(
          posts.map((post) => (post.host, post.room)),
          containsAll(<Object>[
            ('cloud.example.invalid', 'roomb456'),
            (secondHost, 'rooma123'),
          ]),
        );

        held.complete();
        await _waitForChatCondition(() => answered.length == 3);
        expect(await chat.roomsWithPendingTextSends(), isEmpty);
      },
    );

    test(
      'a drain does not re-send an operation that is still on the wire',
      () async {
        final held = Completer<void>();
        addTearDown(() {
          if (!held.isCompleted) held.complete();
        });
        final posts = <String>[];
        final answered = <String>[];
        final api = HttpNextcloudApi(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              return http.Response(jsonEncode(_chatCapabilities()), 200);
            }
            if (request.method == 'GET') {
              return http.Response('', 304);
            }
            posts.add(request.bodyFields['message']!);
            await held.future;
            answered.add(request.bodyFields['message']!);
            return http.Response(
              jsonEncode(_sentMessage(request, id: 150)),
              201,
              headers: const <String, String>{'X-Chat-Last-Common-Read': '110'},
            );
          }),
        );
        addTearDown(api.close);
        final service = ChatService(
          accounts: accounts,
          chat: chat,
          credentials: credentials,
          api: api,
        );
        await service
            .sendText(
              accountId: 'account-a',
              roomToken: 'rooma123',
              message: 'uncertain line',
            )
            .timeout(const Duration(seconds: 5));
        await _waitForChatCondition(() => posts.isNotEmpty);

        // A network hint arriving while the request is unresolved must not turn
        // one message into two: a claimed row is nobody else's to take.
        final drainPosts = <String>[];
        final drainApi = HttpNextcloudApi(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              return http.Response(jsonEncode(_chatCapabilities()), 200);
            }
            if (request.method == 'GET') {
              return http.Response('', 304);
            }
            drainPosts.add(request.bodyFields['message']!);
            return http.Response(
              jsonEncode(_sentMessage(request, id: 151)),
              201,
              headers: const <String, String>{'X-Chat-Last-Common-Read': '110'},
            );
          }),
        );
        addTearDown(drainApi.close);
        await ChatService(
          accounts: AccountRepository(database),
          chat: ChatRepository(database),
          credentials: credentials,
          api: drainApi,
        ).drainPendingSends().timeout(const Duration(seconds: 10));

        expect(drainPosts, isEmpty);
        expect(posts, ['uncertain line']);

        held.complete();
        await _waitForChatCondition(() => answered.isNotEmpty);
        final rows = await _operationsInOrder();
        expect(rows, hasLength(1));
        expect(rows.single.outboxState, isNot('sending'));
        expect(posts, ['uncertain line']);
      },
    );
  }

  Future<List<StoredTextSendOperation>> _operationsInOrder() {
    return (database.select(database.textSendOperations)..orderBy([
          (row) => OrderingTerm.asc(row.enqueueSequence),
          (row) => OrderingTerm.asc(row.createdAtMillis),
        ]))
        .get();
  }
}

Map<String, Object?> _sentMessage(http.Request request, {required int id}) {
  final response = _sendResponse(
    referenceId: request.bodyFields['referenceId']!,
    message: request.bodyFields['message']!,
  );
  final data =
      (response['ocs']! as Map<String, Object?>)['data']!
          as Map<String, Object?>;
  data['id'] = id;
  data['threadId'] = id;
  return response;
}
