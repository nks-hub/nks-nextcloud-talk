import 'dart:collection';

import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';

const String botsV1Path = '/ocs/v2.php/apps/spreed/api/v1/bot';
const String botsContractUserAgent =
    'com.nkshub.nextcloudtalk bots-contract/0.1';

const TalkProtocolErrorCode _requestCode =
    TalkProtocolErrorCode.invalidBotsRequest;

void _validateUserAgent(String userAgent) {
  if (userAgent.isEmpty ||
      userAgent.length > 256 ||
      userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
    protocolFailure(_requestCode, r'$.headers.userAgent');
  }
}

Uri _botUri(ServerBase server, ConversationToken roomToken, [int? botId]) {
  final suffix = botId == null ? '' : '/$botId';
  return server.uri.replace(
    path: '${server.basePath}$botsV1Path/${roomToken.value}$suffix',
    queryParameters: const {'format': 'json'},
  );
}

sealed class BotManagementRequest {
  const BotManagementRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.userAgent,
  });

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final String userAgent;

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri;
  String get httpMethod;
}

/// Reads every bot available to one conversation. Talk exposes this endpoint
/// only to logged-in owners and moderators when `bots-v1` is available.
final class ListBotsRequest extends BotManagementRequest {
  ListBotsRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    super.userAgent = botsContractUserAgent,
  }) {
    _validateUserAgent(userAgent);
  }

  @override
  String get httpMethod => 'GET';

  @override
  Uri get uri => _botUri(server, roomToken);

  @override
  String toString() => 'ListBotsRequest()';
}

/// Enables or disables one bot directly. Neither mutation is replayed: a
/// transport failure can leave the server state unknown, so callers refetch.
final class ChangeBotStateRequest extends BotManagementRequest {
  ChangeBotStateRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    required this.botId,
    required this.enable,
    super.userAgent = botsContractUserAgent,
  }) {
    if (botId < 0) {
      protocolFailure(_requestCode, r'$.path.botId');
    }
    _validateUserAgent(userAgent);
  }

  final int botId;
  final bool enable;

  @override
  String get httpMethod => enable ? 'POST' : 'DELETE';

  @override
  Uri get uri => _botUri(server, roomToken, botId);

  @override
  String toString() => 'ChangeBotStateRequest(botId: $botId, enable: $enable)';
}
