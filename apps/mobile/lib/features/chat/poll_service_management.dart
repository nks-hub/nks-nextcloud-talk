part of 'poll_service.dart';

extension _PollManagement on PollService {
  Future<PollManagementAccess> _managementAccess({
    required PollRoomKey key,
    TalkPoll? poll,
  }) => _withManagement(
    key,
    (context) async => _accessFor(context, poll),
    poll: poll,
  );

  Future<TalkPoll> _close({required PollRoomKey key, required TalkPoll poll}) =>
      _withManagement(key, (context) async {
        _requireStatus(poll, PollStatus.open);
        _requireAllowed(_accessFor(context, poll).canClose);
        final request = PollCloseRequest(
          accountId: AccountId.parse(key.accountId),
          requestId: ChatRequestId.parse(_uuid.v4()),
          server: context.server,
          roomToken: context.room.token,
          pollsAvailable: true,
          pollId: poll.id,
          canClose: true,
        );
        final response = await _managedRequest(
          key,
          context,
          () => _api.closePoll(
            pollRequest: request,
            loginName: context.loginName,
            appPassword: context.appPassword,
          ),
          mutation: true,
        );
        return _confirmed(
          response,
          key.accountId,
          context: context,
          dispatched: true,
        );
      }, poll: poll);

  Future<List<TalkPoll>> _listDrafts(PollRoomKey key) =>
      _withManagement(key, (context) async {
        _requireDrafts(context);
        _requireAllowed(_accessFor(context, null).canListDrafts);
        final request = PollDraftListRequest(
          accountId: AccountId.parse(key.accountId),
          requestId: ChatRequestId.parse(_uuid.v4()),
          server: context.server,
          roomToken: context.room.token,
          pollsAvailable: true,
          draftsAvailable: true,
          isModerator: true,
        );
        final response = await _managedRequest(
          key,
          context,
          () => _api.getPollDrafts(
            pollRequest: request,
            loginName: context.loginName,
            appPassword: context.appPassword,
          ),
          mutation: false,
        );
        await _requireConfirmation(
          response.classification,
          context,
          mutation: false,
        );
        for (final draft in response.drafts) {
          _pollOrigins[draft] = context;
        }
        return response.drafts;
      });

  Future<TalkPoll> _createDraft({
    required PollRoomKey key,
    required String question,
    required List<String> options,
    required PollResultMode resultMode,
    required int maxVotes,
  }) => _withManagement(key, (context) async {
    _requireDrafts(context);
    _requireAllowed(_accessFor(context, null).canCreateDraft);
    final request = PollDraftCreateRequest(
      accountId: AccountId.parse(key.accountId),
      requestId: ChatRequestId.parse(_uuid.v4()),
      server: context.server,
      roomToken: context.room.token,
      pollsAvailable: true,
      draftsAvailable: true,
      isModerator: true,
      question: question,
      options: options,
      resultMode: resultMode,
      maxVotes: maxVotes,
    );
    final response = await _managedRequest(
      key,
      context,
      () => _api.createPollDraft(
        pollRequest: request,
        loginName: context.loginName,
        appPassword: context.appPassword,
      ),
      mutation: true,
      access: _PollAccess.writeDraft,
    );
    return _confirmed(
      response,
      key.accountId,
      context: context,
      dispatched: true,
    );
  });

  Future<TalkPoll> _editDraft({
    required PollRoomKey key,
    required TalkPoll draft,
    required String question,
    required List<String> options,
    required PollResultMode resultMode,
    required int maxVotes,
  }) => _withManagement(key, (context) async {
    _requireDrafts(context);
    if (!context.features.contains('edit-draft-poll')) {
      throw const PollServiceException(PollServiceError.unsupported);
    }
    _requireStatus(draft, PollStatus.draft);
    _requireAllowed(_accessFor(context, draft).canEditDraft);
    final request = PollDraftEditRequest(
      accountId: AccountId.parse(key.accountId),
      requestId: ChatRequestId.parse(_uuid.v4()),
      server: context.server,
      roomToken: context.room.token,
      pollsAvailable: true,
      draftsAvailable: true,
      editDraftAvailable: true,
      canEditDraft: true,
      pollId: draft.id,
      question: question,
      options: options,
      resultMode: resultMode,
      maxVotes: maxVotes,
    );
    final response = await _managedRequest(
      key,
      context,
      () => _api.editPollDraft(
        pollRequest: request,
        loginName: context.loginName,
        appPassword: context.appPassword,
      ),
      mutation: true,
      access: _PollAccess.writeDraft,
    );
    return _confirmed(
      response,
      key.accountId,
      context: context,
      dispatched: true,
    );
  }, poll: draft);

