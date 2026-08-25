import 'dart:collection';

import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';

const String participantsV4Path = '/ocs/v2.php/apps/spreed/api/v4/room';
const String participantsContractUserAgent =
    'com.nkshub.nextcloudtalk participants-contract/0.1';

const TalkProtocolErrorCode _requestCode =
    TalkProtocolErrorCode.invalidParticipantsRequest;

void _validateUserAgent(String userAgent) {
  if (userAgent.isEmpty ||
      userAgent.length > 256 ||
      userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
    protocolFailure(_requestCode, r'$.headers.userAgent');
  }
}

/// Request for the participant list of a single room. Read-only: this
/// contract never issues membership or moderation changes.
final class ParticipantsRequest {
  ParticipantsRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    this.includeStatus = true,
    this.userAgent = participantsContractUserAgent,
  }) {
    _validateUserAgent(userAgent);
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final bool includeStatus;
  final String userAgent;

  Map<String, String> get queryParameters => UnmodifiableMapView({
    'format': 'json',
    'includeStatus': includeStatus.toString(),
  });

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => server.uri.replace(
    path: '${server.basePath}$participantsV4Path/'
        '${roomToken.value}/participants',
    queryParameters: queryParameters,
  );

  @override
  String toString() =>
      'ParticipantsRequest(includeStatus: $includeStatus)';
}

/// The three moderation changes this contract can make to a single attendee.
/// All of them are moderator-only on the server and all of them address the
/// attendee by `attendeeId`.
///
/// Contract source: spreed `docs/participant.md`, sections "Promote a user or
/// guest to moderator", "Demote a moderator to user or guest" and "Delete an
/// attendee by id from a conversation".
enum ParticipantModerationAction {
  /// `POST .../room/{token}/moderators`. The server answers 400 unless the
  /// target is a normal user (3), a guest (4) or a self-joined user (5).
  promote('moderators', 'POST'),

  /// `DELETE .../room/{token}/moderators`. The server answers 400 unless the
  /// target is a moderator (2) or guest moderator (6), and 403 when a
  /// moderator tries to demote themselves.
  demote('moderators', 'DELETE'),

  /// `DELETE .../room/{token}/attendees`. The server answers 400 when the
  /// target is a moderator or owner, or when no other moderator would be
  /// left, and 403 when the target is an owner.
  remove('attendees', 'DELETE');

  const ParticipantModerationAction(this.pathSegment, this.httpMethod);

  final String pathSegment;
  final String httpMethod;
}

/// Promotes, demotes or removes one attendee of a room. Moderator-only on the
/// server; the client must not offer these actions to a plain participant.
///
/// `attendeeId` travels in the query string rather than a form body, matching
/// what the upstream Talk Android client sends for both endpoints
/// (`removeAttendeeFromConversation`, `promoteAttendeeToModerator` and
/// `demoteAttendeeFromModerator` in `NcApi.java` all declare it as a
/// `@Query`).
///
/// The optional `participantType` parameter that promotes or demotes across
/// the owner level is deliberately not modelled: it needs the server's
/// `promote-demote-owner` capability, and this contract only toggles the
/// moderator level.
final class ParticipantModerationRequest {
  ParticipantModerationRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.attendeeId,
    required this.action,
    this.userAgent = participantsContractUserAgent,
  }) {
    if (attendeeId < 0) {
      protocolFailure(_requestCode, r'$.query.attendeeId');
    }
    _validateUserAgent(userAgent);
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final int attendeeId;
  final ParticipantModerationAction action;
  final String userAgent;

  String get httpMethod => action.httpMethod;

  Map<String, String> get queryParameters => UnmodifiableMapView({
    'format': 'json',
    'attendeeId': attendeeId.toString(),
  });

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => server.uri.replace(
    path:
        '${server.basePath}$participantsV4Path/'
        '${roomToken.value}/${action.pathSegment}',
    queryParameters: queryParameters,
  );

  @override
  String toString() =>
      'ParticipantModerationRequest(action: ${action.name}, '
      'attendeeId: $attendeeId)';
}
