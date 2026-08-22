import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';

void main() {
  final accountId = AccountId.parse('release-account');
  final server = ServerBase.parse('https://cloud.example.invalid');
  final roomToken = ConversationToken.parse(
    'rooma123',
    path: r'$.roomToken',
    code: TalkProtocolErrorCode.invalidChatRequest,
  );
  final request = ChatFetchRequest(
    accountId: accountId,
    requestId: ChatRequestId.parse('release-request'),
    server: server,
    roomToken: roomToken,
    profile: ChatCapabilityProfile.fromTalkFeatures(<Object?>[
      'chat-v2',
    ], federated: false),
    direction: ChatFetchDirection.future,
    cursor: ChatCursor.parse('0'),
    lastCommonRead: ChatCursor.parse('0'),
    limit: 1,
    includeLastKnown: false,
    timeoutSeconds: 0,
    interactive: true,
  );
  final body = Uint8List.fromList(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'ocs': <String, Object?>{
          'meta': <String, Object?>{
            'status': 'ok',
            'statuscode': 200,
            'message': 'OK',
          },
          'data': <Object?>[],
        },
      }),
    ),
  );
  final response = decodeChatGetResponse(
    request: request,
    statusCode: 200,
    body: body,
    headers: ChatResponseHeaders.fromMap(const {'X-Chat-Last-Given': '0'}),
  );
  if (response.classification != ChatGetClassification.invisibleCursorAdvance) {
    stderr.writeln('Release chat response classification failed.');
    exitCode = 1;
  }
}
