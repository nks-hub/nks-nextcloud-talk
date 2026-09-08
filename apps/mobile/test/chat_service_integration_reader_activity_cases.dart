part of 'chat_service_integration_test.dart';

extension _ChatReaderActivityCases on _ChatServiceIntegrationSuite {
  ChatService _readerService(http.Client client, {DateTime Function()? clock}) {
    final api = HttpNextcloudApi(client: client, clock: clock);
    addTearDown(api.close);
    return ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );
  }

  void registerReaderActivityCases() {
    test(
      'reader loss during capability lookup is cancellation, not an error',
      () async {
        final started = Completer<void>();
        var reads = 0;
        await chat.ensureRootScope(
          account: (await accounts.getAccount('account-a'))!,
          conversation: (await chat.getConversation(
            accountId: 'account-a',
            roomToken: 'rooma123',
          ))!,
        );
        final service = _readerService(
          MockClient.streaming((request, _) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              started.complete();
              await (request as http.Abortable).abortTrigger;
              throw http.RequestAbortedException(request.url);
            }
            reads++;
            return _streamedResponse('', 304);
          }),
        );
        final binding = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        addTearDown(binding.close);
        final pending = binding.synchronize();
        await started.future.timeout(const Duration(seconds: 2));
        binding.setReaderActive(false);
        await pending.timeout(const Duration(seconds: 2));
        expect(reads, 0);
        final scope = await chat.getRootScope(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        expect(scope?.lastSyncError, isNull);
        expect(binding.debugActiveCancellationCycleCount, 0);
      },
    );

    test(
      'legacy catch-up stops before another page after reader loss',
      () async {
        late ChatLiveRoomBinding binding;
        var futureReads = 0;
        final service = _readerService(
          MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              return http.Response(jsonEncode(_chatCapabilities()), 200);
            }
            if (request.url.queryParameters['lookIntoFuture'] == '0') {
              return http.Response('', 304);
            }
            futureReads++;
            binding.setReaderActive(false);
            return http.Response(
              jsonEncode(
                _externalMessageResponse(
                  messageId: 120,
                  timestamp: 1770000120,
                  message: 'Incoming message',
                ),
              ),
              200,
              headers: const {
                'X-Chat-Last-Given': '120',
                'X-Chat-Last-Common-Read': '110',
              },
            );
          }),
        );
        binding = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        addTearDown(binding.close);
        await binding.synchronize().timeout(const Duration(seconds: 2));
        expect(futureReads, 1);
        final scope = await chat.getRootScope(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        expect(scope?.lastSyncError, isNull);
      },
    );
    test(
      'legacy reader waits outside the room tail and resumes without loss',
      () async {
        var reads = 0;
        final service = _readerService(
          MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              return http.Response(jsonEncode(_chatCapabilities()), 200);
            }
            reads++;
            expect(request.url.queryParameters['markNotificationsAsRead'], '1');
            return http.Response('', 304);
          }),
        );
        final hidden = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
          readerActive: false,
        );
        final active = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        addTearDown(hidden.close);
        addTearDown(active.close);
        final pending = hidden.synchronize();
        await _waitForChatCondition(() => hidden.debugWaitingForReader);
        expect(reads, 0);
        await active.synchronize().timeout(const Duration(seconds: 2));
        final activeReads = reads;
        expect(activeReads, greaterThan(0));
        hidden.setReaderActive(true);
        await pending.timeout(const Duration(seconds: 2));
        expect(reads, greaterThan(activeReads));
      },
    );

    test(
      'legacy reader revalidates context after waking before dispatch',
      () async {
        const updatedFeatures = [
          'conversation-v4',
          'chat-v2',
          'chat-reference-id',
          'chat-keep-notifications',
        ];
        var now = DateTime.utc(2026, 9, 8);
        var capabilityRequests = 0;
        final readFlags = <String?>[];
        final service = _readerService(
          MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              capabilityRequests++;
              return http.Response(
                jsonEncode(
                  capabilityRequests == 1
                      ? _chatCapabilities()
                      : _chatCapabilities(talkFeatures: updatedFeatures),
                ),
                200,
              );
            }
            readFlags.add(
              request.url.queryParameters['markNotificationsAsRead'],
            );
            return http.Response('', 304);
          }),
          clock: () => now,
        );
        final binding = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        addTearDown(binding.close);
        await binding.synchronize();
        expect(readFlags, isNotEmpty);
        expect(readFlags, everyElement('1'));
        readFlags.clear();
        binding.setReaderActive(false);
        final waiting = binding.synchronize();
        await _waitForChatCondition(() => binding.debugWaitingForReader);
        await accounts.updateTalkFeatures('account-a', updatedFeatures.toSet());
        now = now.add(const Duration(minutes: 6));
        binding.setReaderActive(true);
        await waiting.timeout(const Duration(seconds: 2));
        expect(
          readFlags,
          isEmpty,
          reason: 'The stale prepared context must not dispatch a GET',
        );
        await binding.synchronize().timeout(const Duration(seconds: 2));
        expect(capabilityRequests, 2);
        expect(readFlags, isNotEmpty);
        expect(readFlags, everyElement('0'));
        final scope = await chat.getRootScope(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        expect(scope?.lastSyncError, isNull);
      },
    );

    for (final background in [false, true]) {
      test(
        'reader inactivity ${background ? 'preserves passive' : 'aborts legacy'} poll',
        () async {
          final started = Completer<void>(),
              aborted = Completer<void>(),
              release = Completer<void>();
          var polls = 0;
          final service = _readerService(
            MockClient.streaming((request, _) async {
              if (request.url.path.endsWith('/cloud/capabilities')) {
                return _streamedResponse(
                  jsonEncode(
                    _chatCapabilities(
                      talkFeatures: [
                        'conversation-v4',
                        'chat-v2',
                        'chat-reference-id',
                        if (background) 'chat-keep-notifications',
                      ],
                    ),
                  ),
                  200,
                );
              }
              expect(
                request.url.queryParameters['markNotificationsAsRead'],
                background ? '0' : '1',
              );
              if (request.url.queryParameters['timeout'] != '30' ||
                  ++polls != 1) {
                return _streamedResponse('', 304);
              }
              started.complete();
              final cancelled = await Future.any<bool>([
                (request as http.Abortable).abortTrigger!.then((_) => true),
                release.future.then((_) => false),
              ]);
              if (cancelled) {
                aborted.complete();
                throw http.RequestAbortedException(request.url);
              }
              return _streamedResponse('', 304);
            }),
          );
          final binding = service.bindLiveRoom(
            accountId: 'account-a',
            roomToken: 'rooma123',
          );
          addTearDown(binding.close);
          await binding.synchronize();
          final poll = binding.synchronize();
          await started.future.timeout(const Duration(seconds: 2));
          binding.setReaderActive(false);
          if (background) {
            release.complete();
            await poll.timeout(const Duration(seconds: 2));
            expect(aborted.isCompleted, isFalse);
          } else {
            await poll.timeout(const Duration(seconds: 2));
            await aborted.future.timeout(const Duration(seconds: 2));
            final resumed = binding.synchronize();
            await _waitForChatCondition(() => binding.debugWaitingForReader);
            expect(polls, 1);
            binding.setReaderActive(true);
            await resumed.timeout(const Duration(seconds: 2));
            expect(polls, 2);
          }
          final scope = await chat.getRootScope(
            accountId: 'account-a',
            roomToken: 'rooma123',
          );
          expect(scope?.lastSyncError, isNull);
        },
      );
    }

    test(
      'last active legacy owner aborts a shared poll, not the first',
      () async {
        final started = Completer<void>(), aborted = Completer<void>();
        var polls = 0;
        final service = _readerService(
          MockClient.streaming((request, _) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              return _streamedResponse(jsonEncode(_chatCapabilities()), 200);
            }
            if (request.url.queryParameters['timeout'] != '30') {
              return _streamedResponse('', 304);
            }
            polls++;
            if (!started.isCompleted) started.complete();
            await (request as http.Abortable).abortTrigger;
            if (!aborted.isCompleted) aborted.complete();
            throw http.RequestAbortedException(request.url);
          }),
        );
        final first = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        final second = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        addTearDown(first.close);
        addTearDown(second.close);
        await first.synchronize();
        await second.synchronize();
        final firstPoll = first.synchronize(),
            secondPoll = second.synchronize();
        await started.future.timeout(const Duration(seconds: 2));
        await _waitForChatCondition(
          () => first.debugSharedPollReaderCount == 2,
        );
        first.setReaderActive(false);
        await firstPoll.timeout(const Duration(seconds: 2));
        expect(second.debugSharedPollReaderCount, 1);
        expect(aborted.isCompleted, isFalse);
        second.setReaderActive(false);
        await secondPoll.timeout(const Duration(seconds: 2));
        await aborted.future.timeout(const Duration(seconds: 2));
        expect(polls, 1);
      },
    );

    test(
      'closing a waiting legacy reader settles its pending synchronization',
      () async {
        final service = _readerService(
          MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              return http.Response(jsonEncode(_chatCapabilities()), 200);
            }
            fail('An inactive legacy reader must not fetch chat');
          }),
        );
        final binding = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
          readerActive: false,
        );
        addTearDown(binding.close);
        final pending = binding.synchronize();
        await _waitForChatCondition(() => binding.debugWaitingForReader);
        binding.close();
        await pending.timeout(const Duration(seconds: 2));
        expect(binding.debugActiveCancellationCycleCount, 0);
        expect(binding.debugWaitingForReader, isFalse);
      },
    );
  }
}
