part of 'room_settings_service.dart';

final class ClearHistoryResult {
  const ClearHistoryResult({required this.externalCopiesMayRemain});

  /// True for Talk's HTTP 202 success when a bridge or federation can retain
  /// content outside the cleared server history.
  final bool externalCopiesMayRemain;
}

extension RoomSettingsClearHistory on RoomSettingsService {
  /// Clears server history directly. This operation is never retried or
  /// admitted to an outbox because a repeated destructive request has no
  /// client-controlled idempotency key.
  Future<ClearHistoryResult> clearHistory({
    required String accountId,
    required String roomToken,
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
    final ClearRoomHistoryRequest request;
    try {
      request = ClearRoomHistoryRequest(
        accountId: AccountId.parse(accountId),
        server: server,
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        capabilities: capabilityRead.snapshot,
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }

    final response = await _call(
      () => _api.clearRoomHistory(
        clearRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );
    switch (response) {
      case ClearRoomHistorySuccess():
        try {
          await _chat.applyClearRoomHistorySuccess(response);
        } on Exception {
          throw const RoomSettingsException(RoomSettingsError.invalidResponse);
        }
        return ClearHistoryResult(
          externalCopiesMayRemain: response.externalCopiesMayRemain,
        );
      case ClearRoomHistoryReauthenticationRequired():
        throw const RoomSettingsException(
          RoomSettingsError.reauthenticationRequired,
        );
      case ClearRoomHistoryForbidden():
        throw const RoomSettingsException(RoomSettingsError.forbidden);
      case ClearRoomHistoryRoomMissing():
        throw const RoomSettingsException(RoomSettingsError.roomMissing);
      case ClearRoomHistoryHttpFailure(:final kind):
        throw RoomSettingsException(_mapHttpFailure(kind));
    }
  }
}
