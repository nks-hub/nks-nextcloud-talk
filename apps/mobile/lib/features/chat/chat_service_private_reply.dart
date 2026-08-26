part of 'chat_service.dart';

extension ChatServicePrivateReply on ChatService {
  /// Fetches fresh, request-bound evidence for one cross-room private reply.
  /// The returned snapshot is still rechecked against the current capability
  /// generation when [ChatService.sendText] admits the durable operation.
  Future<PrivateReplyEligibilitySnapshot> preparePrivateReplyEligibility({
    required String accountId,
    required String sourceRoomToken,
    required String targetRoomToken,
    required int parentMessageId,
    Future<void>? abortTrigger,
  }) {
    final key = _roomKey(accountId, targetRoomToken);
    return _serializeRoom<PrivateReplyEligibilitySnapshot>(key, () {
      return _withRoomErrorPersistence(accountId, targetRoomToken, () async {
        final sourceToken = ConversationToken.parse(
          sourceRoomToken,
          path: r'$.sourceRoomToken',
        );
        final targetToken = ConversationToken.parse(
          targetRoomToken,
          path: r'$.targetRoomToken',
        );
        if (parentMessageId < 1 || sourceToken == targetToken) {
          throw const ChatServiceException(ChatServiceError.sendUnsupported);
        }

        final prepared = await _prepare(
          accountId,
          targetRoomToken,
          abortTrigger: abortTrigger,
          forceCapabilityNetworkRead: true,
        );
        if (prepared.room.token != targetToken ||
            !prepared.profile.privateReply ||
            prepared.profile.federated) {
          throw const ChatServiceException(ChatServiceError.sendUnsupported);
        }

        final authority = prepared.authority;
        final conversationRequest = ConversationListRequest(
          accountId: authority.accountId,
          requestId: ConversationRequestId.parse(_uuid.v4()),
          server: authority.server,
          mode: ConversationFetchMode.full,
          includeLastMessage: false,
        );
        final sourceParticipantsRequest = ParticipantsRequest(
          accountId: authority.accountId,
          server: authority.server,
          roomToken: sourceToken,
          includeStatus: false,
        );
        final targetParticipantsRequest = ParticipantsRequest(
          accountId: authority.accountId,
          server: authority.server,
          roomToken: targetToken,
          includeStatus: false,
        );
        final parentContextRequest = PrivateReplyParentContextRequest(
          accountId: authority.accountId,
          requestId: ChatRequestId.parse(_uuid.v4()),
          server: authority.server,
          sourceRoomToken: sourceToken,
          parentMessageId: parentMessageId,
          profile: prepared.profile,
        );

        final responses = await Future.wait<Object>(<Future<Object>>[
          _api.getConversations(
            conversationRequest: conversationRequest,
            loginName: prepared.account.loginName,
            appPassword: prepared.appPassword,
            abortTrigger: abortTrigger,
          ),
          _api.getParticipants(
            participantsRequest: sourceParticipantsRequest,
            loginName: prepared.account.loginName,
            appPassword: prepared.appPassword,
            abortTrigger: abortTrigger,
          ),
          _api.getParticipants(
            participantsRequest: targetParticipantsRequest,
            loginName: prepared.account.loginName,
            appPassword: prepared.appPassword,
            abortTrigger: abortTrigger,
          ),
          _api.getPrivateReplyParentContext(
            contextRequest: parentContextRequest,
            loginName: prepared.account.loginName,
            appPassword: prepared.appPassword,
            abortTrigger: abortTrigger,
          ),
        ]);
        final conversationResponse = responses[0] as ConversationListResponse;
        final sourceParticipantsResponse = responses[1] as ParticipantsResponse;
        final targetParticipantsResponse = responses[2] as ParticipantsResponse;
        final parentContext = responses[3] as PrivateReplyParentContextResponse;

        if (conversationResponse is ConversationReauthenticationRequired ||
            sourceParticipantsResponse
                is ParticipantsReauthenticationRequired ||
            targetParticipantsResponse
                is ParticipantsReauthenticationRequired ||
            parentContext.classification ==
                PrivateReplyParentContextClassification
                    .reauthenticationRequired) {
          await _chat.markReauthenticationRequired(accountId);
          throw const ChatServiceException(
            ChatServiceError.reauthenticationRequired,
          );
        }

        try {
          return PrivateReplyEligibilitySnapshot.fromEvidence(
            accountId: authority.accountId,
            server: authority.server,
            capabilityGeneration: authority.capabilityGeneration,
            profile: prepared.profile,
            conversations: _requirePrivateReplyConversations(
              conversationResponse,
            ),
            sourceRoomToken: sourceToken,
            targetRoomToken: targetToken,
            parentContext: _requirePrivateReplyParentContext(parentContext),
            sourceParticipants: _requirePrivateReplyParticipants(
              sourceParticipantsResponse,
            ),
            targetParticipants: _requirePrivateReplyParticipants(
              targetParticipantsResponse,
            ),
          );
        } on TalkProtocolException catch (error) {
          if (error.code == TalkProtocolErrorCode.unsupportedChatOperation) {
            throw const ChatServiceException(ChatServiceError.sendUnsupported);
          }
          rethrow;
        }
      });
    });
  }

