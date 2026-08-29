import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('private reply eligibility', () {
    test('context request and response bind the exact parent endpoint', () {
      final request = _contextRequest();
      expect(
        request.uri.path,
        '/ocs/v2.php/apps/spreed/api/v1/chat/source789/77/context',
      );
      expect(request.queryParameters, {'format': 'json', 'limit': '0'});

      final response = _parentContext();
      expect(
        response.classification,
        PrivateReplyParentContextClassification.found,
      );
      expect(response.request, same(response.request));
      expect(response.parent!.messageId, _parentMessageId);
      expect(response.parent!.roomToken, _sourceToken);
    });

    test('context response rejects a mismatched or ambiguous parent', () {
      expect(
        () => _parentContext(messageId: _parentMessageId + 1),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidChatResponse,
          ),
        ),
      );
      expect(
        () => _parentContext(extraParent: _parentMessage()),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidChatResponse,
          ),
        ),
      );
    });

    test('accepts the one-to-one room name the real server reports', () {
      // Measured on Nextcloud 34: `GET /room` reports a one-to-one room's
      // `name` as the other participant's user id, not the sorted JSON array
      // Talk stores internally. Requiring only the stored form meant every
      // eligibility failed against a live server.
      expect(
        () => _eligibility(
          conversations: _conversations(
            targetRoom: _roomJson(
              token: _targetToken,
              type: 1,
              name: _parentActorId,
            ),
          ),
        ),
        returnsNormally,
      );
    });

    test('still rejects a one-to-one room naming somebody else', () {
      expect(
        () => _eligibility(
          conversations: _conversations(
            targetRoom: _roomJson(
              token: _targetToken,
              type: 1,
              name: 'unrelated-user',
            ),
          ),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('admits, claims and restores the exact cross-room wire binding', () {
      final eligibility = _eligibility();
      var runtime = _runtime();

      final admitted = admitTextSendOperation(
        runtime,
        accountId: _accountId,
        authority: _authority(),
        draft: _draft(eligibility: eligibility),
      );

      expect(admitted.outcome, ChatOutboxOutcome.queued);
      runtime = admitted.plan!.commit(runtime);
      final operation = runtime.accounts[_accountId]!.operations[_operationId]!;
      expect(operation.replyTo, _parentMessageId);
      expect(operation.parentRoomToken, _sourceToken);
      expect(operation.replyToToken, _sourceToken);

      final claimed = claimTextSendOperation(
        runtime,
        accountId: _accountId,
        authority: _authority(),
        operationId: _operationId,
        now: 1,
      );
      expect(claimed.outcome, ChatOutboxOutcome.sending);

      final restored = ChatSendRequest.restored(
        accountId: _accountId,
        requestId: ChatRequestId.parse('private-reply-replay'),
        server: _server,
        roomToken: operation.roomToken,
        operationId: operation.operationId,
        profile: _profile(),
        message: operation.message,
        referenceId: operation.referenceId,
        replyTo: operation.replyTo,
        parentRoomToken: operation.parentRoomToken,
        replyToToken: operation.replyToToken,
      );
      expect(restored.formBody, <String, Object>{
        'message': _message,
        'referenceId': _referenceId.value,
        'replyTo': _parentMessageId,
        'replyToToken': _sourceToken.value,
      });
    });

    test('rejects unsupported or request-unbound evidence', () {
      final cases = <String, PrivateReplyEligibilitySnapshot Function()>{
        'missing capability': () =>
            _eligibility(profile: _profile(privateReply: false)),
        'federated profile': () =>
            _eligibility(profile: _profile(federated: true)),
        'federated source': () => _eligibility(
          conversations: _conversations(
            sourceRoom: _roomJson(
              token: _sourceToken,
              remoteServer: 'remote.example.invalid',
            ),
          ),
        ),
        'classified source': () => _eligibility(
          conversations: _conversations(
            sourceRoom: _roomJson(token: _sourceToken, attributes: 4),
          ),
        ),
        'same source and target': () => _eligibility(
          targetRoomToken: _sourceToken,
          conversations: _conversations(includeTarget: false),
          targetParticipants: _participantsEvidence(roomToken: _sourceToken),
        ),
        'missing source room': () =>
            _eligibility(conversations: _conversations(includeSource: false)),
        'missing target room': () =>
            _eligibility(conversations: _conversations(includeTarget: false)),
        'non-direct target': () => _eligibility(
          conversations: _conversations(
            targetRoom: _roomJson(token: _targetToken, type: 2),
          ),
        ),
        'conversation account mismatch': () => _eligibility(
          conversations: _conversations(
            requestAccountId: AccountId.parse('account-b'),
          ),
        ),
        'conversation server mismatch': () => _eligibility(
          conversations: _conversations(
            requestServer: ServerBase.parse('https://other.example.invalid'),
          ),
        ),
        'incremental conversation snapshot': () => _eligibility(
          conversations: _conversations(
            requestMode: ConversationFetchMode.incremental,
          ),
        ),
        'missing parent': () =>
            _eligibility(parentContext: _parentContextFailure(404)),
        'parent request account mismatch': () => _eligibility(
          parentContext: _parentContext(
            requestAccountId: AccountId.parse('account-b'),
          ),
        ),
        'parent request server mismatch': () => _eligibility(
          parentContext: _parentContext(
            requestServer: ServerBase.parse('https://other.example.invalid'),
          ),
        ),
        'parent request room mismatch': () => _eligibility(
          parentContext: _parentContext(sourceRoomToken: _otherSourceToken),
        ),
        'deleted parent': () =>
            _eligibility(parentContext: _parentContext(deleted: true)),
        'non-replyable parent': () =>
            _eligibility(parentContext: _parentContext(isReplyable: false)),
        'guest parent': () =>
            _eligibility(parentContext: _parentContext(actorType: 'guests')),
        'own parent': () => _eligibility(
          parentContext: _parentContext(actorId: _senderActorId),
        ),
        'source actor mismatch': () => _eligibility(
          conversations: _conversations(
            sourceRoom: _roomJson(token: _sourceToken, actorId: 'other-user'),
          ),
        ),
        'non-canonical direct name': () => _eligibility(
          conversations: _conversations(
            targetRoom: _roomJson(
              token: _targetToken,
              type: 1,
              name: 'not-json',
            ),
          ),
        ),
        'source participants account mismatch': () => _eligibility(
          sourceParticipants: _participantsEvidence(
            roomToken: _sourceToken,
            requestAccountId: AccountId.parse('account-b'),
          ),
        ),
        'target participants server mismatch': () => _eligibility(
          targetParticipants: _participantsEvidence(
            roomToken: _targetToken,
            requestServer: ServerBase.parse('https://other.example.invalid'),
          ),
        ),
        'participants room mismatch': () => _eligibility(
          sourceParticipants: _participantsEvidence(
            roomToken: _otherSourceToken,
          ),
        ),
        'missing source member': () => _eligibility(
          sourceParticipants: _participantsEvidence(
            roomToken: _sourceToken,
            includeParent: false,
          ),
        ),
        'missing target member': () => _eligibility(
          targetParticipants: _participantsEvidence(
            roomToken: _targetToken,
            includeSender: false,
          ),
        ),
        'duplicate participant': () => _eligibility(
          targetParticipants: _participantsEvidence(
            roomToken: _targetToken,
            extraParticipants: [
              _participantJson(_senderActorId, attendeeId: 3),
            ],
          ),
        ),
      };

      for (final entry in cases.entries) {
        expect(
          entry.value,
          throwsA(
            isA<TalkProtocolException>().having(
              (error) => error.code,
              entry.key,
              TalkProtocolErrorCode.unsupportedChatOperation,
            ),
          ),
          reason: entry.key,
        );
      }
    });

    test('admission rejects absent and authority-mismatched snapshots', () {
      final mismatched = <PrivateReplyEligibilitySnapshot?>[
        null,
        _eligibility(accountId: AccountId.parse('account-b')),
        _eligibility(server: ServerBase.parse('https://other.example.invalid')),
        _eligibility(capabilityGeneration: 2),
        _eligibility(sourceRoomToken: _otherSourceToken),
        _eligibility(targetRoomToken: _otherTargetToken),
        _eligibility(parentContext: _parentContext(parentMessageId: 78)),
      ];

      for (final eligibility in mismatched) {
        final result = admitTextSendOperation(
          _runtime(),
          accountId: _accountId,
          authority: _authority(),
          draft: _draft(eligibility: eligibility),
        );
        expect(result.outcome, ChatOutboxOutcome.rejected);
        expect(result.plan, isNull);
      }

      final capabilityLoss = admitTextSendOperation(
        _runtime(),
        accountId: _accountId,
        authority: _authority(profile: _profile(privateReply: false)),
        draft: _draft(eligibility: _eligibility()),
      );
      expect(capabilityLoss.outcome, ChatOutboxOutcome.rejected);
    });
  });
}

const int _parentMessageId = 77;
const String _senderActorId = 'fixture-user-a';
const String _parentActorId = 'fixture-user-b';
const String _message = 'Synthetic private reply';

final AccountId _accountId = AccountId.parse('account-a');
final ServerBase _server = ServerBase.parse('https://cloud.example.invalid');
final ConversationToken _sourceToken = ConversationToken.parse(
  'source789',
  path: r'$.sourceRoomToken',
);
final ConversationToken _otherSourceToken = ConversationToken.parse(
  'source987',
  path: r'$.sourceRoomToken',
);
final ConversationToken _targetToken = ConversationToken.parse(
  'direct123',
  path: r'$.targetRoomToken',
);
final ConversationToken _otherTargetToken = ConversationToken.parse(
  'direct987',
  path: r'$.targetRoomToken',
);
final ChatOperationId _operationId = ChatOperationId.parse(
  'aaaaaaaa-0000-4000-8000-000000000001',
);
final ChatReferenceId _referenceId = ChatReferenceId.parse(
  '11111111-1111-4111-8111-111111111111',
);

ChatCapabilityProfile _profile({
  bool privateReply = true,
  bool federated = false,
}) => ChatCapabilityProfile.fromTalkFeatures(<Object?>[
  'chat-v2',
  'chat-reference-id',
  'chat-replies',
  if (privateReply) 'private-reply',
], federated: federated);

ChatTextSendAuthority _authority({ChatCapabilityProfile? profile}) =>
    ChatTextSendAuthority(
      accountId: _accountId,
      server: _server,
      capabilityGeneration: 1,
      profile: profile ?? _profile(),
      replayContractRevision: textSendReplayContractRevision,
    );

PrivateReplyEligibilitySnapshot _eligibility({
  AccountId? accountId,
  ServerBase? server,
  int capabilityGeneration = 1,
  ChatCapabilityProfile? profile,
  ConversationListSuccess? conversations,
  ConversationToken? sourceRoomToken,
  ConversationToken? targetRoomToken,
  PrivateReplyParentContextResponse? parentContext,
  ParticipantsSuccess? sourceParticipants,
  ParticipantsSuccess? targetParticipants,
}) {
  final eligibilityAccount = accountId ?? _accountId;
  final eligibilityServer = server ?? _server;
  final sourceToken = sourceRoomToken ?? _sourceToken;
  final targetToken = targetRoomToken ?? _targetToken;
  return PrivateReplyEligibilitySnapshot.fromEvidence(
    accountId: eligibilityAccount,
    server: eligibilityServer,
    capabilityGeneration: capabilityGeneration,
    profile: profile ?? _profile(),
    conversations:
        conversations ??
        _conversations(
          requestAccountId: eligibilityAccount,
          requestServer: eligibilityServer,
          sourceToken: sourceToken,
          targetToken: targetToken,
        ),
    sourceRoomToken: sourceToken,
    targetRoomToken: targetToken,
    parentContext:
        parentContext ??
        _parentContext(
          requestAccountId: eligibilityAccount,
          requestServer: eligibilityServer,
          sourceRoomToken: sourceToken,
        ),
    sourceParticipants:
        sourceParticipants ??
        _participantsEvidence(
          requestAccountId: eligibilityAccount,
          requestServer: eligibilityServer,
          roomToken: sourceToken,
        ),
    targetParticipants:
        targetParticipants ??
        _participantsEvidence(
          requestAccountId: eligibilityAccount,
          requestServer: eligibilityServer,
          roomToken: targetToken,
        ),
  );
}

ConversationListSuccess _conversations({
  AccountId? requestAccountId,
  ServerBase? requestServer,
  ConversationFetchMode requestMode = ConversationFetchMode.full,
  ConversationToken? sourceToken,
  ConversationToken? targetToken,
  Map<String, Object?>? sourceRoom,
  Map<String, Object?>? targetRoom,
  bool includeSource = true,
  bool includeTarget = true,
}) {
  final source = sourceToken ?? _sourceToken;
  final target = targetToken ?? _targetToken;
  final json = <String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <Object?>[
        if (includeSource) sourceRoom ?? _roomJson(token: source),
        if (includeTarget) targetRoom ?? _directRoomJson(token: target),
      ],
    },
  };
  return decodeConversationListResponse(
        request: ConversationListRequest(
          accountId: requestAccountId ?? _accountId,
          requestId: ConversationRequestId.parse('private-reply-conversations'),
          server: requestServer ?? _server,
          mode: requestMode,
          includeLastMessage: true,
          cursor: requestMode == ConversationFetchMode.incremental
              ? ConversationCursor.parse('1724300000')
              : null,
        ),
        statusCode: 200,
        json: json,
        headers: const {
          'X-Nextcloud-Talk-Hash': 'fixture-hash-a',
          'X-Nextcloud-Talk-Modified-Before': '1724300001',
        },
      )
      as ConversationListSuccess;
}

