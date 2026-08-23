import '../conversations/identifiers.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';
import 'profile.dart';

const int maximumSignalingWireBytes = 1024 * 1024;
const int maximumSignalingParticipants = 4096;
const int maximumSignalingFeatures = 256;

final class SignalingEndpointPolicy {
  const SignalingEndpointPolicy._({required this.allowDebugCleartext});

  static const production = SignalingEndpointPolicy._(
    allowDebugCleartext: false,
  );

  static const debug = SignalingEndpointPolicy._(
    allowDebugCleartext:
        !bool.fromEnvironment('dart.vm.product') &&
        !bool.fromEnvironment('dart.vm.profile'),
  );

  final bool allowDebugCleartext;
}

final class HpbEndpoint {
  const HpbEndpoint._({required this.baseUri, required this.socketUri});

  factory HpbEndpoint.parse(
    Object? value, {
    String path = r'$.ocs.data.server',
    SignalingEndpointPolicy policy = SignalingEndpointPolicy.production,
  }) {
    final raw = requireString(
      value,
      path: path,
      code: TalkProtocolErrorCode.invalidSignalingSettings,
      minLength: 1,
      maxLength: 4096,
    );
    if (raw.trim() != raw ||
        raw.contains(r'\') ||
        raw.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f)) {
      _settingsFailure(path);
    }
    final parsed = Uri.tryParse(raw);
    if (parsed == null ||
        !parsed.hasAuthority ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasQuery ||
        parsed.hasFragment) {
      _settingsFailure(path);
    }
    final cleartext = parsed.scheme == 'http' || parsed.scheme == 'ws';
    final tls = parsed.scheme == 'https' || parsed.scheme == 'wss';
    if (!tls && !(cleartext && policy.allowDebugCleartext)) {
      _settingsFailure('$path.scheme');
    }

    final httpScheme = cleartext ? 'http' : 'https';
    final normalizedBase = ServerBase.parse(
      parsed.replace(scheme: httpScheme).toString(),
      policy: cleartext
          ? ServerOriginPolicy.debug
          : ServerOriginPolicy.production,
    );
    final baseUri = normalizedBase.uri;
    final socketPath = baseUri.path.endsWith('/spreed')
        ? baseUri.path
        : '${baseUri.path}/spreed';
    return HpbEndpoint._(
      baseUri: baseUri,
      socketUri: baseUri.replace(
        scheme: cleartext ? 'ws' : 'wss',
        path: socketPath,
      ),
    );
  }

  final Uri baseUri;
  final Uri socketUri;

  @override
  bool operator ==(Object other) =>
      other is HpbEndpoint &&
      other.baseUri == baseUri &&
      other.socketUri == socketUri;

  @override
  int get hashCode => Object.hash(baseUri, socketUri);

  @override
  String toString() => 'HpbEndpoint(<redacted>)';
}

final class IceServerConfiguration {
  IceServerConfiguration({
    required Iterable<String> urls,
    required this.username,
    required this.credential,
  }) : urls = List<String>.unmodifiable(urls) {
    if (this.urls.isEmpty || this.urls.length > 16) {
      _settingsFailure(r'$.ocs.data.ice.urls');
    }
    for (final url in this.urls) {
      if (url.isEmpty ||
          url.length > 2048 ||
          !_iceUrlPattern.hasMatch(url) ||
          url.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f)) {
        _settingsFailure(r'$.ocs.data.ice.urls');
      }
    }
    if (username != null && username!.length > 4096) {
      _settingsFailure(r'$.ocs.data.ice.username');
    }
    if (credential != null &&
        (credential!.isEmpty || credential!.length > 16384)) {
      _settingsFailure(r'$.ocs.data.ice.credential');
    }
  }

  final List<String> urls;
  final String? username;
  final String? credential;

  @override
  String toString() => 'IceServerConfiguration(<redacted>)';
}

final class HpbV1Authentication {
  HpbV1Authentication({required this.userId, required this.ticket}) {
    if (userId.length > 4096 || ticket.isEmpty || ticket.length > 16384) {
      _settingsFailure(r'$.ocs.data.helloAuthParams[1.0]');
    }
  }

  final String userId;
  final String ticket;

  @override
  String toString() => 'HpbV1Authentication(<redacted>)';
}

final class HpbV2Authentication {
  HpbV2Authentication({required this.token}) {
    if (token.isEmpty || token.length > 32768) {
      _settingsFailure(r'$.ocs.data.helloAuthParams[2.0].token');
    }
  }

  final String token;

  @override
  String toString() => 'HpbV2Authentication(<redacted>)';
}

