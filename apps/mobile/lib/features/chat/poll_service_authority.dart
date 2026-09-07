part of 'poll_service.dart';

extension _PollAuthority on PollService {
  Future<void> _validateIdentity(_PreparedPoll context) async {
    final account = await _accounts.getAccount(context.accountId);
    final password = await _credentials.readAppPassword(context.accountId);
    if (account == null ||
        account.loginName != context.loginName ||
        ServerBase.parse(account.serverUrl) != context.server ||
        password != context.appPassword) {
      throw const PollServiceException(PollServiceError.contextMissing);
    }
  }

  void _requireOrigin(PollRoomKey key, TalkPoll poll, _PreparedPoll context) {
    final origin = _pollOrigins[poll];
    if (origin == null ||
        origin.accountId != key.accountId ||
        origin.room.token.value != key.roomToken ||
        origin.server != context.server ||
        origin.loginName != context.loginName ||
        origin.appPassword != context.appPassword) {
      throw const PollServiceException(PollServiceError.contextMissing);
    }
  }

  Future<_PreparedPoll> _prepareManagement(PollRoomKey key) async {
    final context = await _prepare(
      key,
      access: _PollAccess.readVote,
      forceCapabilities: true,
    );
    try {
      final response = await _api.getConversations(
        conversationRequest: ConversationListRequest(
          accountId: AccountId.parse(key.accountId),
          requestId: ConversationRequestId.parse(_uuid.v4()),
          server: context.server,
          mode: ConversationFetchMode.full,
          includeLastMessage: false,
        ),
        loginName: context.loginName,
        appPassword: context.appPassword,
      );
      await _validateIdentity(context);
      if (response is! ConversationListSuccess) {
        if (response.statusCode == 401) {
          await _chat.markReauthenticationRequired(key.accountId);
          throw const PollServiceException(
            PollServiceError.reauthenticationRequired,
          );
        }
        throw PollServiceException(
          response.statusCode == 429
              ? PollServiceError.rateLimited
              : PollServiceError.unavailable,
        );
      }
      final matches = response.rooms.where(
        (room) => room.token.value == key.roomToken,
      );
      if (matches.length != 1) {
        throw const PollServiceException(PollServiceError.contextMissing);
      }
      final room = matches.single;
      final role = participantRoleFor(room.participantType);
      if (role == null ||
          (room.lobbyState != 0 &&
              !_isPollModerator(room) &&
              room.permissions & _ignoreLobbyPermission !=
                  _ignoreLobbyPermission)) {
        throw const PollServiceException(PollServiceError.permissionDenied);
      }
      final own = await _api.getOwnProfile(
        server: context.server,
        loginName: context.loginName,
        appPassword: context.appPassword,
      );
      await _validateIdentity(context);
      await _validateCachedContext(key, access: _PollAccess.readVote);
      return _PreparedPoll(
        accountId: context.accountId,
        server: context.server,
        room: room,
        loginName: context.loginName,
        appPassword: context.appPassword,
        features: context.features,
        userId: own.userId,
      );
    } on PollServiceException {
      rethrow;
    } on NextcloudApiException catch (error) {
      await _validateIdentity(context);
      if (error.statusCode == 401) {
        await _chat.markReauthenticationRequired(key.accountId);
        throw const PollServiceException(
          PollServiceError.reauthenticationRequired,
        );
      }
      throw PollServiceException(
        error.statusCode == 429
            ? PollServiceError.rateLimited
            : PollServiceError.unavailable,
      );
    } on TalkProtocolException {
      throw const PollServiceException(PollServiceError.invalidResponse);
    }
  }

