import 'dart:convert';
import 'dart:typed_data';

import '../json_value.dart';
import '../protocol_exception.dart';
import 'request.dart';

const int botsMaximumCount = 5000;
const int botsMaximumWireBytes = 2 * 1024 * 1024;
const int _botsMaximumJsonDepth = 16;
const int _botsMaximumJsonNodes = 60000;

const TalkProtocolErrorCode _responseCode =
    TalkProtocolErrorCode.invalidBotsResponse;

enum BotState { disabled, enabled, noSetup }

final class TalkBot {
  const TalkBot._({
    required this.id,
    required this.name,
    required this.description,
    required this.state,
  });

  final int id;
  final String name;
  final String? description;
  final BotState state;

  @override
  String toString() => 'TalkBot(id: $id, state: ${state.name})';
}

TalkBot _parseBot(Object? json, {required String path}) {
  final object = requireObject(json, path: path, code: _responseCode);
  final rawState = requireInt(
    object['state'],
    path: '$path.state',
    code: _responseCode,
    minimum: 0,
    maximum: 2,
  );
  if (!object.containsKey('description')) {
    protocolFailure(_responseCode, '$path.description');
  }
  final rawDescription = object['description'];
  return TalkBot._(
    id: requireInt(
      object['id'],
      path: '$path.id',
      code: _responseCode,
      minimum: 0,
    ),
    name: requireString(
      object['name'],
      path: '$path.name',
      code: _responseCode,
      maxLength: 4096,
    ),
    description: rawDescription == null
        ? null
        : requireString(
            rawDescription,
            path: '$path.description',
            code: _responseCode,
            maxLength: 8192,
          ),
    state: BotState.values[rawState],
  );
}

sealed class BotManagementResponse {
  const BotManagementResponse(this.request);

  final BotManagementRequest request;
  int get statusCode;
}

final class BotListSuccess extends BotManagementResponse {
  BotListSuccess._({required ListBotsRequest request, required this.bots})
    : super(request);

  @override
  int get statusCode => 200;

  final List<TalkBot> bots;

  @override
  String toString() => 'BotListSuccess(count: ${bots.length})';
}

final class BotChangeSuccess extends BotManagementResponse {
  BotChangeSuccess._({
    required ChangeBotStateRequest request,
    required this.statusCode,
    required this.bot,
  }) : super(request);

  @override
  final int statusCode;
  final TalkBot bot;

  @override
  String toString() =>
      'BotChangeSuccess(statusCode: $statusCode, botId: ${bot.id})';
}

final class BotChangeRejected extends BotManagementResponse {
  const BotChangeRejected._({
    required ChangeBotStateRequest request,
    required this.reason,
  }) : super(request);

  @override
  int get statusCode => 400;

  final String? reason;

  @override
  String toString() => 'BotChangeRejected(reason: ${reason ?? 'unknown'})';
}

final class BotReauthenticationRequired extends BotManagementResponse {
  const BotReauthenticationRequired._(super.request);

  @override
  int get statusCode => 401;

  @override
  String toString() => 'BotReauthenticationRequired()';
}

final class BotForbidden extends BotManagementResponse {
  const BotForbidden._(super.request);

  @override
  int get statusCode => 403;

  @override
  String toString() => 'BotForbidden()';
}

final class BotRoomMissing extends BotManagementResponse {
  const BotRoomMissing._(super.request);

  @override
  int get statusCode => 404;

  @override
  String toString() => 'BotRoomMissing()';
}

enum BotHttpFailureKind { rateLimited, serviceUnavailable }

