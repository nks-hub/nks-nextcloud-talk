import '../json_value.dart';
import '../protocol_exception.dart';

const TalkProtocolErrorCode _responseCode =
    TalkProtocolErrorCode.invalidParticipantsResponse;

/// Standard Nextcloud Talk `participantType` values. A server may return a
/// newer value this client does not know yet; [Participant.participantType]
/// always keeps the raw wire value, and [participantRoleFor] returns `null`
/// for anything outside this set instead of guessing.
enum ParticipantRole {
  owner,
  moderator,
  user,
  guest,
  userSelfJoined,
  guestModerator,
}

ParticipantRole? participantRoleFor(int participantType) {
  return switch (participantType) {
    1 => ParticipantRole.owner,
    2 => ParticipantRole.moderator,
    3 => ParticipantRole.user,
    4 => ParticipantRole.guest,
    5 => ParticipantRole.userSelfJoined,
    6 => ParticipantRole.guestModerator,
    _ => null,
  };
}

/// A single validated entry from the Talk v4 room participants endpoint.
/// `status`/`statusIcon`/`statusMessage` are only present when the request
/// asked for `includeStatus=true` and the server supports it, so they stay
/// nullable rather than defaulted.
final class Participant {
  Participant._({
    required this.attendeeId,
    required this.actorType,
    required this.actorId,
    required this.displayName,
    required this.participantType,
    required this.lastPing,
    required this.sessionIds,
    required this.permissions,
    required this.attendeePermissions,
    required this.inCall,
    required this.status,
    required this.statusIcon,
    required this.statusMessage,
    required this.wire,
  });

  final int attendeeId;
  final String actorType;
  final String actorId;
  final String displayName;
  final int participantType;
  final int lastPing;
  final List<String> sessionIds;
  final int permissions;
  final int attendeePermissions;
  final int inCall;
  final String? status;
  final String? statusIcon;
  final String? statusMessage;
  final Map<String, Object?> wire;

  ParticipantRole? get role => participantRoleFor(participantType);

  /// A live Talk session for this attendee is open in the room. This is a
  /// call/session-presence proxy, not the account-wide user status: use
  /// [status] instead when the server included it.
  bool get hasOpenSession => sessionIds.isNotEmpty;

  @override
  String toString() => 'Participant(<redacted>)';
}

Participant parseParticipant(Object? json, {required String path}) {
  final participant = requireObject(json, path: path, code: _responseCode);
  final attendeeId = requireInt(
    participant['attendeeId'],
    path: '$path.attendeeId',
    code: _responseCode,
    minimum: 0,
  );
  final actorType = requireString(
    participant['actorType'],
    path: '$path.actorType',
    code: _responseCode,
    minLength: 1,
    maxLength: 128,
  );
  final actorId = requireString(
    participant['actorId'],
    path: '$path.actorId',
    code: _responseCode,
    maxLength: 4096,
  );
  final displayName = requireString(
    participant['displayName'],
    path: '$path.displayName',
    code: _responseCode,
    maxLength: 4096,
  );
  final participantType = requireInt(
    participant['participantType'],
    path: '$path.participantType',
    code: _responseCode,
    minimum: 1,
  );
  final lastPing = requireInt(
    participant['lastPing'],
    path: '$path.lastPing',
    code: _responseCode,
    minimum: 0,
  );
  final sessionIdsRaw = requireList(
    participant['sessionIds'],
    path: '$path.sessionIds',
    code: _responseCode,
  );
  if (sessionIdsRaw.length > 64) {
    protocolFailure(_responseCode, '$path.sessionIds');
  }
  final sessionIds = <String>[
    for (var index = 0; index < sessionIdsRaw.length; index++)
      requireString(
        sessionIdsRaw[index],
        path: '$path.sessionIds[$index]',
        code: _responseCode,
        minLength: 1,
        maxLength: 512,
      ),
  ];
  final permissions = requireInt(
    participant['permissions'],
    path: '$path.permissions',
    code: _responseCode,
    minimum: 0,
  );
  final attendeePermissions = requireInt(
    participant['attendeePermissions'],
    path: '$path.attendeePermissions',
    code: _responseCode,
    minimum: 0,
  );
  final inCall = requireInt(
    participant['inCall'],
    path: '$path.inCall',
    code: _responseCode,
    minimum: 0,
  );
  final status = _optionalString(participant, 'status', path, maxLength: 32);
  final statusIcon = _optionalString(
    participant,
    'statusIcon',
    path,
    maxLength: 32,
  );
  final statusMessage = _optionalString(
    participant,
    'statusMessage',
    path,
    maxLength: 4096,
  );

  return Participant._(
    attendeeId: attendeeId,
    actorType: actorType,
    actorId: actorId,
    displayName: displayName,
    participantType: participantType,
    lastPing: lastPing,
    sessionIds: List<String>.unmodifiable(sessionIds),
    permissions: permissions,
    attendeePermissions: attendeePermissions,
    inCall: inCall,
    status: status,
    statusIcon: statusIcon,
    statusMessage: statusMessage,
    wire: participant,
  );
}

String? _optionalString(
  Map<String, Object?> object,
  String key,
  String parentPath, {
  int? maxLength,
}) {
  if (!object.containsKey(key) || object[key] == null) {
    return null;
  }
  return requireString(
    object[key],
    path: '$parentPath.$key',
    code: _responseCode,
    maxLength: maxLength,
  );
}

