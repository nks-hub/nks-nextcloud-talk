part of 'chat_service_integration_test.dart';

extension _ChatServicePrivateReplyCases on _ChatServiceIntegrationSuite {
  void registerPrivateReplyCases() {
    test('repository durably admits and restores a private reply', () async {
      final capability = await chat.recordCapabilities(
        accountId: 'account-a',
        talkFeatures: _privateReplyFeatures,
        observedAt: DateTime.utc(2026, 1, 1),
      );
      final authority = _privateReplyAuthority(capability.generation);
      final eligibility = _privateReplyEligibility(capability.generation);

      final operation = await chat.admitTextSend(
        accountId: 'account-a',
        roomToken: _privateReplyTargetToken,
        authority: authority,
        operationId: ChatOperationId.parse(
          'aaaaaaaa-0000-4000-8000-000000000010',
        ),
        referenceId: ChatReferenceId.parse(
          '11111111-1111-4111-8111-111111111110',
        ),
        message: 'Synthetic durable private reply',
        replyTo: _privateReplyParentId,
        replyToToken: _privateReplySourceToken,
        parentRoomToken: _privateReplySourceToken,
        privateReplyEligibility: eligibility,
      );

      expect(operation.replyTo, _privateReplyParentId);
      expect(operation.replyToToken, _privateReplySourceToken);
      expect(operation.parentRoomToken, _privateReplySourceToken);

      final claim = await ChatRepository(database).claimNextTextSend(
        accountId: 'account-a',
        roomToken: _privateReplyTargetToken,
        authority: authority,
        requestId: ChatRequestId.parse('durable-private-reply'),
        now: 1,
      );
      expect(claim, isNotNull);
      expect(claim!.request.formBody, <String, Object>{
        'message': 'Synthetic durable private reply',
        'referenceId': '11111111-1111-4111-8111-111111111110',
        'replyTo': _privateReplyParentId,
        'replyToToken': _privateReplySourceToken.value,
      });
    });

    test(
      'private reply survives reopen and interrupted send is not replayed',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'nctalk-private-reply-',
        );
        final databaseFile = File(
          '${directory.path}${Platform.pathSeparator}chat.sqlite',
        );
        AppDatabase? reopenedDatabase;
        try {
          reopenedDatabase = AppDatabase.forTesting(
            NativeDatabase(databaseFile),
          );
          final reopenedAccounts = AccountRepository(reopenedDatabase);
          await reopenedAccounts.upsertAccount(
            accountId: 'account-a',
            serverUrl: _privateReplyServer.uri.toString(),
            loginName: 'fixture-user',
            serverProductName: 'Nextcloud',
            createdAt: DateTime.utc(2026, 1, 1),
          );
          var reopenedChat = ChatRepository(reopenedDatabase);
          final capability = await reopenedChat.recordCapabilities(
            accountId: 'account-a',
            talkFeatures: _privateReplyFeatures,
            observedAt: DateTime.utc(2026, 1, 1),
          );
          final authority = _privateReplyAuthority(capability.generation);
          final operationId = ChatOperationId.parse(
            'aaaaaaaa-0000-4000-8000-000000000011',
          );
          await reopenedChat.admitTextSend(
            accountId: 'account-a',
            roomToken: _privateReplyTargetToken,
            authority: authority,
            operationId: operationId,
            referenceId: ChatReferenceId.parse(
              '11111111-1111-4111-8111-111111111111',
            ),
            message: 'Synthetic private reply after restart',
            replyTo: _privateReplyParentId,
            replyToToken: _privateReplySourceToken,
            parentRoomToken: _privateReplySourceToken,
            privateReplyEligibility: _privateReplyEligibility(
              capability.generation,
            ),
          );
          await reopenedDatabase.close();

          reopenedDatabase = AppDatabase.forTesting(
            NativeDatabase(databaseFile),
          );
          reopenedChat = ChatRepository(reopenedDatabase);
          final claimed = await reopenedChat.claimNextTextSend(
            accountId: 'account-a',
            roomToken: _privateReplyTargetToken,
            authority: authority,
            requestId: ChatRequestId.parse('private-reply-reopen'),
            now: 1,
          );
          expect(claimed, isNotNull);
          expect(claimed!.request.formBody, <String, Object>{
            'message': 'Synthetic private reply after restart',
            'referenceId': '11111111-1111-4111-8111-111111111111',
            'replyTo': _privateReplyParentId,
            'replyToToken': _privateReplySourceToken.value,
          });
          await reopenedDatabase.close();

          reopenedDatabase = AppDatabase.forTesting(
            NativeDatabase(databaseFile),
          );
          reopenedChat = ChatRepository(reopenedDatabase);
          await reopenedChat.recoverInterruptedTextSends('account-a');
          final recovered = await reopenedChat.loadRuntimeForTesting(
            'account-a',
          );
          expect(
            recovered
                .accounts[_privateReplyAccountId]!
                .operations[operationId]!
                .state,
            TextSendOutboxState.awaitingConfirmation,
          );
          expect(
            await reopenedChat.claimNextTextSend(
              accountId: 'account-a',
              roomToken: _privateReplyTargetToken,
              authority: authority,
              requestId: ChatRequestId.parse('private-reply-no-repost'),
              now: 2,
            ),
            isNull,
          );
        } finally {
          await reopenedDatabase?.close();
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        }
      },
    );

    test('service acquires evidence and sends snapshot-bound wire', () async {
      await _storePrivateReplyTarget(database);

      var evidenceRequests = 0;
      var sendRequests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(
                _chatCapabilities(
                  talkFeatures: _privateReplyFeatures.toList(growable: false),
                ),
              ),
              200,
            );
          }
          if (request.url.path.endsWith('/api/v4/room')) {
            expect(request.method, 'GET');
            expect(request.url.queryParameters['noStatusUpdate'], '1');
            evidenceRequests++;
            return http.Response(
              jsonEncode(_privateReplyConversationsJson()),
              200,
              headers: const {
                'X-Nextcloud-Talk-Hash': 'fixture-hash-a',
                'X-Nextcloud-Talk-Modified-Before': '1724300001',
              },
            );
          }
          if (request.url.path.endsWith('/participants')) {
            expect(request.method, 'GET');
            expect(request.url.queryParameters['includeStatus'], 'false');
            final token =
                request.url.pathSegments[request.url.pathSegments.length - 2];
            expect(
              token,
              anyOf(
                _privateReplySourceToken.value,
                _privateReplyTargetToken.value,
              ),
            );
            evidenceRequests++;
            return http.Response(
              jsonEncode(_privateReplyParticipantsJson()),
              200,
            );
          }
          if (request.url.path.endsWith('/context')) {
            expect(request.method, 'GET');
            expect(request.url.queryParameters['limit'], '0');
            expect(
              request.url.path,
              endsWith(
                '/chat/${_privateReplySourceToken.value}/'
                '$_privateReplyParentId/context',
              ),
            );
            evidenceRequests++;
            return http.Response(
              jsonEncode(_privateReplyParentContextJson()),
              200,
              headers: const {'X-Chat-Last-Given': '77'},
            );
          }
          expect(request.method, 'POST');
          expect(
            request.url.path,
            endsWith('/api/v1/chat/${_privateReplyTargetToken.value}'),
          );
          expect(request.bodyFields['replyTo'], '$_privateReplyParentId');
          expect(
            request.bodyFields['replyToToken'],
            _privateReplySourceToken.value,
          );
          sendRequests++;
          return http.Response(
            jsonEncode(
              _privateReplyResponse(
                referenceId: request.bodyFields['referenceId']!,
                message: request.bodyFields['message']!,
              ),
            ),
            201,
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
      final eligibility = await service.preparePrivateReplyEligibility(
        accountId: 'account-a',
        sourceRoomToken: _privateReplySourceToken.value,
        targetRoomToken: _privateReplyTargetToken.value,
        parentMessageId: _privateReplyParentId,
      );
      await service.sendText(
        accountId: 'account-a',
        roomToken: _privateReplyTargetToken.value,
        message: 'Synthetic service private reply',
        replyTo: _privateReplyParentId,
        replyToToken: _privateReplySourceToken.value,
        privateReplyEligibility: eligibility,
      );

      final operation = await database
          .select(database.textSendOperations)
          .getSingle();
      expect(evidenceRequests, 4);
      expect(sendRequests, 1);
      expect(operation.outboxState, 'completed');
      expect(operation.replyTo, _privateReplyParentId);
      expect(operation.replyToToken, _privateReplySourceToken.value);
      expect(operation.parentRoomToken, _privateReplySourceToken.value);
    });

    test('service rejects a missing request-bound parent', () async {
      await _storePrivateReplyTarget(database);
      var sendRequests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(
                _chatCapabilities(
                  talkFeatures: _privateReplyFeatures.toList(growable: false),
                ),
              ),
              200,
            );
          }
          if (request.url.path.endsWith('/api/v4/room')) {
            return http.Response(
              jsonEncode(_privateReplyConversationsJson()),
              200,
              headers: const {
                'X-Nextcloud-Talk-Hash': 'fixture-hash-a',
                'X-Nextcloud-Talk-Modified-Before': '1724300001',
              },
            );
          }
          if (request.url.path.endsWith('/participants')) {
            return http.Response(
              jsonEncode(_privateReplyParticipantsJson()),
              200,
            );
          }
          if (request.url.path.endsWith('/context')) {
            return http.Response('', 404);
          }
          sendRequests++;
          return http.Response('', 500);
        }),
      );
      addTearDown(api.close);

      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      await expectLater(
        service.preparePrivateReplyEligibility(
          accountId: 'account-a',
          sourceRoomToken: _privateReplySourceToken.value,
          targetRoomToken: _privateReplyTargetToken.value,
          parentMessageId: _privateReplyParentId,
        ),
        throwsA(
          isA<ChatServiceException>().having(
            (error) => error.code,
            'code',
            ChatServiceError.sendUnsupported,
          ),
        ),
      );

      expect(sendRequests, 0);
      expect(await database.select(database.textSendOperations).get(), isEmpty);
    });
  }
}

