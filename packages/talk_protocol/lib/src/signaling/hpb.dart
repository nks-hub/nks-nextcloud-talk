import 'dart:convert';

import '../conversations/identifiers.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';
import 'models.dart';
import 'profile.dart';

enum HpbHelloVersion {
  v1('1.0'),
  v2('2.0');

  const HpbHelloVersion(this.wireValue);

  final String wireValue;

  static HpbHelloVersion parse(Object? value, {required String path}) {
    final version = requireString(
      value,
      path: path,
      code: TalkProtocolErrorCode.invalidSignalingFrame,
      minLength: 3,
      maxLength: 3,
    );
    return switch (version) {
      '1.0' => HpbHelloVersion.v1,
      '2.0' => HpbHelloVersion.v2,
      _ => _frameFailure(path),
    };
  }
}

final class HpbServerFeatures {
  HpbServerFeatures._(Set<String> values)
    : values = Set<String>.unmodifiable(values);

  factory HpbServerFeatures.parse(Object? value, {required String path}) {
    final items = requireList(
      value,
      path: path,
      code: TalkProtocolErrorCode.invalidSignalingFrame,
    );
    if (items.length > maximumSignalingFeatures) {
      _frameFailure(path);
    }
    final result = <String>{};
    for (var index = 0; index < items.length; index++) {
      final feature = requireString(
        items[index],
        path: '$path[$index]',
        code: TalkProtocolErrorCode.invalidSignalingFrame,
        minLength: 1,
        maxLength: 128,
      );
      if (!_safeAscii(feature) || !result.add(feature)) {
        _frameFailure(path);
      }
    }
    return HpbServerFeatures._(result);
  }

  static final empty = HpbServerFeatures._(<String>{});

  final Set<String> values;

  bool supports(String feature) => values.contains(feature);

  SignalingTopology get topology => supports('mcu')
      ? SignalingTopology.externalMcu
      : SignalingTopology.externalPeerToPeer;

  @override
  String toString() => 'HpbServerFeatures(count: ${values.length})';
}

sealed class HpbClientFrame {
  HpbClientFrame({required this.requestId});

  final SignalingRequestId requestId;

  String get type;

  Map<String, Object?> get wire;

  String encode() {
    final encoded = jsonEncode(wire);
    if (utf8.encode(encoded).length > maximumSignalingWireBytes) {
      _frameFailure(r'$.frame');
    }
    return encoded;
  }

  @override
  String toString() => 'HpbClientFrame(type: $type, sensitive: <redacted>)';
}

final class HpbHelloClientFrame extends HpbClientFrame {
  HpbHelloClientFrame._({
    required super.requestId,
    required this.version,
    required this.resumeId,
    required this.wire,
  });

  factory HpbHelloClientFrame.fullV1({
    required SignalingRequestId requestId,
    required ServerBase server,
    required HpbV1Authentication authentication,
    Iterable<String> features = const <String>['chat-relay'],
  }) {
    final clientFeatures = _clientFeatures(features);
    return HpbHelloClientFrame._(
      requestId: requestId,
      version: HpbHelloVersion.v1,
      resumeId: null,
      wire: RedactedMapView(<String, Object?>{
        'id': requestId.value,
        'type': 'hello',
        'hello': <String, Object?>{
          'version': '1.0',
          'features': clientFeatures,
          'auth': <String, Object?>{
            'url': _backendUri(server).toString(),
            'params': <String, Object?>{
              if (authentication.userId.isNotEmpty)
                'userid': authentication.userId,
              'ticket': authentication.ticket,
            },
          },
        },
      }),
    );
  }

  factory HpbHelloClientFrame.fullV2({
    required SignalingRequestId requestId,
    required ServerBase server,
    required HpbV2Authentication authentication,
    Iterable<String> features = const <String>['chat-relay'],
  }) {
    final clientFeatures = _clientFeatures(features);
    return HpbHelloClientFrame._(
      requestId: requestId,
      version: HpbHelloVersion.v2,
      resumeId: null,
      wire: RedactedMapView(<String, Object?>{
        'id': requestId.value,
        'type': 'hello',
        'hello': <String, Object?>{
          'version': '2.0',
          'features': clientFeatures,
          'auth': <String, Object?>{
            'url': _backendUri(server).toString(),
            'params': <String, Object?>{'token': authentication.token},
          },
        },
      }),
    );
  }

