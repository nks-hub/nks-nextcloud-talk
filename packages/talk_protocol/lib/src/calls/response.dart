import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../json_value.dart';
import '../protocol_exception.dart';
import 'models.dart';
import 'request.dart';

enum CallResponseClassification {
  confirmed,
  rejected,
  reauthenticationRequired,
  forbidden,
  sessionMissing,
  conflict,
  rateLimited,
  serverFailure,
}

final class CallRestResponse {
  const CallRestResponse._({
    required this.request,
    required this.statusCode,
    required this.classification,
    required this.peers,
    required this.errorCode,
  });

  final CallRestRequest request;
  final int statusCode;
  final CallResponseClassification classification;
  final List<CallPeer> peers;

  /// Bounded machine-readable Talk error, never included in [toString].
  final String? errorCode;

  bool get ownSessionPresent => peers.any(
    (peer) =>
        peer.sessionId == request.authority.nextcloudSessionId &&
        peer.roomToken == request.authority.roomToken,
  );

  @override
  String toString() =>
      'CallRestResponse(statusCode: $statusCode, '
      'classification: ${classification.name}, peers: ${peers.length}, '
      'sensitive: <redacted>)';
}

CallRestResponse decodeCallRestResponse({
  required CallRestRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  if (statusCode == 200) {
    final data = _decodeOcsData(body);
    final peers = request is CallPeersRequest
        ? _decodePeers(request, data)
        : const <CallPeer>[];
    return CallRestResponse._(
      request: request,
      statusCode: statusCode,
      classification: CallResponseClassification.confirmed,
      peers: peers,
      errorCode: null,
    );
  }

  final classification = switch (statusCode) {
    400 => CallResponseClassification.rejected,
    401 => CallResponseClassification.reauthenticationRequired,
    403 => CallResponseClassification.forbidden,
    404 => CallResponseClassification.sessionMissing,
    409 => CallResponseClassification.conflict,
    429 => CallResponseClassification.rateLimited,
    >= 500 && <= 599 => CallResponseClassification.serverFailure,
    _ => protocolFailure(
      TalkProtocolErrorCode.unsupportedHttpStatus,
      r'$.statusCode',
    ),
  };
  return CallRestResponse._(
    request: request,
    statusCode: statusCode,
    classification: classification,
    peers: const <CallPeer>[],
    errorCode: statusCode == 400 ? _optionalErrorCode(body) : null,
  );
}

Object? _decodeOcsData(Uint8List body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(body));
  } on Object {
    protocolFailure(TalkProtocolErrorCode.invalidCallResponse, r'$.body');
  }
  final root = requireObject(
    decoded,
    path: r'$',
    code: TalkProtocolErrorCode.invalidCallResponse,
  );
  final ocs = requireObject(
    root['ocs'],
    path: r'$.ocs',
    code: TalkProtocolErrorCode.invalidCallResponse,
  );
  final meta = requireObject(
    ocs['meta'],
    path: r'$.ocs.meta',
    code: TalkProtocolErrorCode.invalidCallResponse,
  );
  if (requireString(
        meta['status'],
        path: r'$.ocs.meta.status',
        code: TalkProtocolErrorCode.invalidCallResponse,
      ) !=
      'ok') {
    protocolFailure(TalkProtocolErrorCode.invalidCallResponse, r'$.ocs.meta');
  }
  if (requireInt(
        meta['statuscode'],
        path: r'$.ocs.meta.statuscode',
        code: TalkProtocolErrorCode.invalidCallResponse,
      ) !=
      200) {
    protocolFailure(TalkProtocolErrorCode.invalidCallResponse, r'$.ocs.meta');
  }
  requireString(
    meta['message'],
    path: r'$.ocs.meta.message',
    code: TalkProtocolErrorCode.invalidCallResponse,
    maxLength: 4096,
  );
  return ocs['data'];
}

List<CallPeer> _decodePeers(CallPeersRequest request, Object? data) {
  final rawPeers = requireList(
    data,
    path: r'$.ocs.data',
    code: TalkProtocolErrorCode.invalidCallResponse,
  );
  if (rawPeers.length > 512) {
    protocolFailure(TalkProtocolErrorCode.invalidCallResponse, r'$.ocs.data');
  }
  final peers = <CallPeer>[];
  final sessions = <String>{};
  for (var index = 0; index < rawPeers.length; index++) {
    final peer = CallPeer.fromJson(rawPeers[index], index: index);
    if (peer.roomToken != request.roomToken ||
        !sessions.add(peer.sessionId.value)) {
      protocolFailure(TalkProtocolErrorCode.invalidCallResponse, r'$.ocs.data');
    }
    peers.add(peer);
  }
  return UnmodifiableListView(peers);
}

String? _optionalErrorCode(Uint8List body) {
  if (body.isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(utf8.decode(body));
    final root = requireObject(
      decoded,
      path: r'$',
      code: TalkProtocolErrorCode.invalidCallResponse,
    );
    final ocs = requireObject(
      root['ocs'],
      path: r'$.ocs',
      code: TalkProtocolErrorCode.invalidCallResponse,
    );
    final meta = requireObject(
      ocs['meta'],
      path: r'$.ocs.meta',
      code: TalkProtocolErrorCode.invalidCallResponse,
    );
    if (requireString(
          meta['status'],
          path: r'$.ocs.meta.status',
          code: TalkProtocolErrorCode.invalidCallResponse,
        ) !=
        'failure') {
      return null;
    }
    requireInt(
      meta['statuscode'],
      path: r'$.ocs.meta.statuscode',
      code: TalkProtocolErrorCode.invalidCallResponse,
      minimum: 400,
      maximum: 499,
    );
    final data = ocs['data'];
    if (data is! Map<String, Object?> || data['error'] == null) {
      return null;
    }
    return requireString(
      data['error'],
      path: r'$.ocs.data.error',
      code: TalkProtocolErrorCode.invalidCallResponse,
      minLength: 1,
      maxLength: 128,
    );
  } on FormatException {
    return null;
  } on TalkProtocolException {
    return null;
  }
}
