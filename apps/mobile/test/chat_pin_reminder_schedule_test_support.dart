part of 'chat_pin_reminder_schedule_test.dart';

/// Everything pin, reminder and scheduled send need, plus what the room pane
/// itself needs to render at all.
const _fullFeatures = <String>[
  'conversation-v4',
  'chat-v2',
  'chat-reference-id',
  'pinned-messages',
  'remind-me-later',
];

late AppDatabase database;
late AccountRepository accounts;
late MemoryCredentialVault vault;
late StoredAccount account;
late List<String> requestLog;

Future<void> setUpPinReminderScheduleHarness() async {
  requestLog = <String>[];
  database = openTestDatabase();
  accounts = AccountRepository(database);
  vault = MemoryCredentialVault()..values['account-a'] = 'fixture-password';
  account = await accounts.upsertAccount(
    accountId: 'account-a',
    serverUrl: 'https://cloud.example.invalid',
    loginName: 'fixture-user',
    serverProductName: 'Nextcloud',
    talkFeatures: const {},
    createdAt: DateTime.utc(2026, 1, 1),
  );
}

Future<void> tearDownPinReminderScheduleHarness() => database.close();

/// Bounded replacement for `pumpAndSettle`: the pane keeps an indeterminate
/// sync progress bar on screen while its foreground loop runs, so settling can
/// never complete here. Real async turns let Drift and HTTP finish between
/// frames, matching the lifecycle used by the working message-jump harness.
Future<void> settle(WidgetTester tester) async {
  for (var index = 0; index < 12; index++) {
    await tester.pump(const Duration(milliseconds: 120));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
}

/// Lets the real Drift and HTTP work behind an action finish. `testWidgets`
/// runs on a fake clock, so a round trip needs `runAsync` to progress.
Future<void> flush(WidgetTester tester) async {
  for (var index = 0; index < 8; index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 120));
  }
  await settle(tester);
}

Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    if (condition()) {
      return;
    }
  }
  fail('Condition was not reached');
}

Future<void> teardownTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
}

Future<CachedConversation> insertRoom({
  int lastPinnedId = 0,
  int hiddenPinnedId = 0,
  int hasScheduledMessages = 0,
  int participantType = 3,
  List<String>? localFeatures,
}) async {
  final room = _roomJson(
    lastPinnedId: lastPinnedId,
    hiddenPinnedId: hiddenPinnedId,
    hasScheduledMessages: hasScheduledMessages,
    participantType: participantType,
  );
  final parsed = ConversationRoom.fromJson(room);
  await database
      .into(database.cachedConversations)
      .insertOnConflictUpdate(
        CachedConversationsCompanion.insert(
          accountId: account.id,
          token: parsed.token.value,
          displayName: parsed.displayName,
          description: parsed.description,
          lastActivity: parsed.lastActivity,
          unreadMessages: parsed.unreadMessages,
          favorite: parsed.isFavorite,
          readOnly: Value(parsed.readOnly),
          roomType: Value(parsed.type),
          roomName: Value(parsed.name),
          objectType: Value(parsed.objectType),
          // Avatars are out of scope and would issue real network requests.
          avatarVersion: const Value(''),
          isCustomAvatar: const Value(false),
          rawJson: jsonEncode(room),
        ),
      );
  // A scope that has already synchronized once makes the pane skip the
  // initial history page, so every test below drives exactly the requests it
  // asserts on and the timeline never moves underneath it. The block spans
  // every message id these tests use, which is what keeps a cached row
  // visible: the pane only shows messages a confirmed block covers.
  await database
      .into(database.chatScopes)
      .insertOnConflictUpdate(
        ChatScopesCompanion.insert(
          accountId: account.id,
          roomToken: 'rooma123',
          scopeKey: 'root',
          historyCursor: '1',
          futureCursor: '1000',
          lastCommonRead: '1000',
          lastReadMessage: 0,
          unreadMessages: 0,
          hasHistory: false,
          futureConverged: false,
          blocksJson: '[["1","1000"]]',
          lastSyncedAtMillis: const Value(1724300000000),
        ),
      );
  return (database.select(
    database.cachedConversations,
  )..where((row) => row.token.equals('rooma123'))).getSingle();
}

Future<void> insertMessage({
  int messageId = 10,
  String text = 'Cached hello',
}) async {
  await database
      .into(database.cachedChatMessages)
      .insertOnConflictUpdate(
        CachedChatMessagesCompanion.insert(
          accountId: account.id,
          roomToken: 'rooma123',
          messageId: messageId,
          actorType: 'users',
          actorId: 'someone-else',
          actorDisplayName: 'Other person',
          timestamp: 1724300000,
          systemMessage: '',
          messageType: 'comment',
          referenceId: 'fixture-reference-$messageId',
          displayText: text,
          deleted: false,
          rawJson: jsonEncode(_messageJson(messageId: messageId, text: text)),
        ),
      );
}