  PollManagementAccess _accessFor(_PreparedPoll context, TalkPoll? poll) {
    final moderator = _isPollModerator(context.room);
    final author =
        poll != null &&
        poll.actorType == 'users' &&
        poll.actorId == context.userId;
    final drafts = context.features.contains('talk-polls-drafts');
    final write = _canWritePoll(context.room);
    final draft = poll == null || poll.status == PollStatus.draft;
    return PollManagementAccess(
      canListDrafts: drafts && moderator,
      canCreateDraft: drafts && moderator && write,
      canEditDraft:
          drafts &&
          draft &&
          write &&
          (moderator || author) &&
          context.features.contains('edit-draft-poll'),
      canDeleteDraft:
          drafts &&
          draft &&
          (participantRoleFor(context.room.participantType) ==
                  ParticipantRole.owner ||
              participantRoleFor(context.room.participantType) ==
                  ParticipantRole.moderator),
      canPublish: drafts && draft && write && (moderator || author),
      canClose: poll?.status == PollStatus.open && (moderator || author),
      canExport:
          poll != null &&
          poll.status != PollStatus.draft &&
          !context.room.isFederated &&
          (moderator || author),
    );
  }

  Future<T> _withManagement<T>(
    PollRoomKey key,
    Future<T> Function(_PreparedPoll context) action, {
    TalkPoll? poll,
  }) async {
    final context = await _prepareManagement(key);
    if (poll != null) _requireOrigin(key, poll, context);
    try {
      return await action(context);
    } on TalkProtocolException {
      // Invalid local form data has not crossed the mutation boundary.
      throw const PollServiceException(PollServiceError.invalidInput);
    }
  }

  Future<T> _managedRequest<T>(
    PollRoomKey key,
    _PreparedPoll context,
    Future<T> Function() send, {
    required bool mutation,
    _PollAccess access = _PollAccess.readVote,
  }) async {
    await _validateIdentity(context);
    await _validateCachedContext(key, access: access);
    try {
      final response = await send();
      await _validateIdentity(context);
      await _validateCachedContext(key, access: access);
      return response;
    } on NextcloudApiException catch (error) {
      await _validateIdentity(context);
      if (error.statusCode == 401) {
        await _chat.markReauthenticationRequired(key.accountId);
        throw const PollServiceException(
          PollServiceError.reauthenticationRequired,
        );
      }
      throw PollServiceException(
        error.statusCode == 429
            ? PollServiceError.rateLimited
            : mutation
            ? PollServiceError.ambiguous
            : PollServiceError.unavailable,
      );
    } on TalkProtocolException {
      throw PollServiceException(
        mutation
            ? PollServiceError.ambiguous
            : PollServiceError.invalidResponse,
      );
    }
  }

  Future<void> _requireConfirmation(
    PollResponseClassification status,
    _PreparedPoll context, {
    required bool mutation,
  }) async {
    if (status == PollResponseClassification.confirmed) return;
    if (status == PollResponseClassification.reauthenticationRequired) {
      await _chat.markReauthenticationRequired(context.accountId);
    }
    throw PollServiceException(switch (status) {
      PollResponseClassification.invalidInput => PollServiceError.invalidInput,
      PollResponseClassification.notFound => PollServiceError.notFound,
      PollResponseClassification.permissionDenied =>
        PollServiceError.permissionDenied,
      PollResponseClassification.reauthenticationRequired =>
        PollServiceError.reauthenticationRequired,
      PollResponseClassification.rateLimited => PollServiceError.rateLimited,
      _ => mutation ? PollServiceError.ambiguous : PollServiceError.unavailable,
    });
  }

  void _requireDrafts(_PreparedPoll context) {
    if (!context.features.contains('talk-polls-drafts')) {
      throw const PollServiceException(PollServiceError.unsupported);
    }
  }

  void _requireAllowed(bool allowed) {
    if (!allowed) {
      throw const PollServiceException(PollServiceError.permissionDenied);
    }
  }

  void _requireStatus(TalkPoll poll, PollStatus status) {
    if (poll.status != status) {
      throw const PollServiceException(PollServiceError.invalidInput);
    }
  }
}

bool _isPollModerator(ConversationRoom room) =>
    switch (participantRoleFor(room.participantType)) {
      ParticipantRole.owner ||
      ParticipantRole.moderator ||
      ParticipantRole.guestModerator => true,
      _ => false,
    };

bool _canWritePoll(ConversationRoom room) =>
    room.readOnly == 0 &&
    (room.type == _roomTypeGroup || room.type == _roomTypePublic) &&
    (room.permissions == 0 ||
        room.permissions & _chatPermission == _chatPermission);
