part of 'chat_service_integration_test.dart';

final class _ChatServiceIntegrationSuite {
  late AppDatabase database;
  late AccountRepository accounts;
  late ChatRepository chat;
  late MemoryCredentialVault credentials;

  Future<void> prepare() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    chat = ChatRepository(database);
    credentials = MemoryCredentialVault();

    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    credentials.values[account.id] = 'fixture-app-password-never-use';

    final roomJson = _conversationRoomJson();
    final room = ConversationRoom.fromJson(roomJson);
    await database
        .into(database.cachedConversations)
        .insert(
          CachedConversationsCompanion.insert(
            accountId: account.id,
            token: room.token.value,
            displayName: room.displayName,
            description: room.description,
            lastActivity: room.lastActivity,
            unreadMessages: room.unreadMessages,
            favorite: room.isFavorite,
            readOnly: Value(room.readOnly),
            roomType: Value(room.type),
            roomName: Value(room.name),
            objectType: Value(room.objectType),
            avatarVersion: Value(room.avatarVersion),
            isCustomAvatar: Value(room.isCustomAvatar),
            rawJson: jsonEncode(roomJson),
          ),
        );
  }

  Future<void> dispose() => database.close();
}

Future<void> _cacheThreadRoot(
  AppDatabase database, {
  bool? isThread,
  int? storedThreadId = 109,
  int? threadReplies,
}) async {
  final rawJson = <String, Object?>{
    'id': 109,
    'token': 'rooma123',
    'actorType': 'users',
    'actorId': 'user-a',
    'actorDisplayName': 'User A',
    'timestamp': 1770000109,
    'systemMessage': '',
    'messageType': 'comment',
    'isReplyable': true,
    'referenceId': '',
    'message': 'Cached thread root',
    'messageParameters': <String, Object?>{},
    'markdown': true,
    'reactions': <String, Object?>{},
    'threadId': storedThreadId,
    'isThread': ?isThread,
    'threadTitle': isThread == true ? 'Cached named thread' : null,
    'threadReplies': ?threadReplies,
  };
  await database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: 'account-a',
          roomToken: 'rooma123',
          messageId: 109,
          actorType: 'users',
          actorId: 'user-a',
          actorDisplayName: 'User A',
          timestamp: 1770000109,
          systemMessage: '',
          messageType: 'comment',
          referenceId: '',
          displayText: 'Cached thread root',
          deleted: false,
          threadId: Value(storedThreadId),
          rawJson: jsonEncode(rawJson),
        ),
      );
}

Map<String, Object?> _chatCapabilities({
  List<String> talkFeatures = const <String>[
    'conversation-v4',
    'chat-v2',
    'chat-reference-id',
  ],
}) => capabilitiesJson(talkFeatures: talkFeatures);

const _giphyResourceUrl = 'https://giphy.com/gifs/waving-cat-fixture123';

Map<String, Object?> _conversationRoomJson() {
  final root =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final room = Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
  final lastMessage = Map<String, Object?>.from(
    room['lastMessage']! as Map<String, Object?>,
  );
  lastMessage['id'] = 109;
  room['lastMessage'] = lastMessage;
  return room;
}

Map<String, Object?> _sendResponse({
  required String referenceId,
  required String message,
  int? threadId,
  int? threadReplies,
}) {
  final response =
      readFixtureJson(
            threadId == null
                ? 'chat-messages/fixtures/send-success.response.json'
                : 'chat-messages/fixtures/send-named-thread-success.response.json',
          )!
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  data['referenceId'] = referenceId;
  data['message'] = message;
  if (threadId != null) {
    data['threadId'] = threadId;
  }
  if (threadReplies != null) {
    data['threadReplies'] = threadReplies;
  }
  return response;
}

Map<String, Object?> _sendReplyResponse({
  required String referenceId,
  required String message,
  required int replyTo,
}) {
  final response =
      readFixtureJson(
            'chat-messages/fixtures/send-reply-success.response.json',
          )!
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  final parent = data['parent']! as Map<String, Object?>;
  data['referenceId'] = referenceId;
  data['message'] = message;
  data['threadId'] = replyTo;
  parent['id'] = replyTo;
  parent['threadId'] = replyTo;
  return response;
}

Map<String, Object?> _externalMessageResponse({
  required int messageId,
  required int timestamp,
  required String message,
  int? threadId,
  String? referenceId,
}) {
  final response =
      jsonDecode(
            jsonEncode(
              readFixtureJson(
                'chat-messages/fixtures/chat-future.response.json',
              ),
            ),
          )!
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final messages = ocs['data']! as List<Object?>;
  final external = Map<String, Object?>.from(
    messages.first! as Map<String, Object?>,
  );
  external['id'] = messageId;
  external['timestamp'] = timestamp;
  external['message'] = message;
  external['messageParameters'] = <String, Object?>{};
  if (referenceId != null) {
    external['referenceId'] = referenceId;
  }
  if (threadId != null) {
    external['threadId'] = threadId;
  }
  ocs['data'] = <Object?>[external];
  return response;
}

http.StreamedResponse _streamedResponse(
  String body,
  int statusCode, {
  Map<String, String> headers = const <String, String>{},
}) {
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body)),
    statusCode,
    headers: headers,
  );
}