Map<String, Object?> _directRoomJson({required ConversationToken token}) =>
    _roomJson(
      token: token,
      type: 1,
      name: jsonEncode(<String>[_senderActorId, _parentActorId]..sort()),
    );

Map<String, Object?> _roomJson({
  required ConversationToken token,
  int type = 2,
  String name = 'Synthetic source room',
  int attributes = 0,
  String actorType = 'users',
  String actorId = _senderActorId,
  String? remoteServer,
}) {
  final root = _fixture(
    'conversation-list/fixtures/conversations-full.response.json',
  );
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final room = Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
  room['token'] = token.value;
  room['type'] = type;
  room['name'] = name;
  room['attributes'] = attributes;
  room['actorType'] = actorType;
  room['actorId'] = actorId;
  if (remoteServer == null) {
    room.remove('remoteServer');
  } else {
    room['remoteServer'] = remoteServer;
  }
  final lastMessage = room['lastMessage'];
  if (lastMessage is Map<String, Object?>) {
    lastMessage['token'] = token.value;
  }
  return room;
}

PrivateReplyParentContextRequest _contextRequest({
  AccountId? accountId,
  ServerBase? server,
  ConversationToken? sourceRoomToken,
  int parentMessageId = _parentMessageId,
}) => PrivateReplyParentContextRequest(
  accountId: accountId ?? _accountId,
  requestId: ChatRequestId.parse('private-reply-parent-context'),
  server: server ?? _server,
  sourceRoomToken: sourceRoomToken ?? _sourceToken,
  parentMessageId: parentMessageId,
  profile: _profile(),
);

