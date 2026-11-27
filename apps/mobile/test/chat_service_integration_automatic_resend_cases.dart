part of 'chat_service_integration_test.dart';

/// A grace period short enough to wait out. The contract's own is thirty
/// seconds; the rule under test is the same at any length.
const int _testGraceSeconds = 1;

/// A server that lets a room be read while nobody has it open, which is what
/// a check made by a timer or a wake needs. One without
/// `chat-keep-notifications` is only read for an open room.
const Set<String> _backgroundReadFeatures = <String>{
  ..._sendFeatures,
  'chat-keep-notifications',
};

extension _ChatServiceAutomaticResendCases on _ChatServiceIntegrationSuite {
  ChatService _resendingService(HttpNextcloudApi api) {
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
      absenceGraceSeconds: _testGraceSeconds,
    );
    addTearDown(service.close);
    return service;
  }

  void registerAutomaticResendCases() {
    test('a send lost after its body left goes out once more by itself, and '
        'the next message follows it', () async {
      final sent = <({String message, String referenceId})>[];
      final api = HttpNextcloudApi(
        client: _sendServer((request) {
          sent.add((
            message: request.bodyFields['message']!,
            referenceId: request.bodyFields['referenceId']!,
          ));
          if (sent.length == 1) {
            throw http.ClientException('Synthetic reset', request.url);
          }
          return _acceptedSend(request, 119 + sent.length);
        }, features: _backgroundReadFeatures),
      );
      addTearDown(api.close);
      final service = _resendingService(api);
      await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');

      await service.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'lost on the way back',
      );
      final lost = await _waitForTextSends(
        database,
        (rows) => rows.single.outboxState == 'awaitingConfirmation',
      );
      expect(lost.single.nextAttemptAt, isNotNull);
      await service.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'written right after',
      );

      // A wake inside the grace period reads the room and proves nothing.
      await service.drainPendingSends();
      expect(sent, hasLength(1));
      expect(
        (await database.select(database.textSendOperations).get()).map(
          (row) => row.outboxState,
        ),
        ['awaitingConfirmation', 'queued'],
      );

      // Nothing else touches the room: only the service's timer can.
      final rows = await _waitForTextSendsWithin(
        database,
        const Duration(seconds: 8),
        (rows) => rows.every((row) => row.outboxState == 'completed'),
      );

      expect(sent.map((request) => request.message), [
        'lost on the way back',
        'lost on the way back',
        'written right after',
      ]);
      expect(
        sent[1].referenceId,
        sent[0].referenceId,
        reason: 'a late first copy has to stay recognisable',
      );
      expect(rows.map((row) => row.attemptCount), [2, 1]);
      expect(rows.map((row) => row.automaticResendCount), [1, 0]);
      expect(rows.map((row) => row.messageIdsJson), ['[121]', '[122]']);
    });

    test('a copy the server did store completes the send instead', () async {
      String? storedReference;
      var posts = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(
                _chatCapabilities(
                  talkFeatures: _backgroundReadFeatures.toList(),
                ),
              ),
              200,
            );
          }
          if (request.method == 'POST') {
            posts++;
            storedReference = request.bodyFields['referenceId'];
            throw http.ClientException('Answer lost', request.url);
          }
          final known = int.parse(
            request.url.queryParameters['lastKnownMessageId']!,
          );
          if (storedReference == null || known >= 121) {
            return http.Response('', 304);
          }
          return http.Response(
            jsonEncode(
              _externalMessageResponse(
                messageId: 121,
                timestamp: 1770000121,
                message: 'stored after all',
                threadId: 121,
                referenceId: storedReference,
              ),
            ),
            200,
            headers: const <String, String>{
              'X-Chat-Last-Given': '121',
              'X-Chat-Last-Common-Read': '110',
            },
          );
        }),
      );
      addTearDown(api.close);
      final service = _resendingService(api);
      await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');

      await service.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'stored after all',
      );
      final rows = await _waitForTextSendsWithin(
        database,
        const Duration(seconds: 8),
        (rows) => rows.single.outboxState == 'completed',
      );

      expect(posts, 1);
      expect(rows.single.messageIdsJson, '[121]');
      expect(rows.single.automaticResendCount, 0);
    });

    test('the state flips only on a read begun after the grace period and '
        'only while no copy is cached', () async {
      final api = HttpNextcloudApi(
        client: _sendServer(
          (request) => throw http.ClientException('Reset', request.url),
          features: _backgroundReadFeatures,
        ),
      );
      addTearDown(api.close);
      final service = _resendingService(api);
      await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
      await service.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'checked by hand',
      );
      final lost = (await _waitForTextSends(
        database,
        (rows) => rows.single.outboxState == 'awaitingConfirmation',
      )).single;
      // The timer goes with the service; the repository is asked directly.
      await service.close();

      final verifiableAt = lost.nextAttemptAt!;
      final capability = await database
          .select(database.chatCapabilities)
          .getSingle();
      Future<bool> resend({required int readStartedAt, int? now}) =>
          chat.resendVerifiedAbsentTextSend(
            accountId: 'account-a',
            roomToken: ConversationToken.parse(
              'rooma123',
              path: r'$.roomToken',
            ),
            threadId: null,
            authority: ChatTextSendAuthority(
              accountId: AccountId.parse('account-a'),
              server: ServerBase.parse('https://cloud.example.invalid'),
              capabilityGeneration: capability.generation,
              profile: ChatCapabilityProfile.fromTalkFeatures(
                _backgroundReadFeatures.toList(),
                federated: false,
              ),
              replayContractRevision: textSendReplayContractRevision,
            ),
            readStartedAt: readStartedAt,
            now: now ?? readStartedAt,
          );
      Future<StoredTextSendOperation> row() =>
          database.select(database.textSendOperations).getSingle();

      expect(await resend(readStartedAt: verifiableAt), isFalse);
      expect(
        await resend(readStartedAt: verifiableAt + 5, now: verifiableAt + 2),
        isFalse,
        reason: 'the clock ran backwards during the read',
      );
      expect((await row()).outboxState, 'awaitingConfirmation');

      // The reference is in the cache, filed where this send never posted.
      await _cacheOwnCopy(database, lost.referenceId, threadId: 500);
      expect(await resend(readStartedAt: verifiableAt + 1), isFalse);
      expect((await row()).outboxState, 'awaitingConfirmation');

      await database.delete(database.cachedChatMessages).go();
      expect(await resend(readStartedAt: verifiableAt + 1), isTrue);
      final queued = await row();
      expect(queued.outboxState, 'queued');
      expect(queued.errorClass, 'verified-absent');
      expect(queued.automaticResendCount, 1);
      expect(queued.referenceId, lost.referenceId);
      expect(queued.nextAttemptAt, isNull);
    });

    test('a cached copy of the send completes it in the same step', () async {
      final api = HttpNextcloudApi(
        client: _sendServer(
          (request) => throw http.ClientException('Reset', request.url),
          features: _backgroundReadFeatures,
        ),
      );
      addTearDown(api.close);
      final service = _resendingService(api);
      await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
      await service.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'already here',
      );
      final lost = (await _waitForTextSends(
        database,
        (rows) => rows.single.outboxState == 'awaitingConfirmation',
      )).single;
      await service.close();
      await _cacheOwnCopy(database, lost.referenceId, threadId: 130);
      final capability = await database
          .select(database.chatCapabilities)
          .getSingle();

      final queued = await chat.resendVerifiedAbsentTextSend(
        accountId: 'account-a',
        roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
        threadId: null,
        authority: ChatTextSendAuthority(
          accountId: AccountId.parse('account-a'),
          server: ServerBase.parse('https://cloud.example.invalid'),
          capabilityGeneration: capability.generation,
          profile: ChatCapabilityProfile.fromTalkFeatures(
            _backgroundReadFeatures.toList(),
            federated: false,
          ),
          replayContractRevision: textSendReplayContractRevision,
        ),
        readStartedAt: lost.nextAttemptAt! + 1,
        now: lost.nextAttemptAt! + 1,
      );

      expect(queued, isFalse);
      final row = await database
          .select(database.textSendOperations)
          .getSingle();
      expect(row.outboxState, 'completed');
      expect(row.messageIdsJson, '[130]');
      expect(row.automaticResendCount, 0);
    });

    test('three automatic resends are the last ones', () async {
      var posts = 0;
      final api = HttpNextcloudApi(
        client: _sendServer((request) {
          posts++;
          throw http.ClientException('Synthetic reset', request.url);
        }, features: _backgroundReadFeatures),
      );
      addTearDown(api.close);
      final service = _resendingService(api);
      await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');

      await service.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'never answered',
      );
      final rows = await _waitForTextSendsWithin(
        database,
        const Duration(seconds: 20),
        (rows) =>
            rows.single.automaticResendCount ==
                textSendMaximumAutomaticResends &&
            rows.single.outboxState == 'awaitingConfirmation',
      );
      expect(posts, 1 + textSendMaximumAutomaticResends);
      expect(rows.single.attemptCount, 1 + textSendMaximumAutomaticResends);

      // Left to the sender from here on, as every ambiguous send used to be.
      expect(await chat.roomsWithPendingTextSends(), isEmpty);
      await Future<void>.delayed(
        const Duration(seconds: 2 * _testGraceSeconds + 2),
      );
      await service.drainPendingSends();
      expect(posts, 1 + textSendMaximumAutomaticResends);
    });

    test('a wake after the grace period checks a send left by an earlier '
        'process', () async {
      var posts = 0;
      final api = HttpNextcloudApi(
        client: _sendServer((request) {
          posts++;
          if (posts == 1) {
            throw http.ClientException('Synthetic reset', request.url);
          }
          return _acceptedSend(request, 121);
        }, features: _backgroundReadFeatures),
      );
      addTearDown(api.close);
      final first = _resendingService(api);
      await first.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
      await first.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'survives the restart',
      );
      await _waitForTextSends(
        database,
        (rows) => rows.single.outboxState == 'awaitingConfirmation',
      );
      await first.close();
      await Future<void>.delayed(
        const Duration(seconds: _testGraceSeconds + 2),
      );
      expect(posts, 1, reason: 'a closed service checks nothing');

      // What a resume or a returning network does.
      await _resendingService(api).drainPendingSends();
      final rows = await _waitForTextSends(
        database,
        (rows) => rows.single.outboxState == 'completed',
      );
      expect(posts, 2);
      expect(rows.single.automaticResendCount, 1);
    });

    test('a suspended account loses its pending check', () async {
      var posts = 0;
      final api = HttpNextcloudApi(
        client: _sendServer((request) {
          posts++;
          throw http.ClientException('Synthetic reset', request.url);
        }, features: _backgroundReadFeatures),
      );
      addTearDown(api.close);
      final service = _resendingService(api);
      await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
      await service.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'signed out meanwhile',
      );
      await _waitForTextSends(
        database,
        (rows) => rows.single.outboxState == 'awaitingConfirmation',
      );

      await service.suspendAccount('account-a');
      await Future<void>.delayed(
        const Duration(seconds: _testGraceSeconds + 2),
      );

      expect(posts, 1);
      final row = await database
          .select(database.textSendOperations)
          .getSingle();
      expect(row.outboxState, 'awaitingConfirmation');
    });

    test('with a trusted relay the check makes its own HTTP read', () async {
      final requests = <String>[];
      var posts = 0;
      final api = HttpNextcloudApi(
        client: _sendServer(
          (request) {
            posts++;
            if (posts == 1) {
              throw http.ClientException('Synthetic reset', request.url);
            }
            return _acceptedSend(request, 121);
          },
          requests: requests,
          features: _backgroundReadFeatures,
        ),
      );
      addTearDown(api.close);
      final service = _resendingService(api);
      final relay = service.bindRelay(
        accountId: 'account-a',
        roomToken: 'rooma123',
      )..activate(1);
      await _waitForChatCondition(() => relay.isTrusted);
      requests.clear();

      await service.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'over the relay',
      );
      await _waitForTextSends(
        database,
        (rows) => rows.single.outboxState == 'awaitingConfirmation',
      );
      await _waitForChatCondition(() => requests.contains('GET'));
      expect(requests.where((kind) => kind != 'capabilities'), ['POST', 'GET']);
      expect(posts, 1, reason: 'the first read can only confirm a saved copy');

      await _waitForTextSendsWithin(
        database,
        const Duration(seconds: 8),
        (rows) => rows.single.outboxState == 'completed',
      );
      expect(relay.isTrusted, isTrue);
      expect(requests.where((kind) => kind != 'capabilities').take(4), [
        'POST',
        'GET',
        'GET',
        'POST',
      ]);
    });
  }
}

