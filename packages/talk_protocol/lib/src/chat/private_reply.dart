import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../conversations/models.dart';
import '../conversations/request.dart';
import '../conversations/response.dart';
import '../identifiers.dart';
import '../participants/models.dart';
import '../participants/response.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';
import 'models.dart';
import 'profile.dart';
import 'request.dart';
import 'response.dart';

enum PrivateReplyParentContextClassification {
  found,
  notModified,
  reauthenticationRequired,
  forbidden,
  missing,
  rateLimited,
  serviceUnavailable,
}

/// A read-only request for exactly one prospective cross-room reply parent.
final class PrivateReplyParentContextRequest {
  PrivateReplyParentContextRequest({
    required this.accountId,
    required this.requestId,
    required this.server,
    required this.sourceRoomToken,
    required this.parentMessageId,
    required this.profile,
    this.userAgent = chatContractUserAgent,
  }) {
    if (parentMessageId < 1 ||
        !profile.read ||
        !profile.privateReply ||
        profile.federated) {
      _eligibilityFailure(r'$.privateReply.parentContext.request');
    }
    if (userAgent.isEmpty ||
        userAgent.length > 256 ||
        userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidChatRequest,
        r'$.headers.userAgent',
      );
    }
  }

  final AccountId accountId;
  final ChatRequestId requestId;
  final ServerBase server;
  final ConversationToken sourceRoomToken;
  final int parentMessageId;
  final ChatCapabilityProfile profile;
  final String userAgent;

  Map<String, String> get queryParameters =>
      UnmodifiableMapView(const {'format': 'json', 'limit': '0'});

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => server.uri.replace(
    path:
        '${server.basePath}$chatV1Path/${sourceRoomToken.value}/'
        '$parentMessageId/context',
    queryParameters: queryParameters,
  );

  ChatFetchRequest _decoderRequest() => ChatFetchRequest(
    accountId: accountId,
    requestId: requestId,
    server: server,
    roomToken: sourceRoomToken,
    profile: profile,
    direction: ChatFetchDirection.history,
    cursor: ChatCursor.parse(parentMessageId.toString()),
    lastCommonRead: ChatCursor.parse('0'),
    limit: 1,
    includeLastKnown: true,
    timeoutSeconds: 0,
    interactive: true,
    userAgent: userAgent,
  );

  @override
  String toString() => 'PrivateReplyParentContextRequest(<redacted>)';
}

/// A request-bound response from the message-context endpoint.
///
/// Only [PrivateReplyParentContextClassification.found] carries a parent and
/// can be used to construct an eligibility snapshot.
final class PrivateReplyParentContextResponse {
  const PrivateReplyParentContextResponse._({
    required this.request,
    required this.classification,
    required this.parent,
  });

  final PrivateReplyParentContextRequest request;
  final PrivateReplyParentContextClassification classification;
  final ChatMessage? parent;

  @override
  String toString() =>
      'PrivateReplyParentContextResponse('
      'classification: ${classification.name})';
}

PrivateReplyParentContextResponse decodePrivateReplyParentContextResponse({
  required PrivateReplyParentContextRequest request,
  required int statusCode,
  required Uint8List body,
  ChatResponseHeaders? headers,
}) {
  final failure = switch (statusCode) {
    304 => PrivateReplyParentContextClassification.notModified,
    401 => PrivateReplyParentContextClassification.reauthenticationRequired,
    403 => PrivateReplyParentContextClassification.forbidden,
    404 => PrivateReplyParentContextClassification.missing,
    429 => PrivateReplyParentContextClassification.rateLimited,
    503 => PrivateReplyParentContextClassification.serviceUnavailable,
    200 => null,
    _ => throw TalkProtocolException(
      TalkProtocolErrorCode.unsupportedHttpStatus,
      path: r'$.statusCode',
    ),
  };
  if (failure != null) {
    if (body.length > chatMaximumResponseBytes ||
        (statusCode == 304 && body.isNotEmpty)) {
      protocolFailure(TalkProtocolErrorCode.invalidChatResponse, r'$.body');
    }
    return PrivateReplyParentContextResponse._(
      request: request,
      classification: failure,
      parent: null,
    );
  }

  final decoded = decodeChatGetResponse(
    request: request._decoderRequest(),
    statusCode: statusCode,
    body: body,
    headers: headers,
  );
  if (decoded.classification != ChatGetClassification.messages ||
      decoded.messages.length != 1) {
    protocolFailure(TalkProtocolErrorCode.invalidChatResponse, r'$.ocs.data');
  }
  final parent = decoded.messages.single;
  if (parent.messageId != request.parentMessageId ||
      parent.roomToken != request.sourceRoomToken) {
    protocolFailure(
      TalkProtocolErrorCode.invalidChatResponse,
      r'$.ocs.data[0]',
    );
  }
  return PrivateReplyParentContextResponse._(
    request: request,
    classification: PrivateReplyParentContextClassification.found,
    parent: parent,
  );
}

/// Immutable proof that one cross-room private reply was eligible when it was
/// admitted to the durable outbox.
final class PrivateReplyEligibilitySnapshot {
  PrivateReplyEligibilitySnapshot._({
    required this.accountId,
    required this.server,
    required this.capabilityGeneration,
    required this.sourceRoomToken,
    required this.targetRoomToken,
    required this.parentMessageId,
    required this.senderActorId,
    required this.parentActorId,
  });

