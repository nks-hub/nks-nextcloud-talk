import 'dart:collection';

import '../conversations/request.dart' show conversationV4Path;
import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';

const String roomSettingsContractUserAgent =
    'com.nkshub.nextcloudtalk room-settings-contract/0.1';

const int roomNameMaximumLength = 200;
const int roomDescriptionMaximumLength = 2000;

const TalkProtocolErrorCode _requestCode =
    TalkProtocolErrorCode.invalidRoomSettingsRequest;

/// Notification levels a participant can pick for a single conversation.
/// The server also reports `0` (default, follow the global preference), but
/// that value is not something this contract offers to set explicitly.
enum RoomNotificationLevel {
  always(1),
  mentions(2),
  never(3);

  const RoomNotificationLevel(this.wireValue);

  final int wireValue;
}

void _validateUserAgent(String userAgent, String path) {
  if (userAgent.isEmpty ||
      userAgent.length > 256 ||
      userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
    protocolFailure(_requestCode, path);
  }
}

bool _hasControlCharacter(String value) =>
    value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);

Uri _roomUri(ServerBase server, ConversationToken roomToken, [String? suffix]) {
  final tail = suffix == null ? '' : '/$suffix';
  return server.uri.replace(
    path: '${server.basePath}$conversationV4Path/${roomToken.value}$tail',
    queryParameters: const {'format': 'json'},
  );
}

/// Renames a conversation. Moderator-only on the server; the client must not
/// offer this action to a plain participant.
final class UpdateRoomNameRequest {
  UpdateRoomNameRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.name,
    this.userAgent = roomSettingsContractUserAgent,
  }) {
    final trimmed = name.trim();
    if (trimmed.isEmpty ||
        trimmed.length > roomNameMaximumLength ||
        _hasControlCharacter(trimmed)) {
      protocolFailure(_requestCode, r'$.body.roomName');
    }
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final String name;
  final String userAgent;

  Map<String, String> get formBody =>
      UnmodifiableMapView({'roomName': name.trim()});

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => _roomUri(server, roomToken);

  @override
  String toString() => 'UpdateRoomNameRequest(<redacted>)';
}

/// Changes a conversation's description. Moderator-only on the server.
final class UpdateRoomDescriptionRequest {
  UpdateRoomDescriptionRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.description,
    this.userAgent = roomSettingsContractUserAgent,
  }) {
    if (description.length > roomDescriptionMaximumLength) {
      protocolFailure(_requestCode, r'$.body.description');
    }
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final String description;
  final String userAgent;

  Map<String, String> get formBody =>
      UnmodifiableMapView({'description': description});

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => _roomUri(server, roomToken, 'description');

  @override
  String toString() => 'UpdateRoomDescriptionRequest(<redacted>)';
}

/// Sets the caller's own per-conversation notification level. This is a
/// personal preference: any participant may set it for themselves.
final class UpdateNotificationLevelRequest {
  UpdateNotificationLevelRequest({
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
  final RoomNotificationLevel level;
  final String userAgent;

  Map<String, String> get formBody =>
      UnmodifiableMapView({'level': level.wireValue.toString()});

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => _roomUri(server, roomToken, 'notify');

  @override
  String toString() =>
      'UpdateNotificationLevelRequest(level: ${level.name})';
}

/// Marks or unmarks a conversation as one of the caller's favorites. This is
/// a personal preference: any participant may set it for themselves.
final class SetFavoriteRequest {
  SetFavoriteRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.favorite,
    this.userAgent = roomSettingsContractUserAgent,
  }) {
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final bool favorite;
  final String userAgent;

  /// `POST` to add the conversation to favorites, `DELETE` to remove it.
  String get httpMethod => favorite ? 'POST' : 'DELETE';

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => _roomUri(server, roomToken, 'favorite');

  @override
  String toString() => 'SetFavoriteRequest(favorite: $favorite)';
}

/// Archives or unarchives a conversation for the caller. This is a personal
/// preference: any participant may set it for themselves.
final class SetArchivedRequest {
  SetArchivedRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.archived,
    this.userAgent = roomSettingsContractUserAgent,
  }) {
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final bool archived;
  final String userAgent;

  /// `POST` to archive the conversation, `DELETE` to unarchive it.
  String get httpMethod => archived ? 'POST' : 'DELETE';

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => _roomUri(server, roomToken, 'archive');

  @override
  String toString() => 'SetArchivedRequest(archived: $archived)';
}

/// Deletes a conversation for everyone.
///
/// `DELETE /ocs/v2.php/apps/spreed/api/v4/room/{token}`, verified against
/// Talk `docs/conversation.md` ("Delete a conversation") on master
/// `f2958bb25be6604240c58a3faf9a2033a30d20e5` and stable
/// `f9b9e9474e3621b47f74bf8890c4642cb49eed97`, where the controller carries
/// `#[RequireModeratorParticipant]` and answers `400` for a one-to-one
/// conversation, `403` for a non-moderator and `404` for an unknown room.
///
/// No Talk capability flag governs this operation; `docs/capabilities.md` at
/// both revisions only lists message-level delete features. The documented
/// eligibility signal is the room's own `canDeleteConversation` field
/// ("Flag if the user can delete the conversation for everyone (not possible
/// without moderator permissions or in one-to-one conversations)"), so that
/// is what gates admission here. The server stays the authority; this only
/// stops a request that is guaranteed to be refused.
final class DeleteRoomRequest {
  DeleteRoomRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required bool canDeleteConversation,
    this.userAgent = roomSettingsContractUserAgent,
  }) {
    if (!canDeleteConversation) {
      protocolFailure(_requestCode, r'$.room.canDeleteConversation');
    }
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final String userAgent;

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => _roomUri(server, roomToken);

  @override
  String toString() => 'DeleteRoomRequest(<redacted>)';
}

/// Removes the caller from a conversation. Irreversible from the client's
/// point of view: rejoining a non-listable conversation needs a new invite.
final class LeaveRoomRequest {
  LeaveRoomRequest({
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

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => _roomUri(server, roomToken, 'participants/self');

  @override
  String toString() => 'LeaveRoomRequest(<redacted>)';
}