final class BotHttpFailure extends BotManagementResponse {
  const BotHttpFailure._({
    required BotManagementRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final BotHttpFailureKind kind;

  @override
  String toString() =>
      'BotHttpFailure(statusCode: $statusCode, kind: ${kind.name})';
}

BotManagementResponse decodeListBotsResponse({
  required ListBotsRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  final failure = _decodeSharedFailure(request, statusCode, body);
  if (failure != null) {
    return failure;
  }
  if (statusCode != 200) {
    protocolFailure(
      TalkProtocolErrorCode.unsupportedHttpStatus,
      r'$.statusCode',
    );
  }
  final rawBots = requireList(
    _decodeOcsEnvelope(body, requireSuccess: true),
    path: r'$.ocs.data',
    code: _responseCode,
  );
  if (rawBots.length > botsMaximumCount) {
    protocolFailure(_responseCode, r'$.ocs.data');
  }
  final bots = <TalkBot>[];
  final ids = <int>{};
  for (var index = 0; index < rawBots.length; index++) {
    final bot = _parseBot(
      rawBots[index],
      path:
          r'$.ocs.data['
          '$index]',
    );
    if (!ids.add(bot.id)) {
      protocolFailure(_responseCode, r'$.ocs.data');
    }
    bots.add(bot);
  }
  return BotListSuccess._(
    request: request,
    bots: List<TalkBot>.unmodifiable(bots),
  );
}

BotManagementResponse decodeChangeBotStateResponse({
  required ChangeBotStateRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  final failure = _decodeSharedFailure(request, statusCode, body);
  if (failure != null) {
    return failure;
  }
  if (statusCode == 400) {
    final data = _decodeOcsEnvelope(body, requireSuccess: false);
    return BotChangeRejected._(
      request: request,
      reason: _optionalRejectionReason(data),
    );
  }
  if (statusCode != 200 && !(request.enable && statusCode == 201)) {
    protocolFailure(
      TalkProtocolErrorCode.unsupportedHttpStatus,
      r'$.statusCode',
    );
  }
  final bot = _parseBot(
    _decodeOcsEnvelope(body, requireSuccess: true),
    path: r'$.ocs.data',
  );
  if (bot.id != request.botId ||
      (request.enable && bot.state == BotState.disabled) ||
      (!request.enable && bot.state != BotState.disabled)) {
    protocolFailure(_responseCode, r'$.ocs.data');
  }
  return BotChangeSuccess._(request: request, statusCode: statusCode, bot: bot);
}

BotManagementResponse? _decodeSharedFailure(
  BotManagementRequest request,
  int statusCode,
  Uint8List body,
) {
  switch (statusCode) {
    case 401:
      _decodeOcsEnvelope(body, requireSuccess: false);
      return BotReauthenticationRequired._(request);
    case 403:
      _decodeOcsEnvelope(body, requireSuccess: false);
      return BotForbidden._(request);
    case 404:
      _decodeOcsEnvelope(body, requireSuccess: false);
      return BotRoomMissing._(request);
    case 429:
      return BotHttpFailure._(
        request: request,
        statusCode: statusCode,
        kind: BotHttpFailureKind.rateLimited,
      );
    case 503:
      return BotHttpFailure._(
        request: request,
        statusCode: statusCode,
        kind: BotHttpFailureKind.serviceUnavailable,
      );
    default:
      return null;
  }
}

String? _optionalRejectionReason(Object? data) {
  if (data is! Map<String, Object?> || data['error'] == null) {
    return null;
  }
  return requireString(
    data['error'],
    path: r'$.ocs.data.error',
    code: _responseCode,
    minLength: 1,
    maxLength: 128,
  );
}

Object? _decodeOcsEnvelope(Uint8List body, {required bool requireSuccess}) {
  final decoded = _decodeJsonBytes(body);
  final root = requireObject(decoded, path: r'$', code: _responseCode);
  final ocs = requireObject(root['ocs'], path: r'$.ocs', code: _responseCode);
  final meta = requireObject(
    ocs['meta'],
    path: r'$.ocs.meta',
    code: _responseCode,
  );
  final status = requireString(
    meta['status'],
    path: r'$.ocs.meta.status',
    code: _responseCode,
    minLength: 1,
    maxLength: 32,
  );
  if (status != 'ok' && status != 'failure') {
    protocolFailure(_responseCode, r'$.ocs.meta.status');
  }
  if (requireSuccess && status != 'ok') {
    protocolFailure(_responseCode, r'$.ocs.meta.status');
  }
  requireInt(
    meta['statuscode'],
    path: r'$.ocs.meta.statuscode',
    code: _responseCode,
    minimum: 0,
    maximum: 999,
  );
  if (!ocs.containsKey('data')) {
    protocolFailure(_responseCode, r'$.ocs.data');
  }
  return ocs['data'];
}

Object? _decodeJsonBytes(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > botsMaximumWireBytes) {
    protocolFailure(_responseCode, r'$');
  }
  try {
    final decoded = decodeJsonRejectingDuplicateMembers(
      utf8.decode(bytes, allowMalformed: false),
      code: _responseCode,
      path: r'$',
    );
    return JsonFreezeSession(
      maximumDepth: _botsMaximumJsonDepth,
      maximumNodes: _botsMaximumJsonNodes,
      errorCode: _responseCode,
      errorPath: r'$',
    ).freeze(decoded);
  } on FormatException {
    protocolFailure(_responseCode, r'$');
  }
}