const Set<String> _privateReplyFeatures = <String>{
  'conversation-v4',
  'chat-v2',
  'chat-reference-id',
  'chat-replies',
  'private-reply',
};
const int _privateReplyParentId = 77;
const String _privateReplySenderId = 'fixture-user-a';
const String _privateReplyParentActorId = 'fixture-user-b';

final AccountId _privateReplyAccountId = AccountId.parse('account-a');
final ServerBase _privateReplyServer = ServerBase.parse(
  'https://cloud.example.invalid',
);
final ConversationToken _privateReplyTargetToken = ConversationToken.parse(
  'rooma123',
  path: r'$.targetRoomToken',
);
final ConversationToken _privateReplySourceToken = ConversationToken.parse(
  'source789',
  path: r'$.sourceRoomToken',
);

ChatTextSendAuthority _privateReplyAuthority(int capabilityGeneration) =>
    ChatTextSendAuthority(
      accountId: _privateReplyAccountId,
      server: _privateReplyServer,
      capabilityGeneration: capabilityGeneration,
      profile: _privateReplyProfile,
      replayContractRevision: textSendReplayContractRevision,
    );

ChatCapabilityProfile get _privateReplyProfile =>
    ChatCapabilityProfile.fromTalkFeatures(
      _privateReplyFeatures.toList(growable: false),
      federated: false,
    );