PrivateReplyParentContextResponse _parentContext({
  AccountId? requestAccountId,
  ServerBase? requestServer,
  ConversationToken? sourceRoomToken,
  int parentMessageId = _parentMessageId,
  int? messageId,
  String actorType = 'users',
  String actorId = _parentActorId,
  bool isReplyable = true,
  bool deleted = false,
  Map<String, Object?>? extraParent,
}) {
  final token = sourceRoomToken ?? _sourceToken;
  final message = _parentMessage(
    messageId: messageId ?? parentMessageId,
    roomToken: token,
    actorType: actorType,
    actorId: actorId,
    isReplyable: isReplyable,
    deleted: deleted,
  );
  final body = _fixture('chat-messages/fixtures/chat-history.response.json');
  final ocs = body['ocs']! as Map<String, Object?>;
  ocs['data'] = <Object?>[message, ?extraParent];
  return decodePrivateReplyParentContextResponse(
    request: _contextRequest(
      accountId: requestAccountId,
      server: requestServer,
      sourceRoomToken: token,
      parentMessageId: parentMessageId,
    ),
    statusCode: 200,
    body: _bytes(body),
    headers: ChatResponseHeaders.fromMap({
      'X-Chat-Last-Given': (messageId ?? parentMessageId).toString(),
    }),
  );
}