Future<List<StoredTextSendOperation>> _waitForTextSendsWithin(
  AppDatabase database,
  Duration limit,
  bool Function(List<StoredTextSendOperation> rows) condition,
) async {
  final waited = Stopwatch()..start();
  while (waited.elapsed < limit) {
    final rows = await database.select(database.textSendOperations).get();
    if (rows.isNotEmpty && condition(rows)) return rows;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('The outbox did not reach the expected state within $limit');
}

/// Caches a message of the user's own that carries [referenceId], as a chat
/// read would have left it. It confirms a plain send only when it is its own
/// thread root, so [threadId] 130 does and any other does not.
Future<void> _cacheOwnCopy(
  AppDatabase database,
  String referenceId, {
  required int threadId,
}) async {
  final rawJson = <String, Object?>{
    'id': 130,
    'token': 'rooma123',
    'actorType': 'users',
    'actorId': 'fixture-user',
    'actorDisplayName': 'Fixture User',
    'timestamp': 1770000130,
    'systemMessage': '',
    'messageType': 'comment',
    'isReplyable': true,
    'referenceId': referenceId,
    'message': 'A copy of the send',
    'messageParameters': <String, Object?>{},
    'markdown': true,
    'reactions': <String, Object?>{},
    'threadId': threadId,
  };
  await database
      .into(database.cachedChatMessages)
      .insertOnConflictUpdate(
        CachedChatMessagesCompanion.insert(
          accountId: 'account-a',
          roomToken: 'rooma123',
          messageId: 130,
          actorType: 'users',
          actorId: 'fixture-user',
          actorDisplayName: 'Fixture User',
          timestamp: 1770000130,
          systemMessage: '',
          messageType: 'comment',
          referenceId: referenceId,
          displayText: 'A copy of the send',
          deleted: false,
          threadId: Value(threadId),
          rawJson: jsonEncode(rawJson),
        ),
      );
}
