import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_room_pane.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

/// Talk features that allow sending text. Dropping `chat-reference-id` is the
/// documented way to make the send path refuse the operation up front.
const _sendableFeatures = <String>[
  'conversation-v4',
  'chat-v2',
  'chat-reference-id',
];

/// Bounded replacement for `pumpAndSettle`.
///
/// The chat pane keeps an indeterminate sync progress bar on screen while its
/// foreground loop is running, so `pumpAndSettle` can never return here. A
/// fixed number of pumps is enough for the sheet and snack bar transitions and
/// cannot hang the suite.
Future<void> settle(WidgetTester tester) async {
  for (var index = 0; index < 12; index++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Lets the real Drift and HTTP work behind a send finish before pumping.
///
/// `testWidgets` runs on a fake clock, so the durable outbox round trip needs
/// `runAsync` to make progress at all.
Future<void> flush(WidgetTester tester) async {
  for (var index = 0; index < 6; index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 120));
  }
  await settle(tester);
}

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;
  late StoredAccount account;
  late CachedConversation source;
  late List<String> postedRooms;
  late List<String> postedMessages;

  setUp(() async {
    postedRooms = <String>[];
    postedMessages = <String>[];
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
    await _insertConversation(
      database,
      accountId: account.id,
      token: 'rooma123',
      displayName: 'Source room',
      lastActivity: 1724300300,
    );
    await _insertConversation(
      database,
      accountId: account.id,
      token: 'roomb456',
      displayName: 'Target room',
      lastActivity: 1724300200,
    );
    await _insertConversation(
      database,
      accountId: account.id,
      token: 'roomc789',
      displayName: 'Announcement room',
      lastActivity: 1724300100,
      readOnly: 1,
    );
    source = await (database.select(
      database.cachedConversations,
    )..where((row) => row.token.equals('rooma123'))).getSingle();
    await database
        .into(database.cachedChatMessages)
        .insert(
          CachedChatMessagesCompanion.insert(
            accountId: account.id,
            roomToken: source.token,
            messageId: 10,
            actorType: 'users',
            actorId: 'someone-else',
            actorDisplayName: 'Other person',
            timestamp: 1724300000,
            systemMessage: '',
            messageType: 'comment',
            referenceId: 'fixture-reference',
            displayText: 'Cached hello',
            deleted: false,
            rawJson: '{}',
          ),
        );
  });

  tearDown(() => database.close());

  HttpNextcloudApi buildApi({
    List<String> talkFeatures = _sendableFeatures,
  }) {
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(capabilitiesJson(talkFeatures: talkFeatures)),
            200,
          );
        }
        if (request.method == 'POST') {
          postedRooms.add(request.url.pathSegments.last);
          postedMessages.add(request.bodyFields['message']!);
          return http.Response(
            jsonEncode(
              _sendResponse(
                referenceId: request.bodyFields['referenceId']!,
                message: request.bodyFields['message']!,
              ),
            ),
            201,
            headers: const <String, String>{'X-Chat-Last-Common-Read': '110'},
          );
        }
        // The room's own live sync is refused with a status the chat service
        // maps to a terminal error, so the foreground sync loop parks itself.
        // A loop that kept succeeding would re-render every second and
        // `pumpAndSettle` would never settle.
        return http.Response('', 403);
      }),
    );
    addTearDown(api.close);
    return api;
  }

  Widget app({required HttpNextcloudApi api}) {
    return ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(api),
        // Forwarding never touches attachment transport; resolving the
        // dependency as unavailable keeps the media buttons settled instead of
        // spinning forever.
        chatAttachmentDependenciesProvider.overrideWith(
          (ref, key) => Future<ChatAttachmentDependencies>.error(
            StateError('attachment dependencies are not wired in this suite'),
            StackTrace.empty,
          ),
        ),
      ],
      child: localizedTestApp(
        home: ChatRoomScreen(account: account, conversation: source),
      ),
    );
  }

  Future<void> openForwardPicker(WidgetTester tester) async {
    await tester.longPress(find.byKey(const Key('chat-message-target-10')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('message-action-forward')));
    await settle(tester);
  }

  testWidgets('forwards the message text into the picked conversation', (
    tester,
  ) async {
    await tester.pumpWidget(app(api: buildApi()));
    await settle(tester);

    await openForwardPicker(tester);

    expect(find.byKey(const Key('chat-forward-sheet')), findsOneWidget);
    expect(find.byKey(const Key('chat-forward-empty')), findsNothing);
    // Neither the room the message already lives in nor a read-only room is
    // ever offered as a forward target.
    expect(
      find.byKey(const Key('chat-forward-conversation-rooma123')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('chat-forward-conversation-roomc789')),
      findsNothing,
    );
    final target = find.byKey(const Key('chat-forward-conversation-roomb456'));
    expect(target, findsOneWidget);

    await tester.tap(target);
    await flush(tester);

    expect(postedRooms, ['roomb456']);
    expect(postedMessages, ['Cached hello']);
    expect(find.byKey(const Key('chat-forward-success')), findsOneWidget);
    expect(find.text('Message forwarded to Target room'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a refused forward reports the error instead of a false success', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        api: buildApi(
          talkFeatures: const <String>['conversation-v4', 'chat-v2'],
        ),
      ),
    );
    await settle(tester);

    await openForwardPicker(tester);
    await tester.tap(
      find.byKey(const Key('chat-forward-conversation-roomb456')),
    );
    await flush(tester);

    expect(postedRooms, isEmpty);
    expect(find.byKey(const Key('chat-forward-failure')), findsOneWidget);
    expect(find.byKey(const Key('chat-forward-success')), findsNothing);
    expect(
      find.text('The message could not be forwarded.'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

}

Future<void> _insertConversation(
  AppDatabase database, {
  required String accountId,
  required String token,
  required String displayName,
  required int lastActivity,
  int readOnly = 0,
}) async {
  final room = _roomJson(
    token: token,
    displayName: displayName,
    lastActivity: lastActivity,
    readOnly: readOnly,
  );
  final parsed = ConversationRoom.fromJson(room);
  await database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: accountId,
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
          // Avatar loading is out of scope here and would otherwise issue real
          // network requests from the list rows.
          avatarVersion: const Value(''),
          isCustomAvatar: const Value(false),
          rawJson: jsonEncode(room),
        ),
      );
}

Map<String, Object?> _roomJson({
  required String token,
  required String displayName,
  required int lastActivity,
  required int readOnly,
}) {
  final root =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final room = Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
  room['token'] = token;
  room['displayName'] = displayName;
  room['name'] = token;
  room['lastActivity'] = lastActivity;
  room['readOnly'] = readOnly;
  final lastMessage = room['lastMessage'];
  if (lastMessage is Map<String, Object?>) {
    room['lastMessage'] = Map<String, Object?>.from(lastMessage)
      ..['token'] = token;
  }
  return room;
}

Map<String, Object?> _sendResponse({
  required String referenceId,
  required String message,
}) {
  final response =
      readFixtureJson('chat-messages/fixtures/send-success.response.json')!
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  data['referenceId'] = referenceId;
  data['message'] = message;
  return response;
}
