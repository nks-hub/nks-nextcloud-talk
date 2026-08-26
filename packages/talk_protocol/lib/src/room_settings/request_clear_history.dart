part of 'request.dart';

/// Clears all server chat history in one conversation.
///
/// Evidence: Talk `f2958bb25be6604240c58a3faf9a2033a30d20e5`,
/// `ChatController::clearHistory`, `ChatManager::clearHistory` and
/// `docs/chat.md`. The operation requires moderator permissions, a read-write
/// conversation and the authenticated `clear-history` capability. It is a
/// direct online-only DELETE; it has no request body and must never enter a
/// durable replay queue.
final class ClearRoomHistoryRequest {
  ClearRoomHistoryRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required CapabilitySnapshot capabilities,
    this.userAgent = roomSettingsContractUserAgent,
  }) {
    if (capabilities.context != CapabilityContext.authenticated ||
        !capabilities.supportsTalk('clear-history')) {
      protocolFailure(_requestCode, r'$.capabilities.clear-history');
    }
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final String userAgent;

  String get httpMethod => 'DELETE';

  Map<String, String>? get formBody => null;

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => server.uri.replace(
    path: '${server.basePath}$chatV1Path/${roomToken.value}',
    queryParameters: const {'format': 'json'},
  );

  @override
  String toString() => 'ClearRoomHistoryRequest(<redacted>)';
}
