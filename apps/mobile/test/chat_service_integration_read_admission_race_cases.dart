part of 'chat_service_integration_test.dart';

extension _ReadAdmissionRaceCases on _ChatServiceIntegrationSuite {
  void registerReadAdmissionRaceCases() {
    for (final passive in [false, true]) {
      test(
        'reader loss while capabilities are unknown preserves the ${passive ? 'passive' : 'legacy'} decision',
        () async {
          final started = Completer<void>(), release = Completer<void>();
          var aborted = false;
          var reads = 0;
          final service = _readerService(
            MockClient.streaming((request, _) async {
              if (request.url.path.endsWith('/cloud/capabilities')) {
                started.complete();
                final cancelled = await Future.any<bool>([
                  (request as http.Abortable).abortTrigger!.then((_) => true),
                  release.future.then((_) => false),
                ]);
                if (cancelled) {
                  aborted = true;
                  throw http.RequestAbortedException(request.url);
                }
                return _streamedResponse(
                  jsonEncode(
                    _chatCapabilities(
                      talkFeatures: [
                        'conversation-v4',
                        'chat-v2',
                        'chat-reference-id',
                        if (passive) 'chat-keep-notifications',
                      ],
                    ),
                  ),
                  200,
                );
              }
              reads++;
              expect(
                request.url.queryParameters['markNotificationsAsRead'],
                '0',
              );
              return _streamedResponse('', 304);
            }),
          );
          final reader = service.bindLiveRoom(
            accountId: 'account-a',
            roomToken: 'rooma123',
          );
          addTearDown(reader.close);
          addTearDown(() {
            if (!release.isCompleted) release.complete();
          });
          final pending = service.catchUpRoom(
            accountId: 'account-a',
            roomToken: 'rooma123',
          );
          await started.future.timeout(const Duration(seconds: 2));
          reader.setReaderActive(false);
          await _settle();
          release.complete();
          expect(
            await pending.timeout(const Duration(seconds: 2)),
            passive
                ? ChatSynchronizationResult.converged
                : ChatSynchronizationResult.deferred,
          );
          expect(
            aborted,
            isFalse,
            reason:
                'Capabilities must finish before deciding whether chat GET needs a reader',
          );
          expect(reads, passive ? greaterThan(0) : 0);
          expect(
            (await chat.getRootScope(
              accountId: 'account-a',
              roomToken: 'rooma123',
            ))?.lastSyncError,
            isNull,
          );
        },
      );
    }

    for (final history in [false, true]) {
      test(
        'revoked explicit ${history ? 'history' : 'sync'} ownership normalizes a pending transport failure',
        () async {
          var ownerActive = true;
          var reads = 0;
          final service = _readerService(
            MockClient((request) async {
              if (request.url.path.endsWith('/cloud/capabilities')) {
                ownerActive = false;
                return http.Response('unavailable', 503);
              }
              reads++;
              return http.Response('', 304);
            }),
          );
          if (history) {
            await service.loadOlder(
              accountId: 'account-a',
              roomToken: 'rooma123',
              readerIsActive: () => ownerActive,
            );
          } else {
            expect(
              await service.syncRoom(
                accountId: 'account-a',
                roomToken: 'rooma123',
                readerIsActive: () => ownerActive,
              ),
              ChatSynchronizationResult.deferred,
            );
          }
          expect(reads, 0);
          expect(
            (await chat.getRootScope(
              accountId: 'account-a',
              roomToken: 'rooma123',
            ))?.lastSyncError,
            isNull,
          );
        },
      );
    }

    test(
      'same-epoch relay wake survives cancellation of its legacy baseline',
      () async {
        final server = _RelayFakeServer([110], passive: false);
        final started = Completer<void>(), release = Completer<void>();
        var firstFuture = true;
        var aborted = false;
        final service = _readerService(
          MockClient.streaming((request, body) async {
            if (request.url.queryParameters['lookIntoFuture'] == '1' &&
                firstFuture) {
              firstFuture = false;
              started.complete();
              await (request as http.Abortable).abortTrigger;
              aborted = true;
              await release.future;
              throw http.RequestAbortedException(request.url);
            }
            final buffered = http.Request(request.method, request.url)
              ..bodyBytes = await body.toBytes();
            final response = await server.handle(buffered);
            return http.StreamedResponse(
              Stream.value(response.bodyBytes),
              response.statusCode,
              headers: response.headers,
            );
          }),
        );
        final reader = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        final relay = service.bindRelay(
          accountId: 'account-a',
          roomToken: 'rooma123',
        )..activate(1);
        addTearDown(reader.close);
        addTearDown(relay.close);
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        await started.future.timeout(const Duration(seconds: 2));
        reader.setReaderActive(false);
        await _waitForChatCondition(() => aborted);
        reader.setReaderActive(true);
        release.complete();
        await _waitForChatCondition(() => relay.isTrusted);
        expect(await _messageIds(), [110]);
        expect(server.futureRequests, greaterThan(0));
      },
    );
  }
}