Future<void> _storePrivateReplyTarget(AppDatabase database) async {
  final targetJson = _privateReplyRoomJson(
    token: _privateReplyTargetToken,
    direct: true,
  );
  await (database.update(database.cachedConversations)..where(
        (row) =>
            row.accountId.equals('account-a') &
            row.token.equals(_privateReplyTargetToken.value),
      ))
      .write(
        CachedConversationsCompanion(
          roomType: const Value(1),
          roomName: Value(targetJson['name']! as String),
          rawJson: Value(jsonEncode(targetJson)),
        ),
      );
}

PrivateReplyEligibilitySnapshot _privateReplyEligibility(
  int capabilityGeneration,
) => PrivateReplyEligibilitySnapshot.fromEvidence(
  accountId: _privateReplyAccountId,
  server: _privateReplyServer,
  capabilityGeneration: capabilityGeneration,
  profile: _privateReplyProfile,
  conversations: _privateReplyConversations(),
  sourceRoomToken: _privateReplySourceToken,
  targetRoomToken: _privateReplyTargetToken,
  parentContext: _privateReplyParentContext(),
  sourceParticipants: _privateReplyParticipants(_privateReplySourceToken),
  targetParticipants: _privateReplyParticipants(_privateReplyTargetToken),
);

ConversationListSuccess _privateReplyConversations() =>
    decodeConversationListResponse(
          request: ConversationListRequest(
            accountId: _privateReplyAccountId,
            requestId: ConversationRequestId.parse(
              'private-reply-conversations',
            ),
            server: _privateReplyServer,
            mode: ConversationFetchMode.full,
            includeLastMessage: true,
          ),
          statusCode: 200,
          json: _privateReplyConversationsJson(),
          headers: const {
            'X-Nextcloud-Talk-Hash': 'fixture-hash-a',
            'X-Nextcloud-Talk-Modified-Before': '1724300001',
          },
        )
        as ConversationListSuccess;

Map<String, Object?> _privateReplyConversationsJson() => <String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': <Object?>[
      _privateReplyRoomJson(token: _privateReplySourceToken),
      _privateReplyRoomJson(token: _privateReplyTargetToken, direct: true),
    ],
  },
};

