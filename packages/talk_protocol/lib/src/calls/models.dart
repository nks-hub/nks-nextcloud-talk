import '../conversations/identifiers.dart';
import '../conversations/models.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import '../server_base.dart';

abstract final class CallFlag {
  static const int disconnected = 0;
  static const int inCall = 1;
  static const int audio = 2;
  static const int video = 4;
  static const int phone = 8;
  static const int all = inCall | audio | video | phone;
}

abstract final class CallPermission {
  static const int start = 2;
  static const int join = 4;
  static const int ignoreLobby = 8;
  static const int audio = 16;
  static const int video = 32;
  static const int screen = 64;
}

abstract final class CallParticipantType {
  static const int owner = 1;
  static const int moderator = 2;
  static const int guestModerator = 6;
}

final class CallInCallFlags {
  CallInCallFlags._(this.value);

  factory CallInCallFlags.parse(
    Object? value, {
    String path = r'$.flags',
    bool requireJoined = false,
  }) {
    final parsed = requireInt(
      value,
      path: path,
      code: TalkProtocolErrorCode.invalidCallRequest,
      minimum: CallFlag.disconnected,
      maximum: CallFlag.all,
    );
    if ((parsed & ~CallFlag.all) != 0 ||
        (requireJoined && (parsed & CallFlag.inCall) == 0)) {
      protocolFailure(TalkProtocolErrorCode.invalidCallRequest, path);
    }
    return CallInCallFlags._(parsed);
  }

  factory CallInCallFlags.audioVideo() =>
      CallInCallFlags._(CallFlag.inCall | CallFlag.audio | CallFlag.video);

  final int value;

  bool contains(int flag) => (value & flag) == flag;

  @override
  bool operator ==(Object other) =>
      other is CallInCallFlags && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'CallInCallFlags($value)';
}

/// Server-owned room facts used before a call mutation is admitted.
final class CallRoomPolicy {
  const CallRoomPolicy._({
    required this.sessionId,
    required this.hasCall,
    required this.canStartCall,
    required this.permissions,
    required this.participantType,
    required this.lobbyState,
    required this.recordingConsent,
  });

  factory CallRoomPolicy.fromConversation(ConversationRoom room) {
    final recordingConsent = requireInt(
      room.wire['recordingConsent'],
      path: r'$.recordingConsent',
      code: TalkProtocolErrorCode.invalidCallState,
      minimum: 0,
      maximum: 2,
    );
    return CallRoomPolicy._(
      sessionId: room.sessionId,
      hasCall: room.hasCall,
      canStartCall: room.canStartCall,
      permissions: room.permissions,
      participantType: room.participantType,
      lobbyState: room.lobbyState,
      recordingConsent: recordingConsent,
    );
  }

  final ConversationSessionId sessionId;
  final bool hasCall;
  final bool canStartCall;
  final int permissions;
  final int participantType;
  final int lobbyState;
  final int recordingConsent;

  bool get isModerator =>
      participantType == CallParticipantType.owner ||
      participantType == CallParticipantType.moderator ||
      participantType == CallParticipantType.guestModerator;

  bool get canEndForEveryone => isModerator;

  bool canJoinWith(CallInCallFlags flags) {
    if (!flags.contains(CallFlag.inCall)) {
      return false;
    }
    final mayEnter = hasCall
        ? _hasPermission(CallPermission.join)
        : canStartCall && _hasPermission(CallPermission.start);
    if (!mayEnter ||
        (lobbyState != 0 &&
            !isModerator &&
            !_hasPermission(CallPermission.ignoreLobby))) {
      return false;
    }
    if (flags.contains(CallFlag.audio) &&
        !_hasPermission(CallPermission.audio)) {
      return false;
    }
    if (flags.contains(CallFlag.video) &&
        !_hasPermission(CallPermission.video)) {
      return false;
    }
    return true;
  }

  bool _hasPermission(int permission) => (permissions & permission) != 0;
}

/// Account, origin, room and generation boundary persisted with every intent.
final class CallLifecycleAuthority {
  CallLifecycleAuthority({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.nextcloudSessionId,
    required this.credentialGeneration,
    required this.capabilityGeneration,
    required this.capabilityRevision,
  }) {
    if (credentialGeneration < 1 ||
        capabilityGeneration < 1 ||
        capabilityRevision.isEmpty ||
        capabilityRevision.length > 128 ||
        capabilityRevision.codeUnits.any(
          (unit) => unit < 0x21 || unit > 0x7e,
        )) {
      protocolFailure(TalkProtocolErrorCode.invalidCallState, r'$.authority');
    }
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final ConversationSessionId nextcloudSessionId;
  final int credentialGeneration;
  final int capabilityGeneration;
  final String capabilityRevision;

  bool matches(CallLifecycleAuthority other) =>
      accountId == other.accountId &&
      server == other.server &&
      roomToken == other.roomToken &&
      nextcloudSessionId == other.nextcloudSessionId &&
      credentialGeneration == other.credentialGeneration &&
      capabilityGeneration == other.capabilityGeneration &&
      capabilityRevision == other.capabilityRevision;

  @override
  String toString() =>
      'CallLifecycleAuthority(credentialGeneration: $credentialGeneration, '
      'capabilityGeneration: $capabilityGeneration, sensitive: <redacted>)';
}

final class CallPeer {
  const CallPeer._({
    required this.actorType,
    required this.actorId,
    required this.displayName,
    required this.roomToken,
    required this.lastPing,
    required this.sessionId,
  });

  factory CallPeer.fromJson(Object? value, {required int index}) {
    final path = '\$.ocs.data[$index]';
    final peer = requireObject(
      value,
      path: path,
      code: TalkProtocolErrorCode.invalidCallResponse,
    );
    final displayName = peer['displayName'];
    return CallPeer._(
      actorType: requireString(
        peer['actorType'],
        path: '$path.actorType',
        code: TalkProtocolErrorCode.invalidCallResponse,
        minLength: 1,
        maxLength: 64,
      ),
      actorId: requireString(
        peer['actorId'],
        path: '$path.actorId',
        code: TalkProtocolErrorCode.invalidCallResponse,
        maxLength: 512,
      ),
      displayName: displayName == null
          ? null
          : requireString(
              displayName,
              path: '$path.displayName',
              code: TalkProtocolErrorCode.invalidCallResponse,
              maxLength: 512,
            ),
      roomToken: ConversationToken.parse(peer['token'], path: '$path.token'),
      lastPing: requireInt(
        peer['lastPing'],
        path: '$path.lastPing',
        code: TalkProtocolErrorCode.invalidCallResponse,
        minimum: 0,
      ),
      sessionId: ConversationSessionId.parse(
        peer['sessionId'],
        path: '$path.sessionId',
        code: TalkProtocolErrorCode.invalidCallResponse,
      ),
    );
  }

  final String actorType;
  final String actorId;
  final String? displayName;
  final ConversationToken roomToken;
  final int lastPing;
  final ConversationSessionId sessionId;

  @override
  String toString() => 'CallPeer(actorType: $actorType, sensitive: <redacted>)';
}