  factory HpbHelloClientFrame.resume({
    required SignalingRequestId requestId,
    required HpbHelloVersion version,
    required HpbResumeId resumeId,
  }) => HpbHelloClientFrame._(
    requestId: requestId,
    version: version,
    resumeId: resumeId,
    wire: RedactedMapView(<String, Object?>{
      'id': requestId.value,
      'type': 'hello',
      'hello': <String, Object?>{
        'version': version.wireValue,
        'resumeid': resumeId.value,
      },
    }),
  );

  final HpbHelloVersion version;
  final HpbResumeId? resumeId;

  bool get isResume => resumeId != null;

  @override
  String get type => 'hello';

  @override
  final Map<String, Object?> wire;
}

final class HpbRoomClientFrame extends HpbClientFrame {
  HpbRoomClientFrame._({
    required super.requestId,
    required this.roomToken,
    required this.nextcloudSessionId,
    required this.federation,
    required this.wire,
  });

  factory HpbRoomClientFrame.join({
    required SignalingRequestId requestId,
    required ConversationToken roomToken,
    required ConversationSessionId nextcloudSessionId,
    FederationSignalingSettings? federation,
  }) => HpbRoomClientFrame._(
    requestId: requestId,
    roomToken: roomToken,
    nextcloudSessionId: nextcloudSessionId,
    federation: federation,
    wire: RedactedMapView(<String, Object?>{
      'id': requestId.value,
      'type': 'room',
      'room': <String, Object?>{
        'roomid': roomToken.value,
        'sessionid': nextcloudSessionId.value,
        if (federation != null)
          'federation': <String, Object?>{
            'signaling': federation.endpoint.socketUri.toString(),
            'url': federation.backendUri.toString(),
            'roomid': federation.remoteRoomToken.value,
            'token': federation.token,
          },
      },
    }),
  );

  factory HpbRoomClientFrame.leave({required SignalingRequestId requestId}) =>
      HpbRoomClientFrame._(
        requestId: requestId,
        roomToken: null,
        nextcloudSessionId: null,
        federation: null,
        wire: RedactedMapView(<String, Object?>{
          'id': requestId.value,
          'type': 'room',
          'room': <String, Object?>{'roomid': ''},
        }),
      );

  final ConversationToken? roomToken;
  final ConversationSessionId? nextcloudSessionId;
  final FederationSignalingSettings? federation;

  bool get isLeave => roomToken == null;

  @override
  String get type => 'room';

  @override
  final Map<String, Object?> wire;
}

final class HpbMessageClientFrame extends HpbClientFrame {
  HpbMessageClientFrame({required super.requestId, required this.message}) {
    final recipient = message.recipient;
    if (recipient == null) {
      _frameFailure(r'$.message.recipient');
    }
    wire = RedactedMapView(<String, Object?>{
      'id': requestId.value,
      'type': 'message',
      'message': <String, Object?>{
        'recipient': <String, Object?>{
          'type': 'session',
          'sessionid': recipient.value,
        },
        'data': message.toWire(includeRecipient: false),
      },
    });
  }

  final SignalingPeerMessage message;

  @override
  String get type => 'message';

  @override
  late final Map<String, Object?> wire;
}

final class HpbControlClientFrame extends HpbClientFrame {
  HpbControlClientFrame({required super.requestId, required this.control}) {
    final recipient = control.recipient;
    if (recipient == null || control.sender != null) {
      _frameFailure(r'$.control');
    }
    wire = RedactedMapView(<String, Object?>{
      'id': requestId.value,
      'type': 'control',
      'control': <String, Object?>{
        'recipient': <String, Object?>{
          'type': 'session',
          'sessionid': recipient.value,
        },
        'data': control.data.wire,
      },
    });
  }

  final HpbControlMessage control;

  @override
  String get type => 'control';

  @override
  late final Map<String, Object?> wire;
}

final class HpbByeClientFrame extends HpbClientFrame {
  HpbByeClientFrame({required super.requestId})
    : wire = RedactedMapView(<String, Object?>{
        'id': requestId.value,
        'type': 'bye',
        'bye': <String, Object?>{},
      });

  @override
  String get type => 'bye';

  @override
  final Map<String, Object?> wire;
}