PrivateReplyParentContextResponse _privateReplyParentContext() {
  final body = _privateReplyParentContextJson();
  return decodePrivateReplyParentContextResponse(
    request: PrivateReplyParentContextRequest(
      accountId: _privateReplyAccountId,
      requestId: ChatRequestId.parse('private-reply-parent-context'),
      server: _privateReplyServer,
      sourceRoomToken: _privateReplySourceToken,
      parentMessageId: _privateReplyParentId,
      profile: _privateReplyProfile,
    ),
    statusCode: 200,
    body: http.Response(jsonEncode(body), 200).bodyBytes,
    headers: ChatResponseHeaders.fromMap(const {'X-Chat-Last-Given': '77'}),
  );
}

Map<String, Object?> _privateReplyParentContextJson() {
  final body =
      jsonDecode(
            jsonEncode(
              readFixtureJson(
                'chat-messages/fixtures/chat-history.response.json',
              ),
            ),
          )!
          as Map<String, Object?>;
  final ocs = body['ocs']! as Map<String, Object?>;
  ocs['data'] = <Object?>[_privateReplyParentMessageJson()];
  return body;
}

Map<String, Object?> _privateReplyRoomJson({
  required ConversationToken token,
  bool direct = false,
}) {
  final room =
      jsonDecode(jsonEncode(_conversationRoomJson()))! as Map<String, Object?>;
  room['token'] = token.value;
  room['actorType'] = 'users';
  room['actorId'] = _privateReplySenderId;
  room['type'] = direct ? 1 : 2;
  room['name'] = direct
      ? jsonEncode(
          <String>[_privateReplySenderId, _privateReplyParentActorId]..sort(),
        )
      : 'Synthetic source room';
  room['attributes'] = 0;
  room.remove('remoteServer');
  final lastMessage = room['lastMessage']! as Map<String, Object?>;
  lastMessage['token'] = token.value;
  return room;
}

Map<String, Object?> _privateReplyParentMessageJson() {
  final root =
      jsonDecode(
            jsonEncode(
              readFixtureJson(
                'chat-messages/fixtures/chat-history.response.json',
              ),
            ),
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as List<Object?>;
  final message = data.first! as Map<String, Object?>;
  message['id'] = _privateReplyParentId;
  message['token'] = _privateReplySourceToken.value;
  message['actorType'] = 'users';
  message['actorId'] = _privateReplyParentActorId;
  message['isReplyable'] = true;
  message.remove('deleted');
  return message;
}

ParticipantsSuccess _privateReplyParticipants(ConversationToken roomToken) =>
    decodeParticipantsResponse(
          request: ParticipantsRequest(
            accountId: _privateReplyAccountId,
            server: _privateReplyServer,
            roomToken: roomToken,
          ),
          statusCode: 200,
          body: http.Response(
            jsonEncode(_privateReplyParticipantsJson()),
            200,
          ).bodyBytes,
        )
        as ParticipantsSuccess;

Map<String, Object?> _privateReplyParticipantsJson() => <String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': <Object?>[
      _privateReplyParticipantJson(_privateReplySenderId, attendeeId: 1),
      _privateReplyParticipantJson(_privateReplyParentActorId, attendeeId: 2),
    ],
  },
};

Map<String, Object?> _privateReplyParticipantJson(
  String actorId, {
  required int attendeeId,
}) => <String, Object?>{
  'attendeeId': attendeeId,
  'actorType': 'users',
  'actorId': actorId,
  'displayName': 'Synthetic user',
  'participantType': 3,
  'lastPing': 0,
  'sessionIds': <String>[],
  'permissions': 254,
  'attendeePermissions': 0,
  'inCall': 0,
};

Map<String, Object?> _privateReplyResponse({
  required String referenceId,
  required String message,
}) {
  final response =
      jsonDecode(
            jsonEncode(
              readFixtureJson(
                'chat-messages/fixtures/send-cross-room-reply-success.response.json',
              ),
            ),
          )!
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  final parent = data['parent']! as Map<String, Object?>;
  final metadata = parent['metaData']! as Map<String, Object?>;
  data['token'] = _privateReplyTargetToken.value;
  data['actorId'] = _privateReplySenderId;
  data['referenceId'] = referenceId;
  data['message'] = message;
  parent['token'] = _privateReplySourceToken.value;
  parent['actorId'] = _privateReplyParentActorId;
  metadata['replyToMessageId'] = _privateReplyParentId;
  metadata['replyToConversationToken'] = _privateReplySourceToken.value;
  return response;
}
