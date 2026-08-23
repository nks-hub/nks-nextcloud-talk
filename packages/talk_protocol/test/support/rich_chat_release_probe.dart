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
    code: TalkProtocolErrorCode.invalidRichChatRequest,
  );
  final profile = RichChatCapabilityProfile.fromTalkFeatures(
    talkFeatures: <Object?>['chat-v2', 'reactions'],
    talkLocalFeatures: const <Object?>[],
    federated: false,
    moderator: false,
    participantPermissions: 0,
  );
  final request = RichChatRequest.addReaction(
    accountId: accountId,
    requestId: ChatRequestId.parse('release-rich-chat'),
    server: server,
    roomToken: roomToken,
    profile: profile,
    messageId: 120,
    reaction: '👍',
    actor: RichChatActorIdentity(actorType: 'users', actorId: 'user-a'),
  );
  final response = decodeRichChatResponse(
    request: request,
    statusCode: 201,
    body: Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'ocs': <String, Object?>{
            'meta': <String, Object?>{
              'status': 'ok',
              'statuscode': 201,
              'message': 'OK',
            },
            'data': <String, Object?>{
              '👍': <Object?>[
                <String, Object?>{
                  'actorDisplayName': 'User A',
                  'actorId': 'user-a',
                  'actorType': 'users',
                  'timestamp': 1787443200,
                },
              ],
            },
          },
        }),
      ),
    ),
  );
  final message = ChatMessage.fromJson(<String, Object?>{
    'id': 120,
    'token': 'rooma123',
    'actorType': 'users',
    'actorId': 'user-a',
    'actorDisplayName': 'User A',
    'timestamp': 1787440000,
    'systemMessage': '',
    'messageType': 'comment',
    'isReplyable': true,
    'referenceId': 'root-120',
    'message': 'Hello {user}',
    'messageParameters': <String, Object?>{
      'user': <String, Object?>{
        'type': 'user',
        'id': 'user-a',
        'name': 'User A',
      },
    },
    'markdown': true,
    'reactions': <String, Object?>{},
  });
  final chatAccount = ChatAccountState(
    accountId: accountId,
    server: server,
    lane: ChatAccountLane.ready,
    credentialGeneration: 1,
    capabilityGeneration: 1,
    scopes: const {},
    operations: const {},
  );
  final room = RichChatRoomState(
    roomToken: roomToken,
    messages: <int, ChatMessage>{120: message},
    threads: const {},
    reminders: const {},
    scheduledMessages: const {},
    lastMessageId: 120,
  );
  final snapshot = RichChatRuntimeSnapshot(
    chat: ChatRuntimeSnapshot(
      accounts: <AccountId, ChatAccountState>{accountId: chatAccount},
    ),
    accounts: <AccountId, RichChatAccountState>{
      accountId: RichChatAccountState(
        accountId: accountId,
        server: server,
        rooms: <ConversationToken, RichChatRoomState>{roomToken: room},
      ),
    },
  );
  final committed = planRichChatMerge(
    snapshot,
    response,
  ).plan!.commit(snapshot);
  final updated =
      committed.accounts[accountId]!.rooms[roomToken]!.messages[120]!;
  final document = renderRichChatMessage(
    message: updated.message,
    markdownEnabled: updated.markdown ?? false,
    parameters: updated.messageParameters,
    server: server,
  );
  final richObjects = document.nodes.where(
    (node) => node.kind == RichChatSemanticKind.richObject,
  );
  if (updated.reactions['👍'] != 1 ||
      updated.reactionsSelf.single != '👍' ||
      richObjects.length != 1) {
    stderr.writeln('Release rich-chat runtime verification failed.');
    exitCode = 1;
  }
}