sealed class HpbServerFrame {
  const HpbServerFrame({required this.requestId});

  factory HpbServerFrame.decode(String encoded) {
    if (encoded.isEmpty ||
        utf8.encode(encoded).length > maximumSignalingWireBytes) {
      _frameFailure(r'$.frame');
    }
    Object? decoded;
    decoded = decodeJsonRejectingDuplicateMembers(
      encoded,
      code: TalkProtocolErrorCode.invalidSignalingFrame,
      path: r'$.frame',
    );
    final frozen = JsonFreezeSession(
      maximumDepth: 32,
      maximumNodes: 12000,
      errorCode: TalkProtocolErrorCode.invalidSignalingFrame,
      errorPath: r'$.frame',
    ).freeze(decoded);
    final frame = requireObject(
      frozen,
      path: r'$',
      code: TalkProtocolErrorCode.invalidSignalingFrame,
    );
    final type = requireString(
      frame['type'],
      path: r'$.type',
      code: TalkProtocolErrorCode.invalidSignalingFrame,
      minLength: 1,
      maxLength: 64,
    );
    if (!_safeAscii(type)) {
      _frameFailure(r'$.type');
    }
    return switch (type) {
      'welcome' => HpbWelcomeServerFrame._parse(frame),
      'hello' => HpbHelloServerFrame._parse(frame),
      'room' => HpbRoomServerFrame._parse(frame),
      'error' => HpbErrorServerFrame._parse(frame),
      'event' => HpbEventServerFrame._parse(frame),
      'message' => HpbMessageServerFrame._parse(frame),
      'control' => HpbControlServerFrame._parse(frame),
      'bye' => HpbByeServerFrame._parse(frame),
      _ => HpbUnsupportedServerFrame(unsupportedType: type),
    };
  }

  final SignalingRequestId? requestId;

  String get type;

  @override
  String toString() => 'HpbServerFrame(type: $type, sensitive: <redacted>)';
}

final class HpbWelcomeServerFrame extends HpbServerFrame {
  HpbWelcomeServerFrame._({required this.features}) : super(requestId: null);

  factory HpbWelcomeServerFrame._parse(Map<String, Object?> frame) {
    if (frame['id'] != null) {
      _frameFailure(r'$.id');
    }
    final welcome = requireObject(
      frame['welcome'],
      path: r'$.welcome',
      code: TalkProtocolErrorCode.invalidSignalingFrame,
    );
    return HpbWelcomeServerFrame._(
      features: welcome['features'] == null
          ? HpbServerFeatures.empty
          : HpbServerFeatures.parse(
              welcome['features'],
              path: r'$.welcome.features',
            ),
    );
  }

  final HpbServerFeatures features;

  @override
  String get type => 'welcome';
}

final class HpbHelloServerFrame extends HpbServerFrame {
  HpbHelloServerFrame._({
    required super.requestId,
    required this.version,
    required this.sessionId,
    required this.resumeId,
    required this.serverFeatures,
  });

  factory HpbHelloServerFrame._parse(Map<String, Object?> frame) {
    final hello = requireObject(
      frame['hello'],
      path: r'$.hello',
      code: TalkProtocolErrorCode.invalidSignalingFrame,
    );
    HpbServerFeatures fallback = HpbServerFeatures.empty;
    if (hello['server'] != null) {
      final server = requireObject(
        hello['server'],
        path: r'$.hello.server',
        code: TalkProtocolErrorCode.invalidSignalingFrame,
      );
      if (server['features'] != null) {
        fallback = HpbServerFeatures.parse(
          server['features'],
          path: r'$.hello.server.features',
        );
      }
    }
    return HpbHelloServerFrame._(
      requestId: _requiredRequestId(frame),
      version: HpbHelloVersion.parse(
        hello['version'],
        path: r'$.hello.version',
      ),
      sessionId: HpbSessionId.parse(hello['sessionid']),
      resumeId: hello['resumeid'] == null
          ? null
          : HpbResumeId.parse(hello['resumeid']),
      serverFeatures: fallback,
    );
  }

  final HpbHelloVersion version;
  final HpbSessionId sessionId;
  final HpbResumeId? resumeId;
  final HpbServerFeatures serverFeatures;

  @override
  String get type => 'hello';
}