final class FederationSignalingSettings {
  FederationSignalingSettings({
    required this.endpoint,
    required this.nextcloudServer,
    required this.remoteRoomToken,
    required this.token,
  }) {
    if (token.isEmpty || token.length > 32768) {
      _settingsFailure(r'$.ocs.data.federation.helloAuthParams.token');
    }
  }

  final HpbEndpoint endpoint;
  final ServerBase nextcloudServer;
  final ConversationToken remoteRoomToken;
  final String token;

  Uri get backendUri => nextcloudServer.uri.replace(
    path:
        '${nextcloudServer.basePath}/ocs/v2.php/apps/spreed/api/v3/'
        'signaling/backend',
  );

  @override
  String toString() => 'FederationSignalingSettings(<redacted>)';
}

sealed class SignalingSettings {
  SignalingSettings({
    required this.userId,
    required Iterable<IceServerConfiguration> stunServers,
    required Iterable<IceServerConfiguration> turnServers,
    required this.federation,
  }) : stunServers = List<IceServerConfiguration>.unmodifiable(stunServers),
       turnServers = List<IceServerConfiguration>.unmodifiable(turnServers) {
    if (userId.length > 4096 ||
        this.stunServers.length > 32 ||
        this.turnServers.length > 32) {
      _settingsFailure(r'$.ocs.data');
    }
  }

  final String userId;
  final List<IceServerConfiguration> stunServers;
  final List<IceServerConfiguration> turnServers;
  final FederationSignalingSettings? federation;

  SignalingTransportKind get transport;

  SignalingTopology get initialTopology;
}

final class InternalSignalingSettings extends SignalingSettings {
  InternalSignalingSettings({
    required super.userId,
    required super.stunServers,
    required super.turnServers,
    required super.federation,
  });

  @override
  SignalingTransportKind get transport => SignalingTransportKind.internal;

  @override
  SignalingTopology get initialTopology => SignalingTopology.internalPeerToPeer;

  @override
  String toString() => 'InternalSignalingSettings(<redacted>)';
}

final class ExternalSignalingSettings extends SignalingSettings {
  ExternalSignalingSettings({
    required super.userId,
    required super.stunServers,
    required super.turnServers,
    required super.federation,
    required this.endpoint,
    required this.v1Authentication,
    required this.v2Authentication,
  }) {
    if (v1Authentication == null && v2Authentication == null) {
      _settingsFailure(r'$.ocs.data.helloAuthParams');
    }
  }

  final HpbEndpoint endpoint;
  final HpbV1Authentication? v1Authentication;
  final HpbV2Authentication? v2Authentication;

  @override
  SignalingTransportKind get transport => SignalingTransportKind.externalHpb;

  @override
  SignalingTopology get initialTopology => SignalingTopology.externalPeerToPeer;

  @override
  String toString() => 'ExternalSignalingSettings(<redacted>)';
}

final class SignalingOpaquePayload {
  SignalingOpaquePayload._(this.wire);

  factory SignalingOpaquePayload.fromJson(
    Object? value, {
    String path = r'$.payload',
  }) {
    _validateSignalingStrings(value, path: path, depth: 0);
    final frozen = JsonFreezeSession(
      maximumDepth: 24,
      maximumNodes: 4096,
      errorCode: TalkProtocolErrorCode.invalidSignalingFrame,
      errorPath: path,
    ).freeze(value);
    return SignalingOpaquePayload._(
      requireObject(
        frozen,
        path: path,
        code: TalkProtocolErrorCode.invalidSignalingFrame,
      ),
    );
  }

  final Map<String, Object?> wire;

  @override
  String toString() => 'SignalingOpaquePayload(<redacted>)';
}

final class SignalingPeerMessage {
  SignalingPeerMessage({
    required this.type,
    required this.roomType,
    required this.sid,
    required this.recipient,
    required this.sender,
    required this.payload,
  }) {
    if (!_safeWireName(type, maximumLength: 128) ||
        (roomType.isNotEmpty && !_safeWireName(roomType, maximumLength: 64)) ||
        (sid != null && !_safeWireName(sid!, maximumLength: 512))) {
      protocolFailure(
        TalkProtocolErrorCode.invalidSignalingFrame,
        r'$.message',
      );
    }
  }

  factory SignalingPeerMessage.fromJson(
    Object? value, {
    String path = r'$.message.data',
  }) {
    final message = requireObject(
      value,
      path: path,
      code: TalkProtocolErrorCode.invalidSignalingFrame,
    );
    return SignalingPeerMessage(
      type: requireString(
        message['type'],
        path: '$path.type',
        code: TalkProtocolErrorCode.invalidSignalingFrame,
        minLength: 1,
        maxLength: 128,
      ),
      roomType: message['roomType'] == null
          ? ''
          : requireString(
              message['roomType'],
              path: '$path.roomType',
              code: TalkProtocolErrorCode.invalidSignalingFrame,
              maxLength: 64,
            ),
      sid: message['sid'] == null
          ? null
          : requireString(
              message['sid'],
              path: '$path.sid',
              code: TalkProtocolErrorCode.invalidSignalingFrame,
              minLength: 1,
              maxLength: 512,
            ),
      recipient: message['to'] == null
          ? null
          : SignalingPeerId.parse(message['to'], path: '$path.to'),
      sender: message['from'] == null
          ? null
          : SignalingPeerId.parse(message['from'], path: '$path.from'),
      payload: SignalingOpaquePayload.fromJson(
        message['payload'],
        path: '$path.payload',
      ),
    );
  }