  factory PrivateReplyEligibilitySnapshot.fromEvidence({
    required AccountId accountId,
    required ServerBase server,
    required int capabilityGeneration,
    required ChatCapabilityProfile profile,
    required ConversationListSuccess conversations,
    required ConversationToken sourceRoomToken,
    required ConversationToken targetRoomToken,
    required PrivateReplyParentContextResponse parentContext,
    required ParticipantsSuccess sourceParticipants,
    required ParticipantsSuccess targetParticipants,
  }) {
    if (capabilityGeneration < 1 ||
        !profile.privateReply ||
        profile.federated) {
      _eligibilityFailure(r'$.privateReply.authority');
    }
    if (conversations.request.accountId != accountId ||
        conversations.request.server != server ||
        conversations.request.mode != ConversationFetchMode.full ||
        sourceRoomToken == targetRoomToken) {
      _eligibilityFailure(r'$.privateReply.conversations');
    }
    final sourceRoom = _singleRoom(
      conversations.rooms,
      sourceRoomToken,
      r'$.privateReply.sourceRoom',
    );
    final targetRoom = _singleRoom(
      conversations.rooms,
      targetRoomToken,
      r'$.privateReply.targetRoom',
    );
    if (sourceRoom.attributes & 4 != 0 || sourceRoom.isFederated) {
      _eligibilityFailure(r'$.privateReply.sourceRoom');
    }
    if (targetRoom.type != 1 || targetRoom.isFederated) {
      _eligibilityFailure(r'$.privateReply.targetRoom.type');
    }

    final contextRequest = parentContext.request;
    final parent = parentContext.parent;
    if (contextRequest.accountId != accountId ||
        contextRequest.server != server ||
        contextRequest.sourceRoomToken != sourceRoomToken ||
        parentContext.classification !=
            PrivateReplyParentContextClassification.found ||
        parent == null ||
        parent.messageId != contextRequest.parentMessageId ||
        parent.roomToken != sourceRoomToken ||
        parent.deleted ||
        !parent.isReplyable) {
      _eligibilityFailure(r'$.privateReply.parent');
    }

    final senderActorId = targetRoom.actorId;
    final parentActorId = parent.actorId;
    if (sourceRoom.actorType != 'users' ||
        targetRoom.actorType != 'users' ||
        parent.actorType != 'users' ||
        senderActorId.isEmpty ||
        sourceRoom.actorId != senderActorId ||
        parentActorId.isEmpty ||
        senderActorId == parentActorId) {
      _eligibilityFailure(r'$.privateReply.actors');
    }

    final canonicalActors = <String>[senderActorId, parentActorId]..sort();
    if (targetRoom.name != jsonEncode(canonicalActors)) {
      _eligibilityFailure(r'$.privateReply.targetRoom.name');
    }

    _validateParticipantsEvidence(
      response: sourceParticipants,
      accountId: accountId,
      server: server,
      roomToken: sourceRoomToken,
      senderActorId: senderActorId,
      parentActorId: parentActorId,
    );
    _validateParticipantsEvidence(
      response: targetParticipants,
      accountId: accountId,
      server: server,
      roomToken: targetRoomToken,
      senderActorId: senderActorId,
      parentActorId: parentActorId,
    );

    return PrivateReplyEligibilitySnapshot._(
      accountId: accountId,
      server: server,
      capabilityGeneration: capabilityGeneration,
      sourceRoomToken: sourceRoomToken,
      targetRoomToken: targetRoomToken,
      parentMessageId: contextRequest.parentMessageId,
      senderActorId: senderActorId,
      parentActorId: parentActorId,
    );
  }

  final AccountId accountId;
  final ServerBase server;
  final int capabilityGeneration;
  final ConversationToken sourceRoomToken;
  final ConversationToken targetRoomToken;
  final int parentMessageId;
  final String senderActorId;
  final String parentActorId;

  bool matchesAdmission({
    required AccountId accountId,
    required ServerBase server,
    required int capabilityGeneration,
    required ConversationToken sourceRoomToken,
    required ConversationToken targetRoomToken,
    required int parentMessageId,
  }) =>
      this.accountId == accountId &&
      this.server == server &&
      this.capabilityGeneration == capabilityGeneration &&
      this.sourceRoomToken == sourceRoomToken &&
      this.targetRoomToken == targetRoomToken &&
      this.parentMessageId == parentMessageId;

  @override
  String toString() => 'PrivateReplyEligibilitySnapshot(<redacted>)';
}

ConversationRoom _singleRoom(
  List<ConversationRoom> rooms,
  ConversationToken token,
  String path,
) {
  final matches = rooms.where((room) => room.token == token).toList();
  if (matches.length != 1) {
    _eligibilityFailure(path);
  }
  return matches.single;
}

void _validateParticipantsEvidence({
  required ParticipantsSuccess response,
  required AccountId accountId,
  required ServerBase server,
  required ConversationToken roomToken,
  required String senderActorId,
  required String parentActorId,
}) {
  final request = response.request;
  if (request.accountId != accountId ||
      request.server != server ||
      request.roomToken != roomToken ||
      !_hasSingleUser(response.participants, senderActorId) ||
      !_hasSingleUser(response.participants, parentActorId)) {
    _eligibilityFailure(r'$.privateReply.participants');
  }
}

bool _hasSingleUser(List<Participant> participants, String actorId) =>
    participants
        .where(
          (participant) =>
              participant.actorType == 'users' &&
              participant.actorId == actorId,
        )
        .length ==
    1;

Never _eligibilityFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.unsupportedChatOperation, path);
