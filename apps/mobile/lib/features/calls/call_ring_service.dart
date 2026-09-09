import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/account_repository.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

enum CallRingError {
  accountMissing,
  credentialMissing,
  reauthenticationRequired,
  forbidden,

  /// The room or the attendee is gone. The server answers `404` for both and
  /// does not say which, so neither does this.
  attendeeMissing,

  /// No call is running, so there is nothing to ring anybody into.
  noCallRunning,
  rateLimited,
  serviceUnavailable,
  network,
}

final class CallRingException implements Exception {
  const CallRingException(this.code);

  final CallRingError code;

  @override
  String toString() => 'CallRingException(${code.name})';
}

/// Rings one attendee into the call that is running in a room.
///
/// Ringing is a nudge, not a state: there is nothing to undo and no answer to
/// wait for. The server accepts it for anybody in the room, including someone
/// already in the call, so the caller decides who it makes sense to offer.
final class CallRingService {
  const CallRingService({
    required AccountRepository accounts,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
  }) : this._(accounts, credentials, api);

  const CallRingService._(this._accounts, this._credentials, this._api);

  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;

  Future<void> ring({
    required String accountId,
    required String roomToken,
    required int attendeeId,
  }) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      throw const CallRingException(CallRingError.accountMissing);
    }
    final appPassword = await _credentials.readAppPassword(accountId);
    if (appPassword == null || appPassword.isEmpty) {
      throw const CallRingException(CallRingError.credentialMissing);
    }
    final RingAttendeeRequest request;
    try {
      request = RingAttendeeRequest(
        context: CallRequestContext(
          authority: CallLifecycleAuthority(
            accountId: AccountId.parse(accountId),
            server: ServerBase.parse(account.serverUrl),
            roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
            nextcloudSessionId: ConversationSessionId.parse(_ringSession),
            credentialGeneration: 1,
            capabilityGeneration: 1,
            capabilityRevision: 'ring',
          ),
          mutationSequence: 0,
        ),
        attendeeId: attendeeId,
      );
    } on TalkProtocolException {
      throw const CallRingException(CallRingError.serviceUnavailable);
    }
    final CallRestResponse response;
    try {
      response = await _api.ringAttendee(
        ringRequest: request,
        loginName: account.loginName,
        appPassword: appPassword,
      );
    } on NextcloudApiException catch (error) {
      throw CallRingException(
        error.code == NextcloudApiError.unexpectedStatus &&
                error.statusCode == 401
            ? CallRingError.reauthenticationRequired
            : CallRingError.network,
      );
    } on TalkProtocolException {
      throw const CallRingException(CallRingError.serviceUnavailable);
    }
    switch (response.classification) {
      case CallResponseClassification.confirmed:
        return;
      case CallResponseClassification.rejected:
        // Measured: the only 400 this endpoint gives is `in-call`.
        throw const CallRingException(CallRingError.noCallRunning);
      case CallResponseClassification.reauthenticationRequired:
        throw const CallRingException(CallRingError.reauthenticationRequired);
      case CallResponseClassification.forbidden:
        throw const CallRingException(CallRingError.forbidden);
      case CallResponseClassification.sessionMissing:
        throw const CallRingException(CallRingError.attendeeMissing);
      case CallResponseClassification.rateLimited:
        throw const CallRingException(CallRingError.rateLimited);
      case CallResponseClassification.conflict:
      case CallResponseClassification.serverFailure:
        throw const CallRingException(CallRingError.serviceUnavailable);
    }
  }
}

/// The ring address carries no session of its own; the authority type requires
/// one and this value never reaches the server.
const String _ringSession = 'ring-attendee';

final callRingServiceProvider = Provider<CallRingService>((ref) {
  return CallRingService(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});