  ConversationListSuccess _requirePrivateReplyConversations(
    ConversationListResponse response,
  ) {
    return switch (response) {
      ConversationListSuccess() => response,
      ConversationReauthenticationRequired() =>
        throw const ChatServiceException(
          ChatServiceError.reauthenticationRequired,
        ),
      ConversationOcsFailure() => throw const ChatServiceException(
        ChatServiceError.invalidResponse,
      ),
      ConversationHttpFailure(:final kind) => switch (kind) {
        ConversationHttpFailureKind.upgradeRequired =>
          throw const ChatServiceException(ChatServiceError.chatUnsupported),
        ConversationHttpFailureKind.rateLimited =>
          throw const ChatServiceException(ChatServiceError.rateLimited),
        ConversationHttpFailureKind.serviceUnavailable =>
          throw const ChatServiceException(ChatServiceError.serviceUnavailable),
      },
    };
  }

  ParticipantsSuccess _requirePrivateReplyParticipants(
    ParticipantsResponse response,
  ) {
    return switch (response) {
      ParticipantsSuccess() => response,
      ParticipantsReauthenticationRequired() =>
        throw const ChatServiceException(
          ChatServiceError.reauthenticationRequired,
        ),
      ParticipantsForbidden() || ParticipantsRoomMissing() =>
        throw const ChatServiceException(ChatServiceError.sendUnsupported),
      ParticipantsHttpFailure(:final kind) => switch (kind) {
        ParticipantsHttpFailureKind.rateLimited =>
          throw const ChatServiceException(ChatServiceError.rateLimited),
        ParticipantsHttpFailureKind.serviceUnavailable =>
          throw const ChatServiceException(ChatServiceError.serviceUnavailable),
      },
    };
  }

  PrivateReplyParentContextResponse _requirePrivateReplyParentContext(
    PrivateReplyParentContextResponse response,
  ) {
    return switch (response.classification) {
      PrivateReplyParentContextClassification.found => response,
      PrivateReplyParentContextClassification.reauthenticationRequired =>
        throw const ChatServiceException(
          ChatServiceError.reauthenticationRequired,
        ),
      PrivateReplyParentContextClassification.rateLimited =>
        throw const ChatServiceException(ChatServiceError.rateLimited),
      PrivateReplyParentContextClassification.serviceUnavailable =>
        throw const ChatServiceException(ChatServiceError.serviceUnavailable),
      PrivateReplyParentContextClassification.notModified ||
      PrivateReplyParentContextClassification.forbidden ||
      PrivateReplyParentContextClassification.missing =>
        throw const ChatServiceException(ChatServiceError.sendUnsupported),
    };
  }
}
