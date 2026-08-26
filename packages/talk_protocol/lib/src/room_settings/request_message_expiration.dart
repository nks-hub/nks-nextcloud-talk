part of 'request.dart';

/// Sets the lifetime of new chat messages for a conversation.
///
/// Evidence: Talk `f2958bb25be6604240c58a3faf9a2033a30d20e5`,
/// `RoomController::setMessageExpiration`, `RoomService::setMessageExpiration`
/// and `docs/conversation.md`. The v4 endpoint requires a moderator and the
/// authenticated `message-expiration` capability. Any non-negative number of
/// seconds is valid; `0` disables expiration.
final class SetMessageExpirationRequest {
  SetMessageExpirationRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required CapabilitySnapshot capabilities,
    required this.seconds,
    this.userAgent = roomSettingsContractUserAgent,
  }) {
    if (capabilities.context != CapabilityContext.authenticated ||
        !capabilities.supportsTalk('message-expiration')) {
      protocolFailure(_requestCode, r'$.capabilities.message-expiration');
    }
    if (seconds < 0) {
      protocolFailure(_requestCode, r'$.body.seconds');
    }
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final int seconds;
  final String userAgent;

  String get httpMethod => 'POST';

  Map<String, String> get formBody =>
      UnmodifiableMapView({'seconds': seconds.toString()});

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => _roomUri(server, roomToken, 'message-expiration');

  @override
  String toString() => 'SetMessageExpirationRequest(seconds: $seconds)';
}