HttpNextcloudApi buildApi({
  List<String> talkFeatures = _fullFeatures,
  List<String> localFeatures = const <String>[],
  http.Response Function(http.Request request)? onRichChat,
}) {
  final api = HttpNextcloudApi(
    client: MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/cloud/capabilities')) {
        return http.Response(
          jsonEncode(
            _capabilitiesJson(
              talkFeatures: talkFeatures,
              localFeatures: localFeatures,
            ),
          ),
          200,
        );
      }
      // Avatars are out of scope here and must be answered explicitly:
      // letting them fall through to the "nothing new" default leaves the
      // avatar loader waiting on a body that never comes.
      if (path.contains('/avatar')) {
        return http.Response('', 404);
      }
      if (path.contains('/pin') ||
          path.contains('/reminder') ||
          path.contains('/schedule')) {
        requestLog.add('${request.method} $path');
        if (onRichChat != null) {
          return onRichChat(request);
        }
        return http.Response(jsonEncode(_emptyOcs(200)), 200);
      }
      // The room's own live sync always reports "nothing new", so the
      // timeline never moves underneath a test and the foreground loop
      // has nothing to re-render.
      return http.Response('', 403);
    }),
  );
  addTearDown(api.close);
  return api;
}

Widget wrap({required HttpNextcloudApi api, required Widget home}) {
  return ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      credentialVaultProvider.overrideWithValue(vault),
      nextcloudApiProvider.overrideWithValue(api),
      // None of these features touch attachment transport; resolving the
      // dependency as unavailable keeps the media buttons settled instead of
      // spinning forever.
      chatAttachmentDependenciesProvider.overrideWith(
        (ref, key) => Future<ChatAttachmentDependencies>.error(
          StateError('attachment dependencies are not wired in this suite'),
          StackTrace.empty,
        ),
      ),
    ],
    child: localizedTestApp(home: home),
  );
}

CachedConversation _bareConversation(String rawJson) => CachedConversation(
  accountId: 'account-a',
  token: 'rooma123',
  displayName: 'Room',
  description: '',
  lastActivity: 0,
  unreadMessages: 0,
  favorite: false,
  readOnly: 0,
  roomType: 2,
  roomName: 'room',
  objectType: '',
  avatarVersion: '',
  isCustomAvatar: false,
  isArchived: false,
  rawJson: rawJson,
);

Map<String, Object?> _capabilitiesJson({
  required List<String> talkFeatures,
  required List<String> localFeatures,
}) {
  final json = capabilitiesJson(talkFeatures: talkFeatures);
  final ocs = json['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  final capabilities = data['capabilities']! as Map<String, Object?>;
  final spreed = capabilities['spreed']! as Map<String, Object?>;
  spreed['features-local'] = <Object?>[...localFeatures];
  return json;
}

Map<String, Object?> _ocs(int statusCode, Object? data) => <String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': statusCode,
      'message': 'OK',
    },
    'data': data,
  },
};

Map<String, Object?> _emptyOcs(int statusCode) =>
    _ocs(statusCode, <String, Object?>{});

Map<String, Object?> _failureOcs(int statusCode) => <String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'failure',
      'statuscode': statusCode,
      'message': 'Not found',
    },
    'data': <String, Object?>{'error': 'message'},
  },
};

Map<String, Object?> _reminderOcs(int statusCode, int timestamp) =>
    _ocs(statusCode, <String, Object?>{
      'userId': 'fixture-user',
      'token': 'rooma123',
      'messageId': 10,
      'timestamp': timestamp,
    });

Map<String, Object?> _scheduleOcs(int statusCode, int sendAt) =>
    _ocs(statusCode, _scheduledMessageJson(sendAt));

Map<String, Object?> _scheduledMessageJson(int sendAt) => <String, Object?>{
  'id': '77',
  'actorId': 'fixture-user',
  'actorType': 'users',
  'threadId': 0,
  'message': 'Scheduled hello',
  'messageType': 'comment',
  'createdAt': 1724300000,
  'sendAt': sendAt,
  'silent': false,
};

/// A pin answers with the system message about the pinning, carrying the
/// pinned message itself as its parent.
Map<String, Object?> _pinResponse() => _ocs(200, <String, Object?>{
  ..._messageJson(messageId: 11, text: '', systemMessage: 'message_pinned'),
  'parent': _messageJson(messageId: 10, text: 'Cached hello'),
});

Map<String, Object?> _messageJson({
  required int messageId,
  required String text,
  String systemMessage = '',
}) => <String, Object?>{
  'id': messageId,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'someone-else',
  'actorDisplayName': 'Other person',
  'timestamp': 1724300000,
  'message': text,
  'messageParameters': <String, Object?>{},
  'messageType': systemMessage.isEmpty ? 'comment' : 'system',
  'systemMessage': systemMessage,
  'expirationTimestamp': 0,
  'referenceId': 'fixture-reference-$messageId',
  'isReplyable': true,
  'markdown': true,
  'reactions': <String, Object?>{},
  'reactionsSelf': <Object?>[],
  'threadId': messageId,
};

Map<String, Object?> _roomJson({
  required int lastPinnedId,
  required int hiddenPinnedId,
  required int hasScheduledMessages,
  required int participantType,
}) {
  final response =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final room = jsonDecode(jsonEncode(rooms.first)) as Map<String, Object?>;
  room['token'] = 'rooma123';
  room['readOnly'] = 0;
  room['lastPinnedId'] = lastPinnedId;
  room['hiddenPinnedId'] = hiddenPinnedId;
  room['hasScheduledMessages'] = hasScheduledMessages;
  room['participantType'] = participantType;
  // PERMISSIONS_MAX_DEFAULT: every permission granted without an override.
  room['permissions'] = 510;
  room['attendeePermissions'] = 0;
  room.remove('remoteServer');
  return room;
}
