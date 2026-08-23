import 'dart:convert';
import 'dart:typed_data';

import '../conversations/identifiers.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';
import 'models.dart';
import 'request.dart';

enum SignalingSettingsClassification {
  confirmed,
  reauthenticationRequired,
  roomRefreshRequired,
  serverError,
}

enum InternalSignalingClassification {
  confirmed,
  profileRefreshRequired,
  reauthenticationRequired,
  roomRefreshRequired,
  sessionTerminated,
  serverError,
}

final class SignalingSettingsResponse {
  const SignalingSettingsResponse({
    required this.request,
    required this.classification,
    required this.settings,
  });

  final SignalingSettingsRequest request;
  final SignalingSettingsClassification classification;
  final SignalingSettings? settings;

  @override
  String toString() =>
      'SignalingSettingsResponse(classification: ${classification.name}, '
      'hasSettings: ${settings != null})';
}

final class InternalSignalingPullResponse {
  InternalSignalingPullResponse({
    required this.request,
    required this.classification,
    required Iterable<SignalingPeerMessage> messages,
    required Iterable<SignalingParticipant> participants,
  }) : messages = List<SignalingPeerMessage>.unmodifiable(messages),
       participants = List<SignalingParticipant>.unmodifiable(participants);

  final InternalSignalingPullRequest request;
  final InternalSignalingClassification classification;
  final List<SignalingPeerMessage> messages;
  final List<SignalingParticipant> participants;

  @override
  String toString() =>
      'InternalSignalingPullResponse(classification: '
      '${classification.name}, messages: ${messages.length}, '
      'participants: ${participants.length})';
}

final class InternalSignalingBatchResponse {
  const InternalSignalingBatchResponse({
    required this.request,
    required this.classification,
  });

  final InternalSignalingBatchRequest request;
  final InternalSignalingClassification classification;

  @override
  String toString() =>
      'InternalSignalingBatchResponse(classification: '
      '${classification.name})';
}

SignalingSettingsResponse decodeSignalingSettingsResponse({
  required SignalingSettingsRequest request,
  required int statusCode,
  required Uint8List body,
  SignalingEndpointPolicy endpointPolicy = SignalingEndpointPolicy.production,
}) {
  final envelope = _decodeOcsEnvelope(
    statusCode: statusCode,
    body: body,
    path: r'$.ocs',
  );
  final classification = switch (statusCode) {
    200 => SignalingSettingsClassification.confirmed,
    401 => SignalingSettingsClassification.reauthenticationRequired,
    404 => SignalingSettingsClassification.roomRefreshRequired,
    >= 500 && <= 599 => SignalingSettingsClassification.serverError,
    _ => _responseFailure(r'$.http.status'),
  };
  if (classification != SignalingSettingsClassification.confirmed) {
    return SignalingSettingsResponse(
      request: request,
      classification: classification,
      settings: null,
    );
  }
  return SignalingSettingsResponse(
    request: request,
    classification: classification,
    settings: _parseSettings(envelope.data, endpointPolicy: endpointPolicy),
  );
}

