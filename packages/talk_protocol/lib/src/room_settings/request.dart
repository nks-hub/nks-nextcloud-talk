import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../bootstrap/capabilities.dart';
import '../conversations/request.dart' show conversationV4Path;
import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';

part 'request_call_notifications.dart';

const String roomSettingsContractUserAgent =
    'com.nkshub.nextcloudtalk room-settings-contract/0.1';

const int roomNameMaximumLength = 200;
const int roomDescriptionMaximumLength = 2000;
const int roomPasswordMaximumLength = 255;
const int roomAvatarEmojiMaximumLength = 32;

/// Year 5138 in UNIX seconds. A lobby timer beyond this is a millisecond
/// value that leaked in, not a date anyone meant to pick.
const int _maximumLobbyTimerSeconds = 99999999999;

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
    required CapabilitySnapshot capabilities,
    required this.archived,
    this.userAgent = roomSettingsContractUserAgent,
  }) {
    if (capabilities.context != CapabilityContext.authenticated ||
        !capabilities.supportsTalk('archived-conversations-v2')) {
      protocolFailure(
        _requestCode,
        r'$.capabilities.archived-conversations-v2',
      );
    }
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

// ---------------------------------------------------------------------------
// Conversation administration
//
// Six moderator-only changes that share one request shape and one response
// family, because the server answers all of them with the same status codes.
// ---------------------------------------------------------------------------

const String conversationV1Path = '/ocs/v2.php/apps/spreed/api/v1/room';

/// Webinar lobby states from Talk `docs/constants.md`, section "Webinar lobby
/// states": `0 No lobby`, `1 Lobby for non moderators`.
enum RoomLobbyState {
  none(0),
  moderatorsOnly(1);

  const RoomLobbyState(this.wireValue);

  final int wireValue;
}

/// Read-only states from Talk `docs/constants.md`, section "Read-only states":
/// `0 Read-write`, `1 Read-only`.
enum RoomReadOnlyState {
  readWrite(0),
  readOnly(1);

  const RoomReadOnlyState(this.wireValue);

  final int wireValue;
}

final RegExp _hexColorPattern = RegExp(r'^[0-9A-Fa-f]{6}$');

/// 128 bits of hex from a cryptographic source. Used as a multipart boundary,
/// which must be unguessable so nothing in the uploaded bytes can be made to
/// look like the end of the part.
String _randomBoundary() {
  final random = Random.secure();
  final buffer = StringBuffer('nkstalk');
  for (var index = 0; index < 32; index++) {
    buffer.write(random.nextInt(16).toRadixString(16));
  }
  return buffer.toString();
}

Uri _roomV1Uri(ServerBase server, ConversationToken roomToken, String suffix) {
  return server.uri.replace(
    path: '${server.basePath}$conversationV1Path/${roomToken.value}/$suffix',
    queryParameters: const {'format': 'json'},
  );
}

/// One moderator-only administration change to a conversation.
///
/// Every subclass targets an endpoint that answers `200` on success, `400`
/// when the conversation type or the value does not allow the change, `403`
/// for a non-moderator and `404` for an unknown room, so they all decode
/// through `decodeRoomAdministrationResponse`.
sealed class RoomAdministrationRequest {
  const RoomAdministrationRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.userAgent,
  });

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final String userAgent;

  String get httpMethod;

  Uri get uri;

  /// Form fields for the request body, or `null` when the endpoint takes none.
  Map<String, String>? get formBody;

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});
}

/// Turns a group conversation into a public one or back again.
///
/// `POST` and `DELETE /ocs/v2.php/apps/spreed/api/v4/room/{token}/public`,
/// from Talk `docs/conversation.md`, sections "Allow guests in a conversation
/// (public conversation)" and "Disallow guests in a conversation (group
/// conversation)". No capability governs the toggle itself; the server
/// answers `400` when the conversation is not a group conversation (POST) or
/// not a public one (DELETE), `403` for a non-moderator and `404` for an
/// unknown room.
///
/// The optional `password` field the POST accepts is deliberately not
/// modelled: `docs/conversation.md` marks it "only available with
/// `conversation-creation-password` capability", and a password is set
/// through [SetRoomPasswordRequest] instead, which needs no capability.
final class SetRoomPublicRequest extends RoomAdministrationRequest {
  SetRoomPublicRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    required this.public,
    super.userAgent = roomSettingsContractUserAgent,
  }) {
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final bool public;

  @override
  String get httpMethod => public ? 'POST' : 'DELETE';

  @override
  Map<String, String>? get formBody => null;

  @override
  Uri get uri => _roomUri(server, roomToken, 'public');

  @override
  String toString() => 'SetRoomPublicRequest(public: $public)';
}