PrivateReplyParentContextResponse _parentContextFailure(int statusCode) =>
    decodePrivateReplyParentContextResponse(
      request: _contextRequest(),
      statusCode: statusCode,
      body: Uint8List(0),
    );

Map<String, Object?> _parentMessage({
  int messageId = _parentMessageId,
  ConversationToken? roomToken,
  String actorType = 'users',
  String actorId = _parentActorId,
  bool isReplyable = true,
  bool deleted = false,
}) {
  final root = _fixture('chat-messages/fixtures/chat-history.response.json');
  final ocs = root['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as List<Object?>;
  final message = Map<String, Object?>.from(
    data.first! as Map<String, Object?>,
  );
  message['id'] = messageId;
  message['token'] = (roomToken ?? _sourceToken).value;
  message['actorType'] = actorType;
  message['actorId'] = actorId;
  message['isReplyable'] = isReplyable;
  if (deleted) {
    message['deleted'] = true;
  } else {
    message.remove('deleted');
  }
  return message;
}

ParticipantsSuccess _participantsEvidence({
  AccountId? requestAccountId,
  ServerBase? requestServer,
  required ConversationToken roomToken,
  bool includeSender = true,
  bool includeParent = true,
  List<Map<String, Object?>> extraParticipants = const [],
}) {
  final data = <Object?>[
    if (includeSender) _participantJson(_senderActorId, attendeeId: 1),
    if (includeParent) _participantJson(_parentActorId, attendeeId: 2),
    ...extraParticipants,
  ];
  return decodeParticipantsResponse(
        request: ParticipantsRequest(
          accountId: requestAccountId ?? _accountId,
          server: requestServer ?? _server,
          roomToken: roomToken,
        ),
        statusCode: 200,
        body: _bytes({
          'ocs': {
            'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
            'data': data,
          },
        }),
      )
      as ParticipantsSuccess;
}

Map<String, Object?> _participantJson(
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

TextSendOutboxDraft _draft({
  required PrivateReplyEligibilitySnapshot? eligibility,
}) => TextSendOutboxDraft(
  operationId: _operationId,
  operationKind: 'textSend',
  roomToken: _targetToken,
  referenceId: _referenceId,
  message: _message,
  replayContractRevision: textSendReplayContractRevision,
  enqueueSequence: 1,
  replyTo: _parentMessageId,
  threadId: null,
  replyToToken: _sourceToken,
  parentRoomToken: _sourceToken,
  privateReplyEligibility: eligibility,
);

ChatRuntimeSnapshot _runtime() => ChatRuntimeSnapshot(
  accounts: <AccountId, ChatAccountState>{
    _accountId: ChatAccountState(
      accountId: _accountId,
      server: _server,
      lane: ChatAccountLane.ready,
      credentialGeneration: 1,
      capabilityGeneration: 1,
      scopes: const {},
      operations: const {},
    ),
  },
);

Uint8List _bytes(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

Map<String, Object?> _fixture(String relativePath) =>
    jsonDecode(File('../../contracts/$relativePath').readAsStringSync())!
        as Map<String, Object?>;
