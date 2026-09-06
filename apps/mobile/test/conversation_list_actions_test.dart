import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
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

const _markUnreadTalkFeatures = {'chat-v2', 'chat-read-marker', 'chat-unread'};
const _archiveTalkFeatures = {'archived-conversations-v2'};
const _markUnreadAndArchiveTalkFeatures = {
  ..._markUnreadTalkFeatures,
  ..._archiveTalkFeatures,
};

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
    return (database.select(database.cachedConversations)..where(
          (conversation) =>
              conversation.accountId.equals(account.id) &
              conversation.token.equals(token),
        ))
        .getSingle();
  }

  Future<void> setTalkFeatures(Set<String> features) async {
    await accounts.updateTalkFeatures(account.id, features);
    account = (await accounts.getAccount(account.id))!;
  }

  Widget app({
    required List<CachedConversation> conversations,
    required http.Client client,
    StoredAccount? displayedAccount,
    ValueListenable<StoredAccount>? accountListenable,
    Map<String, List<CachedConversation>> conversationsByAccount = const {},
    HttpNextcloudApi? api,
    double bottomInset = 0,
  }) {
    final resolvedApi = api ?? HttpNextcloudApi(client: client);
    Widget conversationList(
      StoredAccount resolvedAccount,
      List<CachedConversation> resolvedConversations,
    ) {
      return ConversationListView(
        account: resolvedAccount,
        conversations: resolvedConversations,
        loading: false,
        onRefresh: () async {},
        onSelect: (_) {},
        bottomInset: bottomInset,
      );
    }

    final resolvedAccount = displayedAccount ?? account;
    return ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(resolvedApi),
      ],
      child: localizedTestApp(
        home: Scaffold(
          body: accountListenable == null
              ? conversationList(resolvedAccount, conversations)
              : ValueListenableBuilder<StoredAccount>(
                  valueListenable: accountListenable,
                  builder: (context, currentAccount, child) => conversationList(
                    currentAccount,
                    conversationsByAccount[currentAccount.id] ?? const [],
                  ),
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

  testWidgets('the last conversation is not left under the compose button', (
    tester,
  ) async {
    // FOUND AT 200 % TEXT ON A PHONE, 6 September 2026: with six rooms the
    // list does not scroll, and the floating compose button sat over the last
    // room's message with no way to move it out.
    await setTalkFeatures(const {'chat-v2'});
    final conversation = await insertConversation(token: 'roomlast');

    await tester.pumpWidget(
      app(
        conversations: [conversation],
        client: MockClient((request) async => http.Response('', 404)),
        bottomInset: 88,
      ),
    );
    await tester.pump();

    final list = tester.widget<ListView>(find.byType(ListView));
    expect(
      list.padding,
      const EdgeInsets.only(bottom: 88),
      reason: 'the room the button covers has to be scrollable out from under it',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('mark-unread stays hidden without its capability profile', (
    tester,
  ) async {
    await setTalkFeatures(const {
      'chat-v2',
      'chat-read-marker',
      'archived-conversations-v2',
    });
    final conversation = await insertConversation(token: 'roomread');

    await tester.pumpWidget(
      app(
        conversations: [conversation],
        client: MockClient((request) async => http.Response('', 404)),
      ),
    );
    await tester.pump();

    await tester.longPress(find.byKey(const Key('conversation-tile-roomread')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('conversation-action-mark-unread')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('conversation-action-archive')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('mark-unread is offered for a supported read conversation', (
    tester,
  ) async {
    await setTalkFeatures(_markUnreadAndArchiveTalkFeatures);
    final conversation = await insertConversation(token: 'roomread');

    await tester.pumpWidget(
      app(
        conversations: [conversation],
        client: MockClient((request) async => http.Response('', 404)),
      ),
    );
    await tester.pump();

    await tester.longPress(find.byKey(const Key('conversation-tile-roomread')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('conversation-action-mark-unread')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('conversation-action-archive')),
      findsOneWidget,
    );
    expect(find.text('Archive conversation'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a right click opens the same actions as a long press', (
    tester,
  ) async {
    await setTalkFeatures(_markUnreadAndArchiveTalkFeatures);
    final conversation = await insertConversation(token: 'roomread');

    await tester.pumpWidget(
      app(
        conversations: [conversation],
        client: MockClient((request) async => http.Response('', 404)),
      ),
    );
    await tester.pump();

    // Holding a mouse button down is the wrong gesture on a desktop, so the
    // sheet has to be reachable with the secondary button.
    final tile = find.byKey(const Key('conversation-tile-roomread'));
    await tester.tapAt(tester.getCenter(tile), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('conversation-action-mark-unread')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('conversation-action-archive')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('mark-unread stays hidden for a supported unread conversation', (
    tester,
  ) async {
    await setTalkFeatures(_markUnreadAndArchiveTalkFeatures);
    final conversation = await insertConversation(
      token: 'roomunread',
      unreadMessages: 3,
    );

    await tester.pumpWidget(
      app(
        conversations: [conversation],
        client: MockClient((request) async => http.Response('', 404)),
      ),
    );
    await tester.pump();

    await tester.longPress(
      find.byKey(const Key('conversation-tile-roomunread')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('conversation-action-mark-unread')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('conversation-action-archive')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('archive stays hidden without archived-conversations-v2', (
    tester,
  ) async {
    await setTalkFeatures(_markUnreadTalkFeatures);
    final conversation = await insertConversation(token: 'roomactive');

    await tester.pumpWidget(
      app(
        conversations: [conversation],
        client: MockClient((request) async => http.Response('', 404)),
      ),
    );
    await tester.pump();

    await tester.longPress(
      find.byKey(const Key('conversation-tile-roomactive')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('conversation-action-mark-unread')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('conversation-action-archive')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'marking a conversation unread calls the chat read-marker endpoint',
    (tester) async {
      await setTalkFeatures(_markUnreadTalkFeatures);
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
      await tester.tap(
        find.byKey(const Key('conversation-action-mark-unread')),
      );
      await _pumpUntil(tester, () => markUnreadRequests == 1);
      // The action triggers a best-effort background resync; let it settle
      // (it fails against the unmocked conversation-list endpoint and is
      // swallowed) before the database closes in tearDown.
      await _settle(tester);

      expect(markUnreadRequests, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('archive remains available when unread and uses POST', (
    tester,
  ) async {
    await setTalkFeatures(_archiveTalkFeatures);
    final conversation = await insertConversation(
      token: 'rooma',
      unreadMessages: 3,
    );
    var archiveRequests = 0;

    await tester.pumpWidget(
      app(
        conversations: [conversation],
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(capabilitiesJson(talkFeatures: _archiveTalkFeatures)),
              200,
            );
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
    expect(find.text('Archive conversation'), findsOneWidget);
    await tester.tap(find.byKey(const Key('conversation-action-archive')));
    await _pumpUntil(tester, () => archiveRequests == 1);
    await _settle(tester);

    expect(archiveRequests, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an open action sheet keeps the originating account', (
    tester,
  ) async {
    await setTalkFeatures(_archiveTalkFeatures);
    final accountA = account;
    final conversationA = await insertConversation(token: 'sharedroom');
    vault.values['account-b'] = 'password-b';
    account = await accounts.upsertAccount(
      accountId: 'account-b',
      serverUrl: 'https://other.example.invalid',
      loginName: 'other-user',
      serverProductName: 'Nextcloud',
      talkFeatures: _archiveTalkFeatures,
      createdAt: DateTime.utc(2026, 1, 2),
    );
    final accountB = account;
    final conversationB = await insertConversation(token: 'sharedroom');
    final archiveHosts = <String>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/archive')) {
        archiveHosts.add(request.url.host);
        return ocsSuccess();
      }
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return http.Response(
          jsonEncode(capabilitiesJson(talkFeatures: _archiveTalkFeatures)),
          200,
        );
      }
      return http.Response('', 404);
    });
    final api = HttpNextcloudApi(client: client);
    addTearDown(api.close);
    final displayedAccount = ValueNotifier(accountA);
    addTearDown(displayedAccount.dispose);

    await tester.pumpWidget(
      app(
        conversations: [conversationA],
        client: client,
        accountListenable: displayedAccount,
        conversationsByAccount: {
          accountA.id: [conversationA],
          accountB.id: [conversationB],
        },
        api: api,
      ),
    );
    await tester.pump();
    await tester.longPress(
      find.byKey(const Key('conversation-tile-sharedroom')),
    );
    await tester.pumpAndSettle();

    displayedAccount.value = accountB;
    await tester.pump();
    await tester.tap(find.byKey(const Key('conversation-action-archive')));
    await _pumpUntil(tester, () => archiveHosts.isNotEmpty);

    expect(archiveHosts.single, 'cloud.example.invalid');
  });

  testWidgets('action resync keeps its account during a delayed request', (
    tester,
  ) async {
    await setTalkFeatures(_markUnreadTalkFeatures);
    final accountA = account;
    final conversationA = await insertConversation(token: 'sharedroom');
    vault.values['account-b'] = 'password-b';
    account = await accounts.upsertAccount(
      accountId: 'account-b',
      serverUrl: 'https://other.example.invalid',
      loginName: 'other-user',
      serverProductName: 'Nextcloud',
      talkFeatures: _markUnreadTalkFeatures,
      createdAt: DateTime.utc(2026, 1, 2),
    );
    final accountB = account;
    final conversationB = await insertConversation(token: 'sharedroom');
    final markUnreadResponse = Completer<http.Response>();
    final markUnreadStarted = Completer<void>();
    final conversationHosts = <String>[];
    final client = MockClient((request) async {
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
      if (request.method == 'GET' &&
          request.url.path.endsWith('/spreed/api/v4/room')) {
        conversationHosts.add(request.url.host);
        return http.Response('', 503);
      }
      if (request.method == 'DELETE' &&
          request.url.path.endsWith('/chat/sharedroom/read')) {
        if (!markUnreadStarted.isCompleted) {
          markUnreadStarted.complete();
        }
        return markUnreadResponse.future;
      }
      return http.Response('', 404);
    });
    final api = HttpNextcloudApi(client: client);
    addTearDown(api.close);
    final displayedAccount = ValueNotifier(accountA);
    addTearDown(displayedAccount.dispose);

    await tester.pumpWidget(
      app(
        conversations: [conversationA],
        client: client,
        accountListenable: displayedAccount,
        conversationsByAccount: {
          accountA.id: [conversationA],
          accountB.id: [conversationB],
        },
        api: api,
      ),
    );
    await tester.pump();
    await tester.longPress(
      find.byKey(const Key('conversation-tile-sharedroom')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conversation-action-mark-unread')));
    await _pumpUntil(tester, () => markUnreadStarted.isCompleted);

    displayedAccount.value = accountB;
    await tester.pump();
    markUnreadResponse.complete(
      ocsSuccess(const {
        'token': 'sharedroom',
        'lastReadMessage': 5,
        'lastCommonReadMessage': 5,
        'unreadMessages': 1,
      }),
    );
    await _pumpUntil(tester, () => conversationHosts.isNotEmpty);

    expect(conversationHosts.single, 'cloud.example.invalid');
  });

  testWidgets(
    'archived conversations stay behind a filter and unarchive with DELETE',
    (tester) async {
      await setTalkFeatures(_archiveTalkFeatures);
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
              return http.Response(
                jsonEncode(
                  capabilitiesJson(talkFeatures: _archiveTalkFeatures),
                ),
                200,
              );
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

      expect(
        find.byKey(const Key('conversation-tile-roomactive')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('conversation-tile-roomarchived')),
        findsNothing,
      );
      expect(find.text('Archived'), findsOneWidget);

      await tester.tap(find.byKey(const Key('conversation-filter-archived')));
      await tester.pump();

      expect(
        find.byKey(const Key('conversation-tile-roomactive')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('conversation-tile-roomarchived')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilterChip>(
              find.byKey(const Key('conversation-filter-archived')),
            )
            .selected,
        isTrue,
      );

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
    await setTalkFeatures(_archiveTalkFeatures);
    final conversation = await insertConversation(token: 'rooma');

    await tester.pumpWidget(
      app(
        conversations: [conversation],
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(capabilitiesJson(talkFeatures: _archiveTalkFeatures)),
              200,
            );
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
      () => find
          .byKey(const Key('conversation-action-error'))
          .evaluate()
          .isNotEmpty,
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