/// Sets or clears the password of a public conversation.
///
/// `PUT /ocs/v2.php/apps/spreed/api/v4/room/{token}/password` with a single
/// `password` form field, from Talk `docs/conversation.md`, section "Set
/// password for a conversation". No capability governs it. The server answers
/// `400` when the new password violates the instance password policy — and
/// then carries a translated explanation in `ocs.data.message`, which
/// `RoomAdministrationRejected.message` surfaces — `403` for a non-moderator
/// or a non-public conversation, and `404` for an unknown room.
///
/// Clearing the password is an empty `password` value. That is not in the
/// documentation, but it is what the official web client sends: in
/// `src/components/ConversationSettings/LinkShareSettings.vue` the
/// "disable the password protection for the current conversation" path calls
/// `this.setConversationPassword('')`.
///
/// The password is a secret. It appears only in [formBody]; [toString] never
/// renders it, and neither does any response in this family.
final class SetRoomPasswordRequest extends RoomAdministrationRequest {
  SetRoomPasswordRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    required this.password,
    super.userAgent = roomSettingsContractUserAgent,
  }) {
    if (password.length > roomPasswordMaximumLength ||
        _hasControlCharacter(password)) {
      protocolFailure(_requestCode, r'$.body.password');
    }
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  /// The new password, or the empty string to remove password protection.
  final String password;

  bool get clearsPassword => password.isEmpty;

  @override
  String get httpMethod => 'PUT';

  @override
  Map<String, String>? get formBody =>
      UnmodifiableMapView({'password': password});

  @override
  Uri get uri => _roomUri(server, roomToken, 'password');

  /// Never renders [password]: a diagnostic string must not leak the secret.
  @override
  String toString() =>
      'SetRoomPasswordRequest(clearsPassword: $clearsPassword)';
}

/// Enables or disables the lobby of a group or public conversation, optionally
/// with the moment it lifts itself.
///
/// `PUT /ocs/v2.php/apps/spreed/api/v4/room/{token}/webinar/lobby` with
/// `state` and `timer`, from Talk `docs/webinar.md`, section "Set lobby for a
/// conversation". Requires the server's `webinary-lobby` capability
/// (`docs/capabilities.md`, Talk 7.0). The server answers `400` when the
/// conversation type does not support a lobby or the timestamp is invalid,
/// `403` for a non-moderator and `404` for an unknown room.
final class SetRoomLobbyRequest extends RoomAdministrationRequest {
  SetRoomLobbyRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    required this.state,
    this.timerSecondsSinceEpoch,
    super.userAgent = roomSettingsContractUserAgent,
  }) {
    final timer = timerSecondsSinceEpoch;
    if (timer != null) {
      if (timer <= 0 || timer > _maximumLobbyTimerSeconds) {
        protocolFailure(_requestCode, r'$.body.timer');
      }
      // A timer only means anything while the lobby is on; sending one with
      // state 0 would ask the server to schedule the end of nothing.
      if (state == RoomLobbyState.none) {
        protocolFailure(_requestCode, r'$.body.timer');
      }
    }
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final RoomLobbyState state;

  /// UNIX timestamp in seconds at which the lobby lifts itself, or `null` for
  /// a lobby that stays on until a moderator turns it off.
  final int? timerSecondsSinceEpoch;

  @override
  String get httpMethod => 'PUT';

  @override
  Map<String, String>? get formBody => UnmodifiableMapView({
    'state': state.wireValue.toString(),
    'timer': ?timerSecondsSinceEpoch?.toString(),
  });

  @override
  Uri get uri => _roomUri(server, roomToken, 'webinar/lobby');

  @override
  String toString() =>
      'SetRoomLobbyRequest(state: ${state.name}, '
      'timed: ${timerSecondsSinceEpoch != null})';
}

