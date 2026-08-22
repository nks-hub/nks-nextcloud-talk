import 'dart:collection';

import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';

const String conversationV4Path = '/ocs/v2.php/apps/spreed/api/v4/room';
const String conversationContractUserAgent =
    'com.nkshub.nextcloudtalk conversation-list-contract/0.1';

enum ConversationFetchMode { full, incremental }

final class ConversationListRequest {
  ConversationListRequest({
    required this.accountId,
    required this.requestId,
    required this.server,
    required this.mode,
    required this.includeLastMessage,
    this.cursor,
    this.userAgent = conversationContractUserAgent,
  }) {
    if (mode == ConversationFetchMode.full && cursor != null) {
      protocolFailure(
        TalkProtocolErrorCode.invalidConversationRequest,
        r'$.query.modifiedSince',
      );
    }
    if (mode == ConversationFetchMode.incremental && cursor == null) {
      protocolFailure(
        TalkProtocolErrorCode.invalidConversationRequest,
        r'$.query.modifiedSince',
      );
    }
    if (userAgent.isEmpty ||
        userAgent.length > 256 ||
        userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidConversationRequest,
        r'$.headers.userAgent',
      );
    }
  }

  final AccountId accountId;
  final ConversationRequestId requestId;
  final ServerBase server;
  final ConversationFetchMode mode;
  final bool includeLastMessage;
  final ConversationCursor? cursor;
  final String userAgent;

  Map<String, String> get queryParameters => UnmodifiableMapView({
    'format': 'json',
    'noStatusUpdate': '1',
    'includeStatus': 'false',
    if (mode == ConversationFetchMode.incremental)
      'modifiedSince': cursor!.value,
    'includeLastMessage': includeLastMessage.toString(),
  });

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri {
    return server.uri.replace(
      path: '${server.basePath}$conversationV4Path',
      queryParameters: queryParameters,
    );
  }

  @override
  String toString() =>
      'ConversationListRequest(mode: ${mode.name}, '
      'includeLastMessage: $includeLastMessage)';
}
