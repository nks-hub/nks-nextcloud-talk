part of 'chat_service_integration_test.dart';

extension _ChatServiceAccountSuspendCases on _ChatServiceIntegrationSuite {
  void registerAccountSuspendCases() {
    test(
      'account suspension drains root and thread polls without touching another account',
      () async {
        await _cacheThreadRoot(database, isThread: true);
        final accountB = await accounts.upsertAccount(
          accountId: 'account-b',
          serverUrl: 'https://cloud-b.example.invalid',
          loginName: 'fixture-user-b',
          serverProductName: 'Nextcloud',
          createdAt: DateTime.utc(2026, 1, 2),
        );
        credentials.values[accountB.id] = 'fixture-password-b';
        final roomB = Map<String, Object?>.from(_conversationRoomJson())
          ..['token'] = 'roomb123';
        roomB['lastMessage'] = Map<String, Object?>.from(
          roomB['lastMessage']! as Map<String, Object?>,
        )..['token'] = 'roomb123';
        await database
            .into(database.cachedConversations)
            .insert(
              CachedConversationsCompanion.insert(
                accountId: accountB.id,
                token: 'roomb123',
                displayName: 'Room B',
                description: '',
                lastActivity: 1,
                unreadMessages: 0,
                favorite: false,
                rawJson: jsonEncode(roomB),
              ),
            );

        final started = <String, Completer<void>>{
          'rooma123:root': Completer<void>(),
          'rooma123:109': Completer<void>(),
          'roomb123:root': Completer<void>(),
        };
        final aborted = <String, Completer<void>>{
          'rooma123:root': Completer<void>(),
          'rooma123:109': Completer<void>(),
          'roomb123:root': Completer<void>(),
        };
        final api = HttpNextcloudApi(
          client: MockClient.streaming((request, _) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              return _streamedResponse(
                jsonEncode(
                  _chatCapabilities(
                    talkFeatures: const <String>[
                      'conversation-v4',
                      'chat-v2',
                      'chat-reference-id',
                      'threads',
                    ],
                  ),
                ),
                200,
              );
            }
            if (request.url.queryParameters['lookIntoFuture'] == '0' ||
                request.url.queryParameters['timeout'] == '0') {
              return _streamedResponse('', 304);
            }
            final thread = request.url.queryParameters['threadId'];
            final room = request.url.pathSegments.last;
            final key = '$room:${thread ?? 'root'}';
            started[key]!.complete();
            final abortTrigger = (request as http.Abortable).abortTrigger!;
            await abortTrigger;
            aborted[key]!.complete();
            throw http.RequestAbortedException(request.url);
          }),
        );
        addTearDown(api.close);
        final service = ChatService(
          accounts: accounts,
          chat: chat,
          credentials: credentials,
          api: api,
        );
        final root = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        final thread = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
          threadId: 109,
        );
        final survivor = service.bindLiveRoom(
          accountId: 'account-b',
          roomToken: 'roomb123',
        );
        addTearDown(survivor.close);

        await root.synchronize();
        await thread.synchronize();
        await survivor.synchronize();
        final polls = <Future<void>>[
          root.synchronize(),
          thread.synchronize(),
          survivor.synchronize(),
        ];
        await Future.wait<void>(<Future<void>>[
          started['rooma123:root']!.future,
          started['rooma123:109']!.future,
          started['roomb123:root']!.future,
        ]).timeout(const Duration(seconds: 2));

        await service.suspendAccount('account-a');

        expect(aborted['rooma123:root']?.isCompleted, isTrue);
        expect(aborted['rooma123:109']?.isCompleted, isTrue);
        expect(aborted['roomb123:root']?.isCompleted, isFalse);
        expect(await accounts.getAccount('account-b'), isNotNull);
        survivor.close();
        await Future.wait<void>(polls);
      },
    );
  }
}