/// Puts a group or public conversation into read-only mode or back into
/// read-write.
///
/// `PUT /ocs/v2.php/apps/spreed/api/v4/room/{token}/read-only` with a `state`
/// form field, from Talk `docs/conversation.md`, section "Set read-only for a
/// conversation". Requires the server's `read-only-rooms` capability
/// (`docs/capabilities.md`, Talk 6.0). The server answers `400` when the
/// conversation type does not support read-only, `403` for a non-moderator
/// and `404` for an unknown room.
final class SetRoomReadOnlyRequest extends RoomAdministrationRequest {
  SetRoomReadOnlyRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    required this.state,
    super.userAgent = roomSettingsContractUserAgent,
  }) {
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final RoomReadOnlyState state;

  @override
  String get httpMethod => 'PUT';

  @override
  Map<String, String>? get formBody =>
      UnmodifiableMapView({'state': state.wireValue.toString()});

  @override
  Uri get uri => _roomUri(server, roomToken, 'read-only');

  @override
  String toString() => 'SetRoomReadOnlyRequest(state: ${state.name})';
}

/// Sets a single emoji, with an optional background colour, as the
/// conversation avatar.
///
/// `POST /ocs/v2.php/apps/spreed/api/v1/room/{token}/avatar/emoji`, from Talk
/// `docs/avatar.md`, section "Set emoji as avatar". Requires the server's
/// `avatar` capability (`docs/capabilities.md`, Talk 17). The server answers
/// `400` for a one-to-one conversation, an `emoji` that is not a single
/// emoji, or a `color` outside the documented pattern; `403` when the caller
/// is not a moderator, owner or guest moderator; and `404` for an unknown
/// room.
///
/// `color` is documented as a "HEX color code (6 times 0-9A-F) without the
/// leading `#` character (omit to fallback to the default bright/dark mode
/// icon background color)", which is exactly what [hexColor] validates.
final class SetRoomEmojiAvatarRequest extends RoomAdministrationRequest {
  SetRoomEmojiAvatarRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    required this.emoji,
    this.hexColor,
    super.userAgent = roomSettingsContractUserAgent,
  }) {
    // The server is the authority on "a single emoji"; this only rejects the
    // shapes that are certainly wrong, so an unusual but valid grapheme
    // cluster (skin tone, ZWJ sequence, flag) still reaches it.
    if (emoji.isEmpty ||
        emoji.length > roomAvatarEmojiMaximumLength ||
        _hasControlCharacter(emoji)) {
      protocolFailure(_requestCode, r'$.body.emoji');
    }
    final color = hexColor;
    if (color != null && !_hexColorPattern.hasMatch(color)) {
      protocolFailure(_requestCode, r'$.body.color');
    }
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final String emoji;

  /// Six hex digits without a leading `#`, or `null` for the server default.
  final String? hexColor;

  @override
  String get httpMethod => 'POST';

  @override
  Map<String, String>? get formBody => UnmodifiableMapView({
    'emoji': emoji,
    'color': ?hexColor,
  });

  @override
  Uri get uri => _roomV1Uri(server, roomToken, 'avatar/emoji');

  @override
  String toString() =>
      'SetRoomEmojiAvatarRequest(colored: ${hexColor != null})';
}

/// The image types Talk `docs/avatar.md` accepts for a conversation avatar:
/// "Only accept images with mimetype equal to PNG or JPEG and need to be
/// squared image."
const Set<String> roomAvatarImageTypes = {'image/png', 'image/jpeg'};

/// The largest avatar this client will read into memory before uploading.
///
/// Talk documents "file is too big" as one of the `400` refusals but does not
/// publish the limit, so this is a client-side memory bound, not the server's
/// rule. Anything the server dislikes still comes back as a `400` with a
/// translated `message`.
const int roomAvatarMaximumBytes = 8 * 1024 * 1024;

