part of 'request.dart';

/// Per-participant call notification levels documented by Talk.
enum RoomCallNotificationLevel {
  off(0),
  on(1);

  const RoomCallNotificationLevel(this.wireValue);

  final int wireValue;
}

/// Enables or disables call notifications for the current participant.
///
/// Evidence: spreed `f2958bb25be6604240c58a3faf9a2033a30d20e5`,
/// `RoomController::setNotificationCalls` and `docs/conversation.md`.
final class UpdateCallNotificationLevelRequest {
  UpdateCallNotificationLevelRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.level,
    this.userAgent = roomSettingsContractUserAgent,
  }) {
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final RoomCallNotificationLevel level;
  final String userAgent;

  Map<String, String> get formBody =>
      UnmodifiableMapView({'level': level.wireValue.toString()});

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => _roomUri(server, roomToken, 'notify-calls');

  @override
  String toString() =>
      'UpdateCallNotificationLevelRequest(level: ${level.name})';
}
