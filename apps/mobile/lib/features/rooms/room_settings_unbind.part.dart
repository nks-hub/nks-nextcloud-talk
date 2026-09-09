part of 'room_settings_service.dart';

extension RoomSettingsUnbind on RoomSettingsService {
  /// Takes the object binding off a conversation so it survives that object.
  ///
  /// Returns the conversation's binding afterwards, because the server does
  /// not always remove one: a temporary phone room comes back as a persistent
  /// phone room rather than as an ordinary conversation, measured
  /// 9 September 2026.
  Future<String> unbindConversation({
    required String accountId,
    required String roomToken,
    required String objectType,
  }) async {
    final context = await _authContext(accountId);
    final CapabilitySnapshot capabilities;
    try {
      capabilities = await _api.getAuthenticatedCapabilities(
        server: ServerBase.parse(context.account.serverUrl),
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      );
    } on NextcloudApiException catch (error) {
      throw RoomSettingsException(_mapApiError(error));
    }
    final UnbindConversationRequest request;
    try {
      request = UnbindConversationRequest(
        accountId: AccountId.parse(accountId),
        server: ServerBase.parse(context.account.serverUrl),
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        objectType: objectType,
        capabilities: capabilities,
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.rejected);
    }
    final response = await _call(
      () => _api.administerRoom(
        administrationRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );
    if (response case RoomAdministrationSuccess(:final room)) {
      // The caller reloads the conversation from the server; nothing here
      // writes the cache, so a stale row cannot outlive a completed change.
      return room?.objectType ?? '';
    }
    _classifyAdministration(response);
    throw const RoomSettingsException(RoomSettingsError.invalidResponse);
  }
}
