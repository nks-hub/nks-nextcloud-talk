import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_list_actions.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;
  late StoredAccount account;

  setUp(() async {
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
  });

  tearDown(() => database.close());

  Future<CachedConversation> insertConversation({
    required String token,
    bool isArchived = false,
    int unreadMessages = 0,
  }) async {
    final roomJson = Map<String, Object?>.from(_conversationRoomJson())
      ..['token'] = token
      ..['isArchived'] = isArchived
      ..['unreadMessages'] = unreadMessages;
    final lastMessage = roomJson['lastMessage'];
    if (lastMessage is Map<String, Object?>) {
      roomJson['lastMessage'] = Map<String, Object?>.from(lastMessage)
        ..['token'] = token;
    }
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
            isArchived: Value(room.isArchived),
            readOnly: Value(room.readOnly),
            roomType: Value(room.type),
            roomName: Value(room.name),
            objectType: Value(room.objectType),
            avatarVersion: Value(room.avatarVersion),
            isCustomAvatar: Value(room.isCustomAvatar),
            rawJson: jsonEncode(roomJson),
          ),
        );
    return (database.select(
      database.cachedConversations,
    )..where((conversation) => conversation.token.equals(token))).getSingle();
  }

  Widget app({
    required List<CachedConversation> conversations,
    required http.Client client,
  }) {
    final api = HttpNextcloudApi(client: client);
    return ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(api),
      ],
      child: localizedTestApp(
        home: Scaffold(
          body: ConversationListView(
            account: account,
            conversations: conversations,
            loading: false,
            onRefresh: () async {},
            onSelect: (_) {},
          ),
        ),
      ),
    );
  }

  http.Response ocsSuccess([Object? data = const <Object?>[]]) {
    return http.Response(
      jsonEncode({
        'ocs': {
          'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
          'data': data,
        },
      }),
      200,
    );
  }

  http.Response ocsFailure(int statusCode) {
    return http.Response(
      jsonEncode({
        'ocs': {
          'meta': {'status': 'failure', 'statuscode': statusCode},
          'data': <Object?>[],
        },
      }),
      statusCode,
    );
  }

  testWidgets(
    'long press offers mark-unread only for a read conversation, always offers archive',
    (tester) async {
      final read = await insertConversation(token: 'roomread');
      final unread = await insertConversation(
        token: 'roomunread',
        unreadMessages: 3,
      );

      await tester.pumpWidget(
        app(
          conversations: [read, unread],
          client: MockClient((request) async => http.Response('', 404)),
        ),
      );
      await tester.pump();

      await tester.longPress(find.byKey(const Key('conversation-tile-roomread')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('conversation-action-mark-unread')), findsOneWidget);
      expect(find.byKey(const Key('conversation-action-archive')), findsOneWidget);
      expect(find.text('Archive conversation'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await tester.longPress(find.byKey(const Key('conversation-tile-roomunread')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('conversation-action-mark-unread')), findsNothing);
      expect(find.byKey(const Key('conversation-action-archive')), findsOneWidget);

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('marking a conversation unread calls the chat read-marker endpoint', (
    tester,
  ) async {
    final conversation = await insertConversation(token: 'rooma');
    var markUnreadRequests = 0;

    await tester.pumpWidget(
      app(
        conversations: [conversation],
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(
                capabilitiesJson(
                  talkFeatures: const [
                    'conversation-v4',
                    'chat-v2',
                    'chat-read-marker',
                    'chat-unread',
                  ],
                ),
              ),
              200,
            );
          }
          if (request.method == 'DELETE' &&
              request.url.path.endsWith('/chat/rooma/read')) {
            markUnreadRequests++;
            return ocsSuccess(const {
              'token': 'rooma',
              'lastReadMessage': 5,
              'lastCommonReadMessage': 5,
              'unreadMessages': 1,
            });
          }
          return http.Response('', 404);
        }),
      ),
    );
    await tester.pump();

    await tester.longPress(find.byKey(const Key('conversation-tile-rooma')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conversation-action-mark-unread')));
    await _pumpUntil(tester, () => markUnreadRequests == 1);
    // The action triggers a best-effort background resync; let it settle
    // (it fails against the unmocked conversation-list endpoint and is
    // swallowed) before the database closes in tearDown.
    await _settle(tester);

    expect(markUnreadRequests, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('archiving a conversation calls the archive endpoint with POST', (
    tester,
  ) async {
    final conversation = await insertConversation(token: 'rooma');
    var archiveRequests = 0;

    await tester.pumpWidget(
      app(
        conversations: [conversation],
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(jsonEncode(capabilitiesJson()), 200);
          }
          if (request.url.path.endsWith('/archive')) {
            expect(request.method, 'POST');
            archiveRequests++;
            return ocsSuccess();
          }
          return http.Response('', 404);
        }),
      ),
    );
    await tester.pump();

    await tester.longPress(find.byKey(const Key('conversation-tile-rooma')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conversation-action-archive')));
    await _pumpUntil(tester, () => archiveRequests == 1);
    await _settle(tester);

    expect(archiveRequests, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'archived conversations stay hidden behind a toggle and unarchive with DELETE',
    (tester) async {
      final active = await insertConversation(token: 'roomactive');
      final archived = await insertConversation(
        token: 'roomarchived',
        isArchived: true,
      );
      var unarchiveRequests = 0;

      await tester.pumpWidget(
        app(
          conversations: [active, archived],
          client: MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              return http.Response(jsonEncode(capabilitiesJson()), 200);
            }
            if (request.url.path.endsWith('/archive')) {
              expect(request.method, 'DELETE');
              unarchiveRequests++;
              return ocsSuccess();
            }
            return http.Response('', 404);
          }),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('conversation-tile-roomactive')), findsOneWidget);
      expect(find.byKey(const Key('conversation-tile-roomarchived')), findsNothing);
      expect(find.text('Archived (1)'), findsOneWidget);

      await tester.tap(find.byKey(const Key('conversation-archived-toggle')));
      await tester.pump();

      expect(find.byKey(const Key('conversation-tile-roomactive')), findsNothing);
      expect(find.byKey(const Key('conversation-tile-roomarchived')), findsOneWidget);
      expect(find.text('Back to conversations'), findsOneWidget);

      await tester.longPress(
        find.byKey(const Key('conversation-tile-roomarchived')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Unarchive conversation'), findsOneWidget);
      await tester.tap(find.byKey(const Key('conversation-action-archive')));
      await _pumpUntil(tester, () => unarchiveRequests == 1);
      await _settle(tester);

      expect(unarchiveRequests, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed archive action surfaces an error without crashing', (
    tester,
  ) async {
    final conversation = await insertConversation(token: 'rooma');

    await tester.pumpWidget(
      app(
        conversations: [conversation],
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(jsonEncode(capabilitiesJson()), 200);
          }
          if (request.url.path.endsWith('/archive')) {
            return ocsFailure(401);
          }
          return http.Response('', 404);
        }),
      ),
    );
    await tester.pump();

    await tester.longPress(find.byKey(const Key('conversation-tile-rooma')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conversation-action-archive')));
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('conversation-action-error')).evaluate().isNotEmpty,
    );

    expect(
      find.text('Please sign in again to make this change.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

Map<String, Object?> _conversationRoomJson() {
  final root =
      jsonDecode(
            File(
              '../../contracts/conversation-list/fixtures/conversations-full.response.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  return Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
}

/// Drains pending microtasks/timers after a successful action so its
/// fire-and-forget background resync (triggered by [RoomSettingsService]
/// actions) completes before the test's database is torn down.
Future<void> _settle(WidgetTester tester) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxAttempts = 100,
}) async {
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    if (condition()) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  fail('Condition was not reached');
}