final class HpbRoomServerFrame extends HpbServerFrame {
  HpbRoomServerFrame._({
    required super.requestId,
    required this.roomToken,
    required this.maximumStreamBitrate,
    required this.maximumScreenBitrate,
  });

  factory HpbRoomServerFrame._parse(Map<String, Object?> frame) {
    final room = requireObject(
      frame['room'],
      path: r'$.room',
      code: TalkProtocolErrorCode.invalidSignalingFrame,
    );
    final roomId = requireString(
      room['roomid'],
      path: r'$.room.roomid',
      code: TalkProtocolErrorCode.invalidSignalingFrame,
      maxLength: 30,
    );
    int? stream;
    int? screen;
    if (room['bandwidth'] != null) {
      final bandwidth = requireObject(
        room['bandwidth'],
        path: r'$.room.bandwidth',
        code: TalkProtocolErrorCode.invalidSignalingFrame,
      );
      stream = requireInt(
        bandwidth['maxstreambitrate'],
        path: r'$.room.bandwidth.maxstreambitrate',
        code: TalkProtocolErrorCode.invalidSignalingFrame,
        minimum: 0,
      );
      screen = requireInt(
        bandwidth['maxscreenbitrate'],
        path: r'$.room.bandwidth.maxscreenbitrate',
        code: TalkProtocolErrorCode.invalidSignalingFrame,
        minimum: 0,
      );
    }
    return HpbRoomServerFrame._(
      requestId: _optionalRequestId(frame),
      roomToken: roomId.isEmpty
          ? null
          : ConversationToken.parse(
              roomId,
              path: r'$.room.roomid',
              code: TalkProtocolErrorCode.invalidSignalingFrame,
            ),
      maximumStreamBitrate: stream,
      maximumScreenBitrate: screen,
    );
  }

  final ConversationToken? roomToken;
  final int? maximumStreamBitrate;
  final int? maximumScreenBitrate;

  @override
  String get type => 'room';
}

final class HpbErrorServerFrame extends HpbServerFrame {
  HpbErrorServerFrame._({
    required super.requestId,
    required this.code,
    required this.roomToken,
  });

  factory HpbErrorServerFrame._parse(Map<String, Object?> frame) {
    final error = requireObject(
      frame['error'],
      path: r'$.error',
      code: TalkProtocolErrorCode.invalidSignalingFrame,
    );
    final code = requireString(
      error['code'],
      path: r'$.error.code',
      code: TalkProtocolErrorCode.invalidSignalingFrame,
      minLength: 1,
      maxLength: 128,
    );
    requireString(
      error['message'],
      path: r'$.error.message',
      code: TalkProtocolErrorCode.invalidSignalingFrame,
      maxLength: 4096,
    );
    ConversationToken? roomToken;
    if (error['details'] != null) {
      final details = requireObject(
        error['details'],
        path: r'$.error.details',
        code: TalkProtocolErrorCode.invalidSignalingFrame,
      );
      if (details['room'] != null) {
        final room = requireObject(
          details['room'],
          path: r'$.error.details.room',
          code: TalkProtocolErrorCode.invalidSignalingFrame,
        );
        roomToken = ConversationToken.parse(
          room['roomid'],
          path: r'$.error.details.room.roomid',
          code: TalkProtocolErrorCode.invalidSignalingFrame,
        );
      }
    }
    return HpbErrorServerFrame._(
      requestId: _optionalRequestId(frame),
      code: code,
      roomToken: roomToken,
    );
  }

  final String code;
  final ConversationToken? roomToken;

  @override
  String get type => 'error';
}

final class HpbEventServerFrame extends HpbServerFrame {
  HpbEventServerFrame._({
    required this.target,
    required this.eventType,
    required this.roomToken,
    required Iterable<SignalingParticipant> participants,
    required Iterable<SignalingPeerId> leavingPeerIds,
    required this.allParticipantsInCall,
    required this.federationResumed,
    required this.chatRelay,
  }) : participants = List<SignalingParticipant>.unmodifiable(participants),
       leavingPeerIds = List<SignalingPeerId>.unmodifiable(leavingPeerIds),
       super(requestId: null);

