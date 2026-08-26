part of 'chat_service_integration_test.dart';

extension _ChatServiceThreadAdmissionCases on _ChatServiceIntegrationSuite {
  void registerThreadAdmissionCases() {
    for (final mutation in _InvalidThreadRootMutation.values) {
      test(
        'thread send rejects ${mutation.description} after capability read starts',
        () async {
          await _cacheThreadRoot(database, isThread: false);
          final gate = _ThreadAdmissionGate();
          addTearDown(gate.api.close);
          final service = ChatService(
            accounts: accounts,
            chat: chat,
            credentials: credentials,
            api: gate.api,
          );

          final expectation = expectLater(
            service.sendText(
              accountId: 'account-a',
              roomToken: 'rooma123',
              message: 'Rejected thread send',
              threadId: 109,
            ),
            throwsA(
              isA<ChatServiceException>().having(
                (error) => error.code,
                'code',
                ChatServiceError.invalidResponse,
              ),
            ),
          );
          await gate.capabilityStarted.future;
          await _applyInvalidThreadRootMutation(database, mutation);
          gate.releaseCapabilities();
          await expectation;

          expect(
            await database.select(database.textSendOperations).get(),
            isEmpty,
          );
          expect(gate.postRequests, 0);
        },
      );
    }

    for (final transition in _ValidThreadRootTransition.values) {
      test(
        'thread send follows ${transition.description} during capability read',
        () async {
          await _cacheThreadRoot(database, isThread: transition.initialNamed);
          final gate = _ThreadAdmissionGate();
          addTearDown(gate.api.close);
          final service = ChatService(
            accounts: accounts,
            chat: chat,
            credentials: credentials,
            api: gate.api,
          );

          final send = service.sendText(
            accountId: 'account-a',
            roomToken: 'rooma123',
            message: 'Reclassified thread send',
            threadId: 109,
          );
          await gate.capabilityStarted.future;
          await _rewriteThreadRoot(
            database,
            isNamed: transition.finalNamed,
            title: transition.finalNamed ? 'Reclassified named thread' : null,
          );
          gate.releaseCapabilities();
          await send;

          final operations = await database
              .select(database.textSendOperations)
              .get();
          expect(operations, hasLength(1));
          expect(gate.postRequests, 1);
          if (transition.finalNamed) {
            expect(gate.sentBody?['threadId'], '109');
            expect(gate.sentBody, isNot(contains('replyTo')));
            expect(operations.single.threadId, 109);
            expect(operations.single.replyTo, isNull);
          } else {
            expect(gate.sentBody?['replyTo'], '109');
            expect(gate.sentBody, isNot(contains('threadId')));
            expect(operations.single.threadId, isNull);
            expect(operations.single.replyTo, 109);
          }
        },
      );
    }
  }
}

enum _InvalidThreadRootMutation {
  deleted('a deleted cached root'),
  system('a cached system-message root'),
  untitledNamed('an untitled named root'),
  mismatchedNamed('a named root with a mismatched thread binding');

  const _InvalidThreadRootMutation(this.description);

  final String description;
}

enum _ValidThreadRootTransition {
  ordinaryToNamed('ordinary-to-named reclassification', false, true),
  namedToOrdinary('named-to-ordinary reclassification', true, false);

  const _ValidThreadRootTransition(
    this.description,
    this.initialNamed,
    this.finalNamed,
  );

  final String description;
  final bool initialNamed;
  final bool finalNamed;
}

Future<void> _applyInvalidThreadRootMutation(
  AppDatabase database,
  _InvalidThreadRootMutation mutation,
) {
  return switch (mutation) {
    _InvalidThreadRootMutation.deleted => _rewriteThreadRoot(
      database,
      isNamed: false,
      deleted: true,
    ),
    _InvalidThreadRootMutation.system => _rewriteThreadRoot(
      database,
      isNamed: false,
      systemMessage: 'message_deleted',
    ),
    _InvalidThreadRootMutation.untitledNamed => _rewriteThreadRoot(
      database,
      isNamed: true,
    ),
    _InvalidThreadRootMutation.mismatchedNamed => _rewriteThreadRoot(
      database,
      isNamed: true,
      title: 'Mismatched named thread',
      rawThreadId: 110,
    ),
  };
}

Future<void> _rewriteThreadRoot(
  AppDatabase database, {
  required bool isNamed,
  String? title,
  bool deleted = false,
  String systemMessage = '',
  int? rawThreadId = 109,
  int? indexedThreadId = 109,
}) async {
  final query = database.select(database.cachedChatMessages)
    ..where(
      (message) =>
          message.accountId.equals('account-a') &
          message.roomToken.equals('rooma123') &
          message.messageId.equals(109),
    );
  final root = await query.getSingle();
  final raw = jsonDecode(root.rawJson) as Map<String, Object?>;
  raw['deleted'] = deleted ? true : null;
  raw['systemMessage'] = systemMessage;
  raw['threadId'] = rawThreadId;
  raw['isThread'] = isNamed;
  raw['threadTitle'] = title;
  await (database.update(database.cachedChatMessages)..where(
        (message) =>
            message.accountId.equals('account-a') &
            message.roomToken.equals('rooma123') &
            message.messageId.equals(109),
      ))
      .write(
        CachedChatMessagesCompanion(
          systemMessage: Value(systemMessage),
          deleted: Value(deleted),
          threadId: Value(indexedThreadId),
          rawJson: Value(jsonEncode(raw)),
        ),
      );
}

final class _ThreadAdmissionGate {
  _ThreadAdmissionGate() {
    api = HttpNextcloudApi(client: MockClient(_handle));
  }

  late final HttpNextcloudApi api;
  final capabilityStarted = Completer<void>();
  final _capabilityResponse = Completer<http.Response>();
  int postRequests = 0;
  Map<String, String>? sentBody;

  void releaseCapabilities() {
    _capabilityResponse.complete(
      http.Response(
        jsonEncode(
          _chatCapabilities(
            talkFeatures: const <String>[
              'conversation-v4',
              'chat-v2',
              'chat-reference-id',
              'chat-replies',
              'threads',
            ],
          ),
        ),
        200,
      ),
    );
  }

  Future<http.Response> _handle(http.Request request) async {
    if (request.url.path.endsWith('/cloud/capabilities')) {
      if (!capabilityStarted.isCompleted) {
        capabilityStarted.complete();
      }
      return _capabilityResponse.future;
    }
    if (request.method == 'GET') {
      return http.Response('', 304);
    }
    postRequests++;
    sentBody = Map<String, String>.of(request.bodyFields);
    final response = request.bodyFields.containsKey('threadId')
        ? _sendResponse(
            referenceId: request.bodyFields['referenceId']!,
            message: request.bodyFields['message']!,
            threadId: 109,
            threadReplies: 1,
          )
        : _sendReplyResponse(
            referenceId: request.bodyFields['referenceId']!,
            message: request.bodyFields['message']!,
            replyTo: 109,
          );
    return http.Response(
      jsonEncode(response),
      201,
      headers: const <String, String>{'X-Chat-Last-Common-Read': '110'},
    );
  }
}