InternalSignalingPullResponse decodeInternalSignalingPullResponse({
  required InternalSignalingPullRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  final envelope = _decodeOcsEnvelope(
    statusCode: statusCode,
    body: body,
    path: r'$.ocs',
  );
  final classification = _classifyInternal(statusCode);
  if (classification != InternalSignalingClassification.confirmed) {
    return InternalSignalingPullResponse(
      request: request,
      classification: classification,
      messages: const <SignalingPeerMessage>[],
      participants: const <SignalingParticipant>[],
    );
  }

  final items = requireList(
    envelope.data,
    path: r'$.ocs.data',
    code: TalkProtocolErrorCode.invalidSignalingResponse,
  );
  if (items.isEmpty || items.length > 4097) {
    _responseFailure(r'$.ocs.data');
  }
  final messages = <SignalingPeerMessage>[];
  List<SignalingParticipant>? participants;
  for (var index = 0; index < items.length; index++) {
    final path = '\$.ocs.data[$index]';
    final item = requireObject(
      items[index],
      path: path,
      code: TalkProtocolErrorCode.invalidSignalingResponse,
    );
    final type = requireString(
      item['type'],
      path: '$path.type',
      code: TalkProtocolErrorCode.invalidSignalingResponse,
      minLength: 1,
      maxLength: 64,
    );
    if (type == 'message') {
      if (participants != null) {
        _responseFailure(path);
      }
      final encoded = requireString(
        item['data'],
        path: '$path.data',
        code: TalkProtocolErrorCode.invalidSignalingResponse,
        minLength: 2,
        maxLength: maximumSignalingWireBytes,
      );
      messages.add(
        SignalingPeerMessage.fromJson(
          _decodeJsonString(encoded, path: '$path.data'),
          path: '$path.data',
        ),
      );
      continue;
    }
    if (type != 'usersInRoom' || participants != null) {
      _responseFailure('$path.type');
    }
    final values = requireList(
      item['data'],
      path: '$path.data',
      code: TalkProtocolErrorCode.invalidSignalingResponse,
    );
    if (values.length > maximumSignalingParticipants) {
      _responseFailure('$path.data');
    }
    participants = <SignalingParticipant>[
      for (
        var participantIndex = 0;
        participantIndex < values.length;
        participantIndex++
      )
        _parseInternalParticipant(
          values[participantIndex],
          path: '$path.data[$participantIndex]',
        ),
    ];
  }
  if (participants == null) {
    _responseFailure(r'$.ocs.data');
  }
  return InternalSignalingPullResponse(
    request: request,
    classification: classification,
    messages: messages,
    participants: participants,
  );
}

InternalSignalingBatchResponse decodeInternalSignalingBatchResponse({
  required InternalSignalingBatchRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  final envelope = _decodeOcsEnvelope(
    statusCode: statusCode,
    body: body,
    path: r'$.ocs',
  );
  final classification = _classifyInternal(statusCode);
  if (classification == InternalSignalingClassification.confirmed &&
      envelope.data != null &&
      !(envelope.data is List<Object?> &&
          (envelope.data! as List<Object?>).isEmpty)) {
    _responseFailure(r'$.ocs.data');
  }
  return InternalSignalingBatchResponse(
    request: request,
    classification: classification,
  );
}

SignalingSettings _parseSettings(
  Object? value, {
  required SignalingEndpointPolicy endpointPolicy,
}) {
  final data = requireObject(
    value,
    path: r'$.ocs.data',
    code: TalkProtocolErrorCode.invalidSignalingSettings,
  );
  final mode = requireString(
    data['signalingMode'],
    path: r'$.ocs.data.signalingMode',
    code: TalkProtocolErrorCode.invalidSignalingSettings,
    minLength: 1,
    maxLength: 32,
  );
  final userId = requireString(
    data['userId'],
    path: r'$.ocs.data.userId',
    code: TalkProtocolErrorCode.invalidSignalingSettings,
    maxLength: 4096,
  );
  requireBool(
    data['hideWarning'],
    path: r'$.ocs.data.hideWarning',
    code: TalkProtocolErrorCode.invalidSignalingSettings,
  );
  requireString(
    data['sipDialinInfo'],
    path: r'$.ocs.data.sipDialinInfo',
    code: TalkProtocolErrorCode.invalidSignalingSettings,
    maxLength: 16384,
  );
  final stun = _parseIceServers(
    data['stunservers'],
    path: r'$.ocs.data.stunservers',
    turn: false,
  );
  final turn = _parseIceServers(
    data['turnservers'],
    path: r'$.ocs.data.turnservers',
    turn: true,
  );
  final federation = data['federation'] == null
      ? null
      : _parseFederation(data['federation'], endpointPolicy: endpointPolicy);

  if (mode == 'internal') {
    requireString(
      data['server'],
      path: r'$.ocs.data.server',
      code: TalkProtocolErrorCode.invalidSignalingSettings,
      maxLength: 4096,
    );
    return InternalSignalingSettings(
      userId: userId,
      stunServers: stun,
      turnServers: turn,
      federation: federation,
    );
  }
  if (mode != 'external') {
    _settingsFailure(r'$.ocs.data.signalingMode');
  }
  final endpoint = HpbEndpoint.parse(data['server'], policy: endpointPolicy);
  final auth = data['helloAuthParams'] == null
      ? const <String, Object?>{}
      : requireObject(
          data['helloAuthParams'],
          path: r'$.ocs.data.helloAuthParams',
          code: TalkProtocolErrorCode.invalidSignalingSettings,
        );
  HpbV1Authentication? v1;
  final rawV1 = auth['1.0'];
  if (rawV1 != null) {
    final object = requireObject(
      rawV1,
      path: r'$.ocs.data.helloAuthParams[1.0]',
      code: TalkProtocolErrorCode.invalidSignalingSettings,
    );
    v1 = HpbV1Authentication(
      userId: requireString(
        object['userid'],
        path: r'$.ocs.data.helloAuthParams[1.0].userid',
        code: TalkProtocolErrorCode.invalidSignalingSettings,
        maxLength: 4096,
      ),
      ticket: requireString(
        object['ticket'],
        path: r'$.ocs.data.helloAuthParams[1.0].ticket',
        code: TalkProtocolErrorCode.invalidSignalingSettings,
        minLength: 1,
        maxLength: 16384,
      ),
    );
  } else if (data['ticket'] != null) {
    v1 = HpbV1Authentication(
      userId: userId,
      ticket: requireString(
        data['ticket'],
        path: r'$.ocs.data.ticket',
        code: TalkProtocolErrorCode.invalidSignalingSettings,
        minLength: 1,
        maxLength: 16384,
      ),
    );
  }
  HpbV2Authentication? v2;
  final rawV2 = auth['2.0'];
  if (rawV2 != null) {
    final object = requireObject(
      rawV2,
      path: r'$.ocs.data.helloAuthParams[2.0]',
      code: TalkProtocolErrorCode.invalidSignalingSettings,
    );
    v2 = HpbV2Authentication(
      token: requireString(
        object['token'],
        path: r'$.ocs.data.helloAuthParams[2.0].token',
        code: TalkProtocolErrorCode.invalidSignalingSettings,
        minLength: 1,
        maxLength: 32768,
      ),
    );
  }
  return ExternalSignalingSettings(
    userId: userId,
    stunServers: stun,
    turnServers: turn,
    federation: federation,
    endpoint: endpoint,
    v1Authentication: v1,
    v2Authentication: v2,
  );
}

List<IceServerConfiguration> _parseIceServers(
  Object? value, {
  required String path,
  required bool turn,
}) {
  final list = requireList(
    value,
    path: path,
    code: TalkProtocolErrorCode.invalidSignalingSettings,
  );
  if (list.length > 32) {
    _settingsFailure(path);
  }
  return <IceServerConfiguration>[
    for (var index = 0; index < list.length; index++)
      _parseIceServer(list[index], path: '$path[$index]', turn: turn),
  ];
}

IceServerConfiguration _parseIceServer(
  Object? value, {
  required String path,
  required bool turn,
}) {
  final object = requireObject(
    value,
    path: path,
    code: TalkProtocolErrorCode.invalidSignalingSettings,
  );
  final urls = requireList(
    object['urls'],
    path: '$path.urls',
    code: TalkProtocolErrorCode.invalidSignalingSettings,
  );
  return IceServerConfiguration(
    urls: <String>[
      for (var index = 0; index < urls.length; index++)
        requireString(
          urls[index],
          path: '$path.urls[$index]',
          code: TalkProtocolErrorCode.invalidSignalingSettings,
          minLength: 1,
          maxLength: 2048,
        ),
    ],
    username: turn
        ? requireString(
            object['username'],
            path: '$path.username',
            code: TalkProtocolErrorCode.invalidSignalingSettings,
            maxLength: 4096,
          )
        : null,
    credential: turn
        ? requireString(
            object['credential'],
            path: '$path.credential',
            code: TalkProtocolErrorCode.invalidSignalingSettings,
            minLength: 1,
            maxLength: 16384,
          )
        : null,
  );
}

FederationSignalingSettings _parseFederation(
  Object? value, {
  required SignalingEndpointPolicy endpointPolicy,
}) {
  final federation = requireObject(
    value,
    path: r'$.ocs.data.federation',
    code: TalkProtocolErrorCode.invalidSignalingSettings,
  );
  final auth = requireObject(
    federation['helloAuthParams'],
    path: r'$.ocs.data.federation.helloAuthParams',
    code: TalkProtocolErrorCode.invalidSignalingSettings,
  );
  return FederationSignalingSettings(
    endpoint: HpbEndpoint.parse(
      federation['server'],
      path: r'$.ocs.data.federation.server',
      policy: endpointPolicy,
    ),
    nextcloudServer: ServerBase.parse(
      requireString(
        federation['nextcloudServer'],
        path: r'$.ocs.data.federation.nextcloudServer',
        code: TalkProtocolErrorCode.invalidSignalingSettings,
        minLength: 1,
        maxLength: 4096,
      ),
    ),
    remoteRoomToken: ConversationToken.parse(
      federation['roomId'],
      path: r'$.ocs.data.federation.roomId',
      code: TalkProtocolErrorCode.invalidSignalingSettings,
    ),
    token: requireString(
      auth['token'],
      path: r'$.ocs.data.federation.helloAuthParams.token',
      code: TalkProtocolErrorCode.invalidSignalingSettings,
      minLength: 1,
      maxLength: 32768,
    ),
  );
}

SignalingParticipant _parseInternalParticipant(
  Object? value, {
  required String path,
}) {
  final participant = requireObject(
    value,
    path: path,
    code: TalkProtocolErrorCode.invalidSignalingResponse,
  );
  final sessionId = SignalingPeerId.parse(
    participant['sessionId'],
    path: '$path.sessionId',
  );
  requireInt(
    participant['roomId'],
    path: '$path.roomId',
    code: TalkProtocolErrorCode.invalidSignalingResponse,
    minimum: 1,
  );
  requireInt(
    participant['lastPing'],
    path: '$path.lastPing',
    code: TalkProtocolErrorCode.invalidSignalingResponse,
    minimum: 0,
  );
  return SignalingParticipant(
    peerId: sessionId,
    nextcloudSessionId: ConversationSessionId.parse(
      participant['sessionId'],
      path: '$path.sessionId',
      code: TalkProtocolErrorCode.invalidSignalingResponse,
    ),
    userId: requireString(
      participant['userId'],
      path: '$path.userId',
      code: TalkProtocolErrorCode.invalidSignalingResponse,
      maxLength: 4096,
    ),
    inCall: requireInt(
      participant['inCall'],
      path: '$path.inCall',
      code: TalkProtocolErrorCode.invalidSignalingResponse,
      minimum: 0,
    ),
    permissions: requireInt(
      participant['participantPermissions'],
      path: '$path.participantPermissions',
      code: TalkProtocolErrorCode.invalidSignalingResponse,
      minimum: 0,
    ),
    actorType: requireString(
      participant['actorType'],
      path: '$path.actorType',
      code: TalkProtocolErrorCode.invalidSignalingResponse,
      minLength: 1,
      maxLength: 128,
    ),
    actorId: requireString(
      participant['actorId'],
      path: '$path.actorId',
      code: TalkProtocolErrorCode.invalidSignalingResponse,
      maxLength: 4096,
    ),
    federated: false,
    features: const <String>[],
  );
}

InternalSignalingClassification _classifyInternal(int statusCode) =>
    switch (statusCode) {
      200 => InternalSignalingClassification.confirmed,
      400 => InternalSignalingClassification.profileRefreshRequired,
      401 => InternalSignalingClassification.reauthenticationRequired,
      404 => InternalSignalingClassification.roomRefreshRequired,
      409 => InternalSignalingClassification.sessionTerminated,
      >= 500 && <= 599 => InternalSignalingClassification.serverError,
      _ => _responseFailure(r'$.http.status'),
    };

_OcsEnvelope _decodeOcsEnvelope({
  required int statusCode,
  required Uint8List body,
  required String path,
}) {
  if (statusCode < 100 || statusCode > 599) {
    _responseFailure(r'$.http.status');
  }
  final root = requireObject(
    _decodeJsonBytes(body, path: r'$'),
    path: r'$',
    code: TalkProtocolErrorCode.invalidSignalingResponse,
  );
  final ocs = requireObject(
    root['ocs'],
    path: path,
    code: TalkProtocolErrorCode.invalidSignalingResponse,
  );
  final meta = requireObject(
    ocs['meta'],
    path: '$path.meta',
    code: TalkProtocolErrorCode.invalidSignalingResponse,
  );
  final status = requireString(
    meta['status'],
    path: '$path.meta.status',
    code: TalkProtocolErrorCode.invalidSignalingResponse,
    minLength: 1,
    maxLength: 32,
  );
  final ocsStatusCode = requireInt(
    meta['statuscode'],
    path: '$path.meta.statuscode',
    code: TalkProtocolErrorCode.invalidSignalingResponse,
    minimum: 0,
    maximum: 999,
  );
  requireString(
    meta['message'],
    path: '$path.meta.message',
    code: TalkProtocolErrorCode.invalidSignalingResponse,
    maxLength: 4096,
  );
  if (ocsStatusCode != statusCode ||
      (statusCode >= 200 && statusCode < 300
          ? status != 'ok'
          : status != 'failure')) {
    _responseFailure('$path.meta');
  }
  return _OcsEnvelope(ocs['data']);
}

Object? _decodeJsonBytes(Uint8List bytes, {required String path}) {
  if (bytes.isEmpty || bytes.length > maximumSignalingWireBytes) {
    _responseFailure(path);
  }
  try {
    final decoded = decodeJsonRejectingDuplicateMembers(
      utf8.decode(bytes, allowMalformed: false),
      code: TalkProtocolErrorCode.invalidSignalingResponse,
      path: path,
    );
    return JsonFreezeSession(
      maximumDepth: 32,
      maximumNodes: 12000,
      errorCode: TalkProtocolErrorCode.invalidSignalingResponse,
      errorPath: path,
    ).freeze(decoded);
  } on FormatException {
    _responseFailure(path);
  }
}

Object? _decodeJsonString(String value, {required String path}) {
  try {
    final decoded = decodeJsonRejectingDuplicateMembers(
      value,
      code: TalkProtocolErrorCode.invalidSignalingResponse,
      path: path,
    );
    return JsonFreezeSession(
      maximumDepth: 24,
      maximumNodes: 4096,
      errorCode: TalkProtocolErrorCode.invalidSignalingResponse,
      errorPath: path,
    ).freeze(decoded);
  } on FormatException {
    _responseFailure(path);
  }
}

final class _OcsEnvelope {
  const _OcsEnvelope(this.data);

  final Object? data;
}

Never _settingsFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidSignalingSettings, path);

Never _responseFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidSignalingResponse, path);