  factory HpbEventServerFrame._parse(Map<String, Object?> frame) {
    if (frame['id'] != null) {
      _frameFailure(r'$.id');
    }
    final event = requireObject(
      frame['event'],
      path: r'$.event',
      code: TalkProtocolErrorCode.invalidSignalingFrame,
    );
    final target = requireString(
      event['target'],
      path: r'$.event.target',
      code: TalkProtocolErrorCode.invalidSignalingFrame,
      minLength: 1,
      maxLength: 64,
    );
    final eventType = requireString(
      event['type'],
      path: r'$.event.type',
      code: TalkProtocolErrorCode.invalidSignalingFrame,
      minLength: 1,
      maxLength: 64,
    );
    if (!_safeAscii(target) || !_safeAscii(eventType)) {
      _frameFailure(r'$.event');
    }

    var participants = const <SignalingParticipant>[];
    var leaving = const <SignalingPeerId>[];
    ConversationToken? roomToken;
    int? allParticipantsInCall;
    bool? federationResumed;
    Map<String, Object?>? chatRelay;
    if (target == 'room' && eventType == 'message') {
      final message = requireObject(
        event['message'],
        path: r'$.event.message',
        code: TalkProtocolErrorCode.invalidSignalingFrame,
      );
      roomToken = ConversationToken.parse(
        message['roomid'],
        path: r'$.event.message.roomid',
        code: TalkProtocolErrorCode.invalidSignalingFrame,
      );
      final data = requireObject(
        message['data'],
        path: r'$.event.message.data',
        code: TalkProtocolErrorCode.invalidSignalingFrame,
      );
      // Only the chat payload is claimed here. Recording status and any
      // future room message type stay unparsed rather than rejected, so an
      // unknown one is ignored instead of killing the connection.
      if (data['type'] == 'chat') {
        chatRelay = requireObject(
          data['chat'],
          path: r'$.event.message.data.chat',
          code: TalkProtocolErrorCode.invalidSignalingFrame,
        );
      }
    } else if (target == 'room' &&
        (eventType == 'join' || eventType == 'change')) {
      final raw = requireList(
        event[eventType],
        path: '\$.event.$eventType',
        code: TalkProtocolErrorCode.invalidSignalingFrame,
      );
      participants = _parseHpbParticipants(
        raw,
        path: '\$.event.$eventType',
        participantUpdate: false,
      );
    } else if (target == 'room' && eventType == 'leave') {
      final raw = requireList(
        event['leave'],
        path: r'$.event.leave',
        code: TalkProtocolErrorCode.invalidSignalingFrame,
      );
      if (raw.length > maximumSignalingParticipants) {
        _frameFailure(r'$.event.leave');
      }
      leaving = <SignalingPeerId>[
        for (var index = 0; index < raw.length; index++)
          SignalingPeerId.parse(raw[index], path: '\$.event.leave[$index]'),
      ];
      if (leaving.toSet().length != leaving.length) {
        _frameFailure(r'$.event.leave');
      }
    } else if (target == 'participants' && eventType == 'update') {
      final update = requireObject(
        event['update'],
        path: r'$.event.update',
        code: TalkProtocolErrorCode.invalidSignalingFrame,
      );
      roomToken = ConversationToken.parse(
        update['roomid'],
        path: r'$.event.update.roomid',
        code: TalkProtocolErrorCode.invalidSignalingFrame,
      );
      if (update['users'] != null) {
        participants = _parseHpbParticipants(
          requireList(
            update['users'],
            path: r'$.event.update.users',
            code: TalkProtocolErrorCode.invalidSignalingFrame,
          ),
          path: r'$.event.update.users',
          participantUpdate: true,
        );
      } else {
        final all = requireBool(
          update['all'],
          path: r'$.event.update.all',
          code: TalkProtocolErrorCode.invalidSignalingFrame,
        );
        if (!all) {
          _frameFailure(r'$.event.update.all');
        }
        allParticipantsInCall = requireInt(
          update['incall'],
          path: r'$.event.update.incall',
          code: TalkProtocolErrorCode.invalidSignalingFrame,
          minimum: 0,
        );
      }
    } else if (target == 'room' && eventType == 'federation_interrupted') {
      federationResumed = false;
    } else if (target == 'room' && eventType == 'federation_resumed') {
      federationResumed = requireBool(
        event['resumed'],
        path: r'$.event.resumed',
        code: TalkProtocolErrorCode.invalidSignalingFrame,
      );
    }
    return HpbEventServerFrame._(
      target: target,
      eventType: eventType,
      roomToken: roomToken,
      participants: participants,
      leavingPeerIds: leaving,
      allParticipantsInCall: allParticipantsInCall,
      federationResumed: federationResumed,
      chatRelay: chatRelay,
    );
  }

