import 'dart:collection';

import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';

/// Base path of the Talk ban API.
///
/// The ban endpoints do not live under `/room/{token}` like the rest of
/// conversation moderation: `BanController` declares
/// `#[ApiRoute(verb: ..., url: '/api/{apiVersion}/ban/{token}', requirements:
/// ['apiVersion' => '(v1)', 'token' => '[a-z0-9]{4,30}'])]` for all three
/// operations, so `v1` is the only version they exist in.
const String bansV1Path = '/ocs/v2.php/apps/spreed/api/v1/ban';

const String bansContractUserAgent =
    'com.nkshub.nextcloudtalk bans-contract/0.1';

/// `BanController::banActor` documents `@param string $internalNote Optional
/// internal note (max. 4000 characters)`.
const int banNoteMaximumLength = 4000;

const TalkProtocolErrorCode _requestCode =
    TalkProtocolErrorCode.invalidBansRequest;

/// The actor kinds the ban endpoint accepts.
///
/// `BanController::banActor` declares
/// `@param 'users'|'guests'|'emails'|'ip' $actorType Type of actor to ban, or
/// `ip` when banning a clients remote address`.
///
/// `ip` is deliberately not modelled: this contract bans a participant the
/// moderator picked out of the attendee list, and the attendee list never
/// carries a remote address to ban.
enum BannedActorType {
  users('users'),
  guests('guests'),
  emails('emails');

  const BannedActorType(this.wireValue);

  final String wireValue;
}

/// Maps an attendee's `actorType` onto the ban actor types the server
/// accepts, or `null` when this client must not offer a ban for it.
BannedActorType? bannedActorTypeFor(String actorType) {
  return switch (actorType) {
    'users' => BannedActorType.users,
    'guests' => BannedActorType.guests,
    'emails' => BannedActorType.emails,
    _ => null,
  };
}

void _validateUserAgent(String userAgent) {
  if (userAgent.isEmpty ||
      userAgent.length > 256 ||
      userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
    protocolFailure(_requestCode, r'$.headers.userAgent');
  }
}

Uri _banUri(ServerBase server, ConversationToken roomToken, [int? banId]) {
  final tail = banId == null ? '' : '/$banId';
  return server.uri.replace(
    path: '${server.basePath}$bansV1Path/${roomToken.value}$tail',
    queryParameters: const {'format': 'json'},
  );
}

/// Reads the list of bans on one conversation.
///
/// `GET /ocs/v2.php/apps/spreed/api/v1/ban/{token}`, from
/// `lib/Controller/BanController.php::listBans`, which carries
/// `Required capability: `ban-v1``, `#[PublicPage]`,
/// `#[RequireModeratorParticipant]` and returns
/// `DataResponse<Http::STATUS_OK, list<TalkBan>, array{}>`.
final class ListBansRequest {
  ListBansRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    this.userAgent = bansContractUserAgent,
  }) {
    _validateUserAgent(userAgent);
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final String userAgent;

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => _banUri(server, roomToken);

  @override
  String toString() => 'ListBansRequest()';
}

/// Bans one attendee from a conversation.
///
/// `POST /ocs/v2.php/apps/spreed/api/v1/ban/{token}` with `actorType`,
/// `actorId` and an optional `internalNote`, from
/// `lib/Controller/BanController.php::banActor`, which carries
/// `Required capability: `ban-v1``, `#[PublicPage]` and
/// `#[RequireModeratorParticipant]`. It answers `200: Ban successfully` with
/// a `TalkBan` object and `400: Actor information is invalid` with
/// `array{error: 'bannedActor'|'internalNote'|'moderator'|'self'|'room'}`.
///
/// The ban is not only a block on rejoining: `BanService::createBan` looks the
/// banned actor up in the room and calls
/// `$this->participantService->removeAttendee($room, $bannedParticipant,
/// AAttendeeRemovedEvent::REASON_REMOVED)`, so the attendee leaves the
/// conversation as part of the same call. The same method throws
/// `InvalidArgumentException('room')` unless the room is
/// `Room::TYPE_GROUP` or `Room::TYPE_PUBLIC`, which is why the client only
/// offers a ban in those two conversation types.
final class BanActorRequest {
  BanActorRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.actorType,
    required this.actorId,
    this.internalNote = '',
  }) : userAgent = bansContractUserAgent {
    if (actorId.isEmpty ||
        actorId.length > 4096 ||
        actorId.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f)) {
      protocolFailure(_requestCode, r'$.body.actorId');
    }
    if (internalNote.length > banNoteMaximumLength) {
      protocolFailure(_requestCode, r'$.body.internalNote');
    }
    _validateUserAgent(userAgent);
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final BannedActorType actorType;
  final String actorId;

  /// A moderator-visible reason. Empty means the server stores none.
  final String internalNote;

  final String userAgent;

  Map<String, String> get formBody => UnmodifiableMapView({
    'actorType': actorType.wireValue,
    'actorId': actorId,
    if (internalNote.isNotEmpty) 'internalNote': internalNote,
  });

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => _banUri(server, roomToken);

  /// Renders neither [actorId] nor [internalNote]: both name a real person
  /// and the note is a moderator's private remark about them.
  @override
  String toString() => 'BanActorRequest(actorType: ${actorType.name})';
}

/// Lifts one ban.
///
/// `DELETE /ocs/v2.php/apps/spreed/api/v1/ban/{token}/{banId}`, from
/// `lib/Controller/BanController.php::unbanActor`, which carries
/// `Required capability: `ban-v1``, `#[PublicPage]`,
/// `#[RequireModeratorParticipant]`, the route requirement
/// `'banId' => '[0-9]{1,64}'` and answers
/// `200: Unban successfully or not found` — so a ban that is already gone is
/// success, not an error.
final class UnbanActorRequest {
  UnbanActorRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.banId,
    this.userAgent = bansContractUserAgent,
  }) {
    if (banId < 0) {
      protocolFailure(_requestCode, r'$.path.banId');
    }
    _validateUserAgent(userAgent);
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final int banId;
  final String userAgent;

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => _banUri(server, roomToken, banId);

  @override
  String toString() => 'UnbanActorRequest(banId: $banId)';
}