/// Uploads an image as the conversation avatar.
///
/// `POST /ocs/v2.php/apps/spreed/api/v1/room/{token}/avatar` as
/// `multipart/form-data` with a single `file` part, from Talk
/// `docs/avatar.md`, section "Set conversations avatar", which documents the
/// field as "Blob of image in a multipart/form-data request. Only accept
/// images with mimetype equal to PNG or JPEG and need to be squared image."
/// Requires the server's `avatar` capability (`docs/capabilities.md`, Talk
/// 17).
///
/// The server answers `400` "When: is one-to-one, no image, file is too big,
/// invalid mimetype or resource, isn't square, unknown error" and carries an
/// "error in user language" in `message`, which this client shows verbatim
/// rather than second-guessing. `403` is a caller who is not a moderator,
/// owner or guest moderator; `404` an unknown room.
///
/// Squareness is deliberately not checked here: it needs the image decoded,
/// and the server already refuses a non-square upload with an explanation.
final class SetRoomAvatarRequest extends RoomAdministrationRequest {
  SetRoomAvatarRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    required this.imageBytes,
    required this.contentType,
    required this.fileName,
    super.userAgent = roomSettingsContractUserAgent,
  }) {
    if (imageBytes.isEmpty || imageBytes.length > roomAvatarMaximumBytes) {
      protocolFailure(_requestCode, r'$.body.file');
    }
    if (!roomAvatarImageTypes.contains(contentType)) {
      protocolFailure(_requestCode, r'$.body.file.contentType');
    }
    if (fileName.isEmpty ||
        fileName.length > 255 ||
        _hasControlCharacter(fileName) ||
        fileName.contains('/') ||
        fileName.contains(r'\') ||
        fileName.contains('"')) {
      protocolFailure(_requestCode, r'$.body.file.fileName');
    }
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final List<int> imageBytes;

  /// `image/png` or `image/jpeg`; nothing else reaches the wire.
  final String contentType;

  /// The multipart part's file name. Never a path: the constructor refuses
  /// separators and quotes so it cannot break out of the part header.
  final String fileName;

  /// The multipart field name Talk reads the blob from.
  static const String fileField = 'file';

  /// A per-request boundary from a cryptographic source, so a crafted image
  /// cannot contain a boundary an attacker predicted and split the body.
  late final String _boundary = _randomBoundary();

  /// The `Content-Type` header that goes with [multipartBody].
  String get multipartContentType =>
      'multipart/form-data; boundary=$_boundary';

  /// The encoded `multipart/form-data` body carrying [imageBytes] as the
  /// single `file` part.
  ///
  /// Hand-encoded rather than delegated, so the wire format this contract
  /// promises is the one that is actually sent and can be asserted on.
  Uint8List get multipartBody {
    final head = utf8.encode(
      '--$_boundary\r\n'
      'Content-Disposition: form-data; name="$fileField"; '
      'filename="$fileName"\r\n'
      'Content-Type: $contentType\r\n'
      '\r\n',
    );
    final tail = utf8.encode('\r\n--$_boundary--\r\n');
    final body = Uint8List(head.length + imageBytes.length + tail.length);
    body.setAll(0, head);
    body.setAll(head.length, imageBytes);
    body.setAll(head.length + imageBytes.length, tail);
    return body;
  }

  @override
  String get httpMethod => 'POST';

  /// The payload is multipart, not form fields; the transport sends
  /// [multipartBody] instead.
  @override
  Map<String, String>? get formBody => null;

  @override
  Map<String, String> get headers => UnmodifiableMapView({
    ...super.headers,
    'Content-Type': multipartContentType,
  });

  @override
  Uri get uri => _roomV1Uri(server, roomToken, 'avatar');

  /// Renders neither the bytes nor the file name, which comes from the user's
  /// own device and can carry personal detail.
  @override
  String toString() =>
      'SetRoomAvatarRequest(contentType: $contentType, '
      'bytes: ${imageBytes.length})';
}

/// Removes a conversation's custom avatar, restoring the generated one.
///
/// `DELETE /ocs/v2.php/apps/spreed/api/v1/room/{token}/avatar`, from Talk
/// `docs/avatar.md`, section "Delete conversations avatar". Requires the
/// server's `avatar` capability (`docs/capabilities.md`, Talk 17). The server
/// answers `403` when the caller is not a moderator, owner or guest
/// moderator, and `404` for an unknown room.
///
/// That same section notes: "To determine if the delete option should be
/// presented to the user, it's recommended to check the `isCustomAvatar`
/// property", which is what gates the action in the UI.
final class DeleteRoomAvatarRequest extends RoomAdministrationRequest {
  DeleteRoomAvatarRequest({
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
  Uri get uri => _roomV1Uri(server, roomToken, 'avatar');

  @override
  String toString() => 'DeleteRoomAvatarRequest()';
}