  final String target;
  final String eventType;
  final ConversationToken? roomToken;
  final List<SignalingParticipant> participants;
  final List<SignalingPeerId> leavingPeerIds;
  final int? allParticipantsInCall;
  final bool? federationResumed;

  /// The raw `data.chat` object of a room message event, or null when the
  /// event carries no chat payload. Decoding it is the chat layer's job;
  /// see `decodeChatRelayEvent`.
  final Map<String, Object?>? chatRelay;

  @override
  String get type => 'event';
}

final class HpbMessageServerFrame extends HpbServerFrame {
  HpbMessageServerFrame._({
    required super.requestId,
    required this.frameType,
    required this.message,
  });

  factory HpbMessageServerFrame._parse(Map<String, Object?> frame) {
    const type = 'message';
    final body = requireObject(
      frame[type],
      path: r'$.message',
      code: TalkProtocolErrorCode.invalidSignalingFrame,
    );
    final sender = _parseHpbSender(body, path: r'$.message.sender');
    final parsed = SignalingPeerMessage.fromJson(
      body['data'],
      path: r'$.message.data',
    );
    return HpbMessageServerFrame._(
      requestId: _optionalRequestId(frame),
      frameType: type,
      message: SignalingPeerMessage(
        type: parsed.type,
        roomType: parsed.roomType,
        sid: parsed.sid,
        recipient: parsed.recipient,
        sender: sender ?? parsed.sender,
        payload: parsed.payload,
        broadcaster: parsed.broadcaster,
      ),
    );
  }

  final String frameType;
  final SignalingPeerMessage message;

  @override
  String get type => frameType;
}

final class HpbControlServerFrame extends HpbServerFrame {
  HpbControlServerFrame._({required super.requestId, required this.control});

  factory HpbControlServerFrame._parse(Map<String, Object?> frame) {
    final body = requireObject(
      frame['control'],
      path: r'$.control',
      code: TalkProtocolErrorCode.invalidSignalingFrame,
    );
    return HpbControlServerFrame._(
      requestId: _optionalRequestId(frame),
      control: HpbControlMessage(
        recipient: _parseHpbRecipient(body, path: r'$.control.recipient'),
        sender: _parseHpbSender(body, path: r'$.control.sender'),
        data: SignalingOpaquePayload.fromJson(
          body['data'],
          path: r'$.control.data',
        ),
      ),
    );
  }

  final HpbControlMessage control;

  @override
  String get type => 'control';
}

final class HpbByeServerFrame extends HpbServerFrame {
  HpbByeServerFrame._({required super.requestId});

  factory HpbByeServerFrame._parse(Map<String, Object?> frame) {
    requireObject(
      frame['bye'],
      path: r'$.bye',
      code: TalkProtocolErrorCode.invalidSignalingFrame,
    );
    return HpbByeServerFrame._(requestId: _optionalRequestId(frame));
  }

  @override
  String get type => 'bye';
}

final class HpbUnsupportedServerFrame extends HpbServerFrame {
  const HpbUnsupportedServerFrame({required this.unsupportedType})
    : super(requestId: null);

  final String unsupportedType;

  @override
  String get type => unsupportedType;
}

