part of 'room_settings_service.dart';

/// What the server reported about a CSV of e-mail invitations.
final class EmailInvitationImportResult {
  const EmailInvitationImportResult({
    required this.invites,
    required this.duplicates,
    required this.invitationsSent,
  });

  /// Addresses the server accepted; on a preview, what it would invite.
  final int invites;

  /// Addresses skipped as already invited or repeated inside the file.
  final int duplicates;

  /// `true` only when invitations really left the server. A preview is always
  /// `false`, and the protocol layer refuses a preview that claims otherwise.
  final bool invitationsSent;
}

/// A CSV the server parsed but refused: some rows are not addresses, so
/// nothing was imported.
final class EmailInvitationInvalidRowsException implements Exception {
  const EmailInvitationInvalidRowsException({
    required this.invalid,
    required this.invalidLines,
  });

  final int invalid;

  /// 1-based line numbers, the header counted as line 1.
  final List<int> invalidLines;

  @override
  String toString() => 'EmailInvitationInvalidRowsException(invalid: $invalid)';
}

/// A CSV the server would not read at all — no `email` header, empty upload,
/// unusable encoding. [message] is the server's own translated explanation.
final class EmailInvitationFileRejectedException implements Exception {
  const EmailInvitationFileRejectedException(this.message);

  final String? message;

  @override
  String toString() => 'EmailInvitationFileRejectedException()';
}

extension RoomSettingsEmailInvitations on RoomSettingsService {
  /// Uploads a CSV of e-mail addresses.
  ///
  /// With [testRun] the server only reports what it would do; without it the
  /// invitations really go out. Neither call is ever retried or queued: an
  /// e-mail send has no client-controlled idempotency key, so a request whose
  /// outcome is unknown is reported as [RoomSettingsError.ambiguous] and left
  /// for a person to decide about.
  Future<EmailInvitationImportResult> importEmailInvitations({
    required String accountId,
    required String roomToken,
    required List<int> csvBytes,
    required String fileName,
    required bool testRun,
  }) async {
    final context = await _authContext(accountId);
    final ServerBase server;
    try {
      server = ServerBase.parse(context.account.serverUrl);
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }

    final capabilityRead = await _call(
      () => _api.getAuthenticatedCapabilitiesWithSource(
        server: server,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
        forceRefresh: true,
      ),
    );

    final ImportEmailInvitationsRequest request;
    try {
      request = ImportEmailInvitationsRequest(
        accountId: AccountId.parse(accountId),
        server: server,
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        csvBytes: csvBytes,
        fileName: fileName,
        testRun: testRun,
        capabilities: capabilityRead.snapshot,
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }

    final ImportEmailInvitationsResponse response;
    try {
      response = await _api.importEmailInvitations(
        importRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      );
    } on NextcloudApiException catch (error) {
      throw RoomSettingsException(_mapSendError(error, testRun: testRun));
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }

    switch (response) {
      case ImportEmailInvitationsSuccess(
        :final invites,
        :final duplicates,
        :final invitationsSent,
      ):
        return EmailInvitationImportResult(
          invites: invites,
          duplicates: duplicates,
          invitationsSent: invitationsSent,
        );
      case ImportEmailInvitationsInvalidRows(
        :final invalid,
        :final invalidLines,
      ):
        throw EmailInvitationInvalidRowsException(
          invalid: invalid,
          invalidLines: invalidLines,
        );
      case ImportEmailInvitationsRejected(:final message):
        throw EmailInvitationFileRejectedException(message);
      case ImportEmailInvitationsReauthenticationRequired():
        throw const RoomSettingsException(
          RoomSettingsError.reauthenticationRequired,
        );
      case ImportEmailInvitationsForbidden():
        throw const RoomSettingsException(RoomSettingsError.forbidden);
      case ImportEmailInvitationsRoomMissing():
        throw const RoomSettingsException(RoomSettingsError.roomMissing);
      case ImportEmailInvitationsHttpFailure(:final kind):
        throw RoomSettingsException(_mapHttpFailure(kind));
    }
  }

  /// Mails the invitation again, to [attendeeId] or to every e-mail attendee.
  ///
  /// Never retried: see [importEmailInvitations].
  Future<void> resendEmailInvitations({
    required String accountId,
    required String roomToken,
    int? attendeeId,
  }) async {
    final context = await _authContext(accountId);
    final ResendEmailInvitationsRequest request;
    try {
      request = ResendEmailInvitationsRequest(
        accountId: AccountId.parse(accountId),
        server: ServerBase.parse(context.account.serverUrl),
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        attendeeId: attendeeId,
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }

    final ResendEmailInvitationsResponse response;
    try {
      response = await _api.resendEmailInvitations(
        resendRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      );
    } on NextcloudApiException catch (error) {
      throw RoomSettingsException(_mapSendError(error, testRun: false));
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }

    switch (response) {
      case ResendEmailInvitationsSuccess():
        return;
      case ResendEmailInvitationsReauthenticationRequired():
        throw const RoomSettingsException(
          RoomSettingsError.reauthenticationRequired,
        );
      case ResendEmailInvitationsForbidden():
        throw const RoomSettingsException(RoomSettingsError.forbidden);
      case ResendEmailInvitationsTargetMissing():
        throw const RoomSettingsException(RoomSettingsError.roomMissing);
      case ResendEmailInvitationsHttpFailure(:final kind):
        throw RoomSettingsException(_mapHttpFailure(kind));
    }
  }

  /// A dropped connection around a request that may already have mailed
  /// people is not a plain network error: nobody can tell from here whether
  /// the invitations went out. It is reported as ambiguous so the UI asks the
  /// moderator to check instead of offering to try again.
  RoomSettingsError _mapSendError(
    NextcloudApiException error, {
    required bool testRun,
  }) {
    final mapped = _mapApiError(error);
    if (testRun) {
      return mapped;
    }
    return mapped == RoomSettingsError.network
        ? RoomSettingsError.ambiguous
        : mapped;
  }
}