  final String type;
  final String roomType;
  final String? sid;
  final SignalingPeerId? recipient;
  final SignalingPeerId? sender;
  final SignalingOpaquePayload payload;

  Map<String, Object?> toWire({
    bool includeSender = false,
    bool includeRecipient = true,
  }) => RedactedMapView(<String, Object?>{
    'type': type,
    'roomType': roomType,
    if (sid != null) 'sid': sid,
    if (includeRecipient && recipient != null) 'to': recipient!.value,
    if (includeSender && sender != null) 'from': sender!.value,
    'payload': payload.wire,
  });

  @override
  String toString() => 'SignalingPeerMessage(<redacted>)';
}

final class HpbControlMessage {
  const HpbControlMessage({
    required this.recipient,
    required this.sender,
    required this.data,
  });

  final SignalingPeerId? recipient;
  final SignalingPeerId? sender;
  final SignalingOpaquePayload data;

  @override
  String toString() => 'HpbControlMessage(<redacted>)';
}

final class SignalingParticipant {
  SignalingParticipant({
    required this.peerId,
    required this.nextcloudSessionId,
    required this.userId,
    required this.inCall,
    required this.permissions,
    required this.actorType,
    required this.actorId,
    required this.federated,
    required Iterable<String> features,
  }) : features = Set<String>.unmodifiable(features) {
    if (userId.length > 4096 ||
        actorType.length > 128 ||
        actorId.length > 4096 ||
        inCall < 0 ||
        permissions < 0 ||
        this.features.length > maximumSignalingFeatures ||
        this.features.any(
          (value) => !_safeWireName(value, maximumLength: 128),
        )) {
      protocolFailure(
        TalkProtocolErrorCode.invalidSignalingFrame,
        r'$.participant',
      );
    }
  }

  final SignalingPeerId peerId;
  final ConversationSessionId? nextcloudSessionId;
  final String userId;
  final int inCall;
  final int permissions;
  final String actorType;
  final String actorId;
  final bool federated;
  final Set<String> features;

  SignalingParticipant withInCall(int value) => SignalingParticipant(
    peerId: peerId,
    nextcloudSessionId: nextcloudSessionId,
    userId: userId,
    inCall: value,
    permissions: permissions,
    actorType: actorType,
    actorId: actorId,
    federated: federated,
    features: features,
  );

  @override
  String toString() => 'SignalingParticipant(<redacted>)';
}

final RegExp _iceUrlPattern = RegExp(
  r'^(?:stun|stuns|turn|turns):[^\s]+$',
  caseSensitive: false,
);

bool _safeWireName(String value, {required int maximumLength}) =>
    value.isNotEmpty &&
    value.length <= maximumLength &&
    value.codeUnits.every((unit) => unit >= 0x20 && unit <= 0x7e);

void _validateSignalingStrings(
  Object? value, {
  required String path,
  required int depth,
}) {
  if (depth > 24) {
    protocolFailure(TalkProtocolErrorCode.invalidSignalingFrame, path);
  }
  if (value is String) {
    if (value.length > 512 * 1024) {
      protocolFailure(TalkProtocolErrorCode.invalidSignalingFrame, path);
    }
    return;
  }
  if (value is Map<Object?, Object?>) {
    if (value.length > 4096) {
      protocolFailure(TalkProtocolErrorCode.invalidSignalingFrame, path);
    }
    for (final entry in value.entries) {
      if (entry.key is! String || (entry.key! as String).length > 256) {
        protocolFailure(TalkProtocolErrorCode.invalidSignalingFrame, path);
      }
      _validateSignalingStrings(entry.value, path: path, depth: depth + 1);
    }
    return;
  }
  if (value is List<Object?>) {
    if (value.length > 4096) {
      protocolFailure(TalkProtocolErrorCode.invalidSignalingFrame, path);
    }
    for (final item in value) {
      _validateSignalingStrings(item, path: path, depth: depth + 1);
    }
    return;
  }
  if (value != null && value is! num && value is! bool) {
    protocolFailure(TalkProtocolErrorCode.invalidSignalingFrame, path);
  }
}

Never _settingsFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidSignalingSettings, path);