List<SignalingParticipant> _parseHpbParticipants(
  List<Object?> values, {
  required String path,
  required bool participantUpdate,
}) {
  if (values.length > maximumSignalingParticipants) {
    _frameFailure(path);
  }
  final result = <SignalingParticipant>[];
  final ids = <SignalingPeerId>{};
  for (var index = 0; index < values.length; index++) {
    final itemPath = '$path[$index]';
    final value = requireObject(
      values[index],
      path: itemPath,
      code: TalkProtocolErrorCode.invalidSignalingFrame,
    );
    final peerId = SignalingPeerId.parse(
      value[participantUpdate ? 'sessionId' : 'sessionid'],
      path: '$itemPath.${participantUpdate ? 'sessionId' : 'sessionid'}',
    );
    if (!ids.add(peerId)) {
      _frameFailure(path);
    }
    final rawFeatures = value['features'];
    final features = rawFeatures == null
        ? const <String>{}
        : HpbServerFeatures.parse(
            rawFeatures,
            path: '$itemPath.features',
          ).values;
    final rawRoomSession =
        value[participantUpdate ? 'nextcloudSessionId' : 'roomsessionid'];
    result.add(
      SignalingParticipant(
        peerId: peerId,
        nextcloudSessionId: rawRoomSession == null
            ? null
            : ConversationSessionId.parse(
                rawRoomSession,
                path:
                    '$itemPath.'
                    '${participantUpdate ? 'nextcloudSessionId' : 'roomsessionid'}',
                code: TalkProtocolErrorCode.invalidSignalingFrame,
              ),
        userId: value[participantUpdate ? 'userId' : 'userid'] == null
            ? ''
            : requireString(
                value[participantUpdate ? 'userId' : 'userid'],
                path: '$itemPath.${participantUpdate ? 'userId' : 'userid'}',
                code: TalkProtocolErrorCode.invalidSignalingFrame,
                maxLength: 4096,
              ),
        inCall: value['inCall'] == null
            ? 0
            : requireInt(
                value['inCall'],
                path: '$itemPath.inCall',
                code: TalkProtocolErrorCode.invalidSignalingFrame,
                minimum: 0,
              ),
        permissions: value['participantPermissions'] == null
            ? 0
            : requireInt(
                value['participantPermissions'],
                path: '$itemPath.participantPermissions',
                code: TalkProtocolErrorCode.invalidSignalingFrame,
                minimum: 0,
              ),
        actorType: value['actorType'] == null
            ? ''
            : requireString(
                value['actorType'],
                path: '$itemPath.actorType',
                code: TalkProtocolErrorCode.invalidSignalingFrame,
                maxLength: 128,
              ),
        actorId: value['actorId'] == null
            ? ''
            : requireString(
                value['actorId'],
                path: '$itemPath.actorId',
                code: TalkProtocolErrorCode.invalidSignalingFrame,
                maxLength: 4096,
              ),
        federated: value['federated'] == null
            ? false
            : requireBool(
                value['federated'],
                path: '$itemPath.federated',
                code: TalkProtocolErrorCode.invalidSignalingFrame,
              ),
        features: features,
      ),
    );
  }
  return result;
}

SignalingRequestId _requiredRequestId(Map<String, Object?> frame) =>
    SignalingRequestId.parse(frame['id']);

SignalingRequestId? _optionalRequestId(Map<String, Object?> frame) =>
    frame['id'] == null ? null : SignalingRequestId.parse(frame['id']);

SignalingPeerId? _parseHpbSender(
  Map<String, Object?> body, {
  required String path,
}) => _parseHpbActor(body['sender'], path: path);

SignalingPeerId? _parseHpbRecipient(
  Map<String, Object?> body, {
  required String path,
}) => _parseHpbActor(body['recipient'], path: path);

SignalingPeerId? _parseHpbActor(Object? value, {required String path}) {
  if (value == null) {
    return null;
  }
  final actor = requireObject(
    value,
    path: path,
    code: TalkProtocolErrorCode.invalidSignalingFrame,
  );
  final type = requireString(
    actor['type'],
    path: '$path.type',
    code: TalkProtocolErrorCode.invalidSignalingFrame,
    minLength: 1,
    maxLength: 64,
  );
  if (!_safeAscii(type)) {
    _frameFailure('$path.type');
  }
  return actor['sessionid'] == null
      ? null
      : SignalingPeerId.parse(actor['sessionid'], path: '$path.sessionid');
}

List<String> _clientFeatures(Iterable<String> source) {
  final values = source.toSet();
  if (values.length > maximumSignalingFeatures ||
      values.any((value) => !_safeAscii(value) || value.length > 128)) {
    _frameFailure(r'$.hello.features');
  }
  return List<String>.unmodifiable(values);
}

Uri _backendUri(ServerBase server) => server.uri.replace(
  path: '${server.basePath}/ocs/v2.php/apps/spreed/api/v3/signaling/backend',
);

bool _safeAscii(String value) =>
    value.isNotEmpty &&
    value.codeUnits.every((unit) => unit >= 0x20 && unit <= 0x7e);

Never _frameFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidSignalingFrame, path);
