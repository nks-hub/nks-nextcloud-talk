part of 'request.dart';

// ---------------------------------------------------------------------------
// Breakout rooms — Talk `docs/breakout-rooms.md`, API v1, capability
// `breakout-rooms-v1`. Every call is moderator-only on the parent
// conversation except the assistance request, which any participant of a
// breakout room may make. The endpoints answer with the refreshed parent
// (or target) conversation, the broadcast with 201 and the created messages —
// which `decodeRoomAdministrationResponse` reports as a success without a room.

const String breakoutRoomsV1Path =
    '/ocs/v2.php/apps/spreed/api/v1/breakout-rooms';
const int breakoutRoomsMinimum = 1;
const int breakoutRoomsMaximum = 20;
const int breakoutBroadcastMaximumLength = 32000;

Uri _breakoutUri(
  ServerBase server,
  ConversationToken roomToken, [
  String? suffix,
]) {
  final tail = suffix == null ? '' : '/$suffix';
  return server.uri.replace(
    path: '${server.basePath}$breakoutRoomsV1Path/${roomToken.value}$tail',
    queryParameters: const {'format': 'json'},
  );
}

/// How attendees are distributed over the breakout rooms.
enum BreakoutRoomMode {
  /// The server spreads the attendees evenly.
  automatic(1),

  /// The moderator hands over an attendee map.
  manual(2),

  /// Attendees pick a room themselves.
  free(3);

  const BreakoutRoomMode(this.wireValue);

  final int wireValue;
}

/// `POST /breakout-rooms/{token}` — creates the breakout rooms of a group
/// conversation. `amount` is 1–20; `attendeeMap` is the JSON map of
/// attendee id to room index that the manual and free modes take, and is
/// sent as `[]` when there is none, which is what the automatic mode wants.
final class ConfigureBreakoutRoomsRequest extends RoomAdministrationRequest {
  ConfigureBreakoutRoomsRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    required this.mode,
    required this.amount,
    this.attendeeMap,
    super.userAgent = roomSettingsContractUserAgent,
  }) {
    if (amount < breakoutRoomsMinimum || amount > breakoutRoomsMaximum) {
      protocolFailure(_requestCode, r'$.body.amount');
    }
    final map = attendeeMap;
    if (map != null && (map.isEmpty || map.length > 64 * 1024)) {
      protocolFailure(_requestCode, r'$.body.attendeeMap');
    }
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final BreakoutRoomMode mode;
  final int amount;
  final String? attendeeMap;

  @override
  String get httpMethod => 'POST';

  @override
  Map<String, String>? get formBody => UnmodifiableMapView({
    'mode': mode.wireValue.toString(),
    'amount': amount.toString(),
    'attendeeMap': attendeeMap ?? '[]',
  });

  @override
  Uri get uri => _breakoutUri(server, roomToken);

  @override
  String toString() =>
      'ConfigureBreakoutRoomsRequest(mode: ${mode.name}, amount: $amount)';
}

/// `DELETE /breakout-rooms/{token}` — removes the breakout rooms again.
final class RemoveBreakoutRoomsRequest extends RoomAdministrationRequest {
  RemoveBreakoutRoomsRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    super.userAgent = roomSettingsContractUserAgent,
  }) {
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  @override
  String get httpMethod => 'DELETE';

  @override
  Map<String, String>? get formBody => null;

  @override
  Uri get uri => _breakoutUri(server, roomToken);

  @override
  String toString() => 'RemoveBreakoutRoomsRequest()';
}

/// `POST` and `DELETE /breakout-rooms/{token}/rooms` — starts the breakout
/// session (moves the attendees into their rooms) or ends it.
final class RunBreakoutRoomsRequest extends RoomAdministrationRequest {
  RunBreakoutRoomsRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    required this.start,
    super.userAgent = roomSettingsContractUserAgent,
  }) {
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final bool start;

  @override
  String get httpMethod => start ? 'POST' : 'DELETE';

  @override
  Map<String, String>? get formBody => null;

  @override
  Uri get uri => _breakoutUri(server, roomToken, 'rooms');

  @override
  String toString() => 'RunBreakoutRoomsRequest(start: $start)';
}

/// `POST /breakout-rooms/{token}/broadcast` — posts one chat message into
/// every breakout room. Answers 201 with the messages, not a conversation.
final class BroadcastBreakoutRoomsRequest extends RoomAdministrationRequest {
  BroadcastBreakoutRoomsRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    required this.message,
    super.userAgent = roomSettingsContractUserAgent,
  }) {
    if (message.trim().isEmpty ||
        message.length > breakoutBroadcastMaximumLength) {
      protocolFailure(_requestCode, r'$.body.message');
    }
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final String message;

  @override
  String get httpMethod => 'POST';

  @override
  Map<String, String>? get formBody =>
      UnmodifiableMapView({'message': message});

  @override
  Uri get uri => _breakoutUri(server, roomToken, 'broadcast');

  @override
  String toString() =>
      'BroadcastBreakoutRoomsRequest(length: ${message.length})';
}

/// `POST` and `DELETE /breakout-rooms/{token}/request-assistance` — a
/// participant of a breakout room raises (or withdraws) a request for a
/// moderator to come over. `roomToken` is the BREAKOUT room's token.
final class BreakoutAssistanceRequest extends RoomAdministrationRequest {
  BreakoutAssistanceRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    required this.requested,
    super.userAgent = roomSettingsContractUserAgent,
  }) {
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final bool requested;

  @override
  String get httpMethod => requested ? 'POST' : 'DELETE';

  @override
  Map<String, String>? get formBody => null;

  @override
  Uri get uri => _breakoutUri(server, roomToken, 'request-assistance');

  @override
  String toString() => 'BreakoutAssistanceRequest(requested: $requested)';
}

/// `POST /breakout-rooms/{token}/switch` — moves this participant to another
/// breakout room of the same parent (`roomToken` is the parent's token).
final class SwitchBreakoutRoomRequest extends RoomAdministrationRequest {
  SwitchBreakoutRoomRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    required this.target,
    super.userAgent = roomSettingsContractUserAgent,
  }) {
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final ConversationToken target;

  @override
  String get httpMethod => 'POST';

  @override
  Map<String, String>? get formBody =>
      UnmodifiableMapView({'target': target.value});

  @override
  Uri get uri => _breakoutUri(server, roomToken, 'switch');

  @override
  String toString() => 'SwitchBreakoutRoomRequest()';
}

/// `GET /room/{token}/breakout-rooms` (room API v4; v1 answers OCS 998 on
/// Talk 22, measured 5 September 2026) — the breakout rooms of a
/// parent conversation as full conversation objects. This is how a moderator
/// learns which room asked for assistance: the request marks the BREAKOUT
/// room's `breakoutRoomStatus` (2), never the parent's.
final class BreakoutRoomsListRequest {
  BreakoutRoomsListRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    this.userAgent = roomSettingsContractUserAgent,
  }) {
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final String userAgent;

  String get httpMethod => 'GET';

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => server.uri.replace(
    path:
        '${server.basePath}$conversationV4Path/${roomToken.value}/breakout-rooms',
    queryParameters: const {'format': 'json'},
  );

  @override
  String toString() => 'BreakoutRoomsListRequest()';
}