  Future<void> _deleteDraft({
    required PollRoomKey key,
    required TalkPoll draft,
  }) => _withManagement(key, (context) async {
    _requireDrafts(context);
    _requireStatus(draft, PollStatus.draft);
    _requireAllowed(_accessFor(context, draft).canDeleteDraft);
    final request = PollDraftDeleteRequest(
      accountId: AccountId.parse(key.accountId),
      requestId: ChatRequestId.parse(_uuid.v4()),
      server: context.server,
      roomToken: context.room.token,
      pollsAvailable: true,
      draftsAvailable: true,
      isModerator: true,
      pollId: draft.id,
    );
    final response = await _managedRequest(
      key,
      context,
      () => _api.deletePollDraft(
        pollRequest: request,
        loginName: context.loginName,
        appPassword: context.appPassword,
      ),
      mutation: true,
    );
    await _requireConfirmation(
      response.classification,
      context,
      mutation: true,
    );
    _pollOrigins[draft] = null;
  }, poll: draft);

  Future<TalkPoll> _publishDraft({
    required PollRoomKey key,
    required TalkPoll draft,
  }) => _withManagement(key, (context) async {
    _requireDrafts(context);
    _requireStatus(draft, PollStatus.draft);
    _requireAllowed(_accessFor(context, draft).canPublish);
    if (key.threadId != null && !context.features.contains('threads')) {
      throw const PollServiceException(PollServiceError.unsupported);
    }
    await _validateCachedContext(key, access: _PollAccess.create);
    final request = PollCreateRequest.fromDraft(
      accountId: AccountId.parse(key.accountId),
      requestId: ChatRequestId.parse(_uuid.v4()),
      server: context.server,
      roomToken: context.room.token,
      pollsAvailable: true,
      draftsAvailable: true,
      canPublishDraft: true,
      draft: draft,
      threadId: key.threadId,
    );
    final response = await _managedRequest(
      key,
      context,
      () => _api.createPoll(
        pollRequest: request,
        loginName: context.loginName,
        appPassword: context.appPassword,
      ),
      mutation: true,
      access: _PollAccess.create,
    );
    // Publishing creates a separate poll; the draft remains reusable.
    return _confirmed(
      response,
      key.accountId,
      context: context,
      dispatched: true,
    );
  }, poll: draft);

  Future<PollExportFile> _export({
    required PollRoomKey key,
    required TalkPoll poll,
    required PollExportFormat format,
  }) => _withManagement(key, (context) async {
    if (poll.status == PollStatus.draft) {
      throw const PollServiceException(PollServiceError.invalidInput);
    }
    if (context.room.isFederated) {
      throw const PollServiceException(PollServiceError.unsupported);
    }
    _requireAllowed(_accessFor(context, poll).canExport);
    final request = PollExportRequest(
      accountId: AccountId.parse(key.accountId),
      requestId: ChatRequestId.parse(_uuid.v4()),
      server: context.server,
      roomToken: context.room.token,
      pollsAvailable: true,
      pollId: poll.id,
      format: format,
      canExport: true,
    );
    final response = await _managedRequest(
      key,
      context,
      () => _api.exportPoll(
        pollRequest: request,
        loginName: context.loginName,
        appPassword: context.appPassword,
      ),
      mutation: false,
    );
    await _requireConfirmation(
      response.classification,
      context,
      mutation: false,
    );
    return PollExportFile(
      bytes: response.bytes!,
      fileName: response.fileName!,
      mimeType: response.mimeType!,
    );
  }, poll: poll);
}
