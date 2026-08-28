import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/outgoing_message_status.dart';
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';
import 'package:nextcloudtalk/features/conversations/conversation_shell.dart';
import 'package:nextcloudtalk/features/search/message_search_service.dart';
import 'package:nextcloudtalk/features/search/message_search_screen.dart';
import 'package:nextcloudtalk/features/search/message_search_thread_screen.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  testWidgets(
    'a stale thread sync cannot replace the route opened after search closes',
    (tester) async {
      final fixture = await _LifecycleFixture.create();
      addTearDown(fixture.dispose);
      final selectedAccounts = StreamController<StoredAccount?>();
      addTearDown(selectedAccounts.close);
      final heldThreadSync = Completer<http.Response>();
      final threadSyncStarted = Completer<void>();
      var threadSyncRequests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(
                capabilitiesJson(
                  talkFeatures: const <String>[
                    'conversation-v4',
                    'chat-v2',
                    'chat-reference-id',
                    'chat-replies',
                    'threads',
                  ],
                ),
              ),
              200,
              headers: const <String, String>{
                'content-type': 'application/json; charset=utf-8',
              },
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/apps/spreed/api/v1/chat/rooma123') &&
              request.url.queryParameters['threadId'] == '80') {
            threadSyncRequests++;
            if (!threadSyncStarted.isCompleted) {
              threadSyncStarted.complete();
            }
            return heldThreadSync.future;
          }
          return http.Response('', 404);
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        _wrapShell(
          fixture,
          selectedAccounts.stream,
          overrides: <Override>[
            nextcloudApiProvider.overrideWithValue(api),
            messageSearchServiceProvider.overrideWithValue(
              _FixedSearchService(_threadResult()),
            ),
          ],
        ),
      );
      addTearDown(() async {
        if (!heldThreadSync.isCompleted) {
          heldThreadSync.complete(http.Response('', 503));
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
      selectedAccounts.add(fixture.account);
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const Key('open-message-search')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(
        find.byKey(const Key('message-search-field')),
        'fixture',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      await tester.tap(find.text('Fixture author'));
      await tester.tap(find.text('Fixture author'));
      await _pumpUntil(tester, () => threadSyncStarted.isCompleted);
      expect(threadSyncRequests, 1);

      final navigator = Navigator.of(
        tester.element(find.byType(MessageSearchScreen)),
      );
      unawaited(
        navigator.pushReplacement<void, void>(
          MaterialPageRoute<void>(builder: (_) => const _SentinelScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('sentinel-screen')), findsOneWidget);

      await tester.runAsync(() => fixture.insertNamedThreadRoot(80));
      heldThreadSync.complete(http.Response('', 304));
      await _waitForResultGuard(tester);

      expect(find.byKey(const Key('sentinel-screen')), findsOneWidget);
      expect(find.byType(MessageSearchThreadScreen), findsNothing);
      expect(find.byKey(const Key('search-thread-unavailable')), findsNothing);
      expect(tester.takeException(), null);
    },
  );

  testWidgets('the current result replaces search with its destination', (
    tester,
  ) async {
    final fixture = await _LifecycleFixture.create();
    addTearDown(fixture.dispose);
    final selectedAccounts = StreamController<StoredAccount?>();
    addTearDown(selectedAccounts.close);
    final api = _notFoundApi();
    addTearDown(api.close);

    await tester.pumpWidget(
      _wrapShell(
        fixture,
        selectedAccounts.stream,
        overrides: <Override>[
          nextcloudApiProvider.overrideWithValue(api),
          messageSearchServiceProvider.overrideWithValue(
            _FixedSearchService(_rootResult()),
          ),
        ],
      ),
    );
    addTearDown(() => _disposeShell(tester));
    selectedAccounts.add(fixture.account);
    await _openFirstSearchResult(tester);

    await _pumpUntil(
      tester,
      () => find.byType(PresenceChatRoomScreen).evaluate().isNotEmpty,
    );
    expect(find.byType(PresenceChatRoomScreen), findsOneWidget);
    expect(tester.takeException(), null);
  });

  testWidgets('a missing conversation reports the failure without a guess', (
    tester,
  ) async {
    final fixture = await _LifecycleFixture.create();
    addTearDown(fixture.dispose);
    final selectedAccounts = StreamController<StoredAccount?>();
    addTearDown(selectedAccounts.close);
    final api = _notFoundApi();
    addTearDown(api.close);

    await tester.pumpWidget(
      _wrapShell(
        fixture,
        selectedAccounts.stream,
        overrides: <Override>[
          nextcloudApiProvider.overrideWithValue(api),
          messageSearchServiceProvider.overrideWithValue(
            _FixedSearchService(_missingRoomResult()),
          ),
        ],
      ),
    );
    addTearDown(() => _disposeShell(tester));
    selectedAccounts.add(fixture.account);
    await _openFirstSearchResult(tester);

    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('search-conversation-missing'), skipOffstage: false)
          .evaluate()
          .isNotEmpty,
    );
    expect(find.byType(PresenceChatRoomScreen), findsNothing);
    expect(tester.takeException(), null);
  });

  testWidgets(
    'a current thread failure stays on search and reports its cause',
    (tester) async {
      final fixture = await _LifecycleFixture.create();
      addTearDown(fixture.dispose);
      final selectedAccounts = StreamController<StoredAccount?>();
      addTearDown(selectedAccounts.close);
      final api = _threadFailureApi();
      addTearDown(api.close);

      await tester.pumpWidget(
        _wrapShell(
          fixture,
          selectedAccounts.stream,
          overrides: <Override>[
            nextcloudApiProvider.overrideWithValue(api),
            messageSearchServiceProvider.overrideWithValue(
              _FixedSearchService(_threadResult()),
            ),
          ],
        ),
      );
      addTearDown(() => _disposeShell(tester));
      selectedAccounts.add(fixture.account);
      await _openFirstSearchResult(tester);

      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('search-thread-unavailable'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.byType(MessageSearchScreen), findsOneWidget);
      expect(find.byType(MessageSearchThreadScreen), findsNothing);
      expect(tester.takeException(), null);
    },
  );

  testWidgets('an account switch invalidates a pending thread completion', (
    tester,
  ) async {
    final fixture = await _LifecycleFixture.create();
    addTearDown(fixture.dispose);
    final accountB = await fixture.createSecondaryAccount();
    final selectedAccounts = StreamController<StoredAccount?>();
    addTearDown(selectedAccounts.close);
    final heldThreadSync = Completer<http.Response>();
    final threadSyncStarted = Completer<void>();
    final api = _heldThreadApi(heldThreadSync, threadSyncStarted);
    addTearDown(api.close);

    await tester.pumpWidget(
      _wrapShell(
        fixture,
        selectedAccounts.stream,
        availableAccounts: <StoredAccount>[fixture.account, accountB],
        overrides: <Override>[
          nextcloudApiProvider.overrideWithValue(api),
          messageSearchServiceProvider.overrideWithValue(
            _FixedSearchService(_threadResult()),
          ),
        ],
      ),
    );
    addTearDown(() async {
      if (!heldThreadSync.isCompleted) {
        heldThreadSync.complete(http.Response('', 503));
      }
      await _disposeShell(tester);
    });
    selectedAccounts.add(fixture.account);
    await _openFirstSearchResult(tester);
    await _pumpUntil(tester, () => threadSyncStarted.isCompleted);

    selectedAccounts.add(accountB);
    await tester.pump();
    await tester.runAsync(() => fixture.insertNamedThreadRoot(80));
    heldThreadSync.complete(http.Response('', 304));
    await _waitForResultGuard(tester);

    expect(find.byType(MessageSearchThreadScreen), findsNothing);
    expect(
      find.byKey(const Key('search-thread-unavailable'), skipOffstage: false),
      findsNothing,
    );
    expect(tester.takeException(), null);
  });
}

Widget _wrapShell(
  _LifecycleFixture fixture,
  Stream<StoredAccount?> selectedAccounts, {
  List<Override> overrides = const <Override>[],
  List<StoredAccount>? availableAccounts,
}) {
  return ProviderScope(
    overrides: <Override>[
      appDatabaseProvider.overrideWithValue(fixture.database),
      // Push owns separate call-chain coverage; lifecycle search tests must
      // not open its unrelated Drift watcher.
      clientPushEnabledProvider.overrideWithValue(false),
      credentialVaultProvider.overrideWithValue(fixture.credentials),
      accountsProvider.overrideWith(
        (ref) =>
            Stream.value(availableAccounts ?? <StoredAccount>[fixture.account]),
      ),
      selectedAccountProvider.overrideWith((ref) => selectedAccounts),
      conversationsProvider.overrideWith(
        (ref, accountId) =>
            Stream.value(<CachedConversation>[fixture.conversation]),
      ),
      chatMessagesProvider.overrideWith(
        (ref, key) => Stream.value(const <CachedChatMessage>[]),
      ),
      outgoingMessageStatusesProvider.overrideWith(
        (ref, key) => Stream.value(const <OutgoingMessageStatus>[]),
      ),
      textSendOperationsProvider.overrideWith(
        (ref, key) => Stream.value(const <StoredTextSendOperation>[]),
      ),
      chatScopeProvider.overrideWith((ref, key) => Stream.value(null)),
      connectivityWakeEventsProvider.overrideWithValue(
        const Stream<void>.empty(),
      ),
      chatAttachmentDependenciesProvider.overrideWith(
        (ref, key) => Future<ChatAttachmentDependencies>.error(
          StateError('attachment transport is outside this lifecycle test'),
          StackTrace.empty,
        ),
      ),
      ...overrides,
    ],
    child: localizedTestApp(home: const ConversationShell()),
  );
}

final class _LifecycleFixture {
  _LifecycleFixture({
    required this.database,
    required this.credentials,
    required this.account,
    required this.conversation,
  });

  final AppDatabase database;
  final MemoryCredentialVault credentials;
  final StoredAccount account;
  final CachedConversation conversation;

  static Future<_LifecycleFixture> create() async {
    final database = openTestDatabase();
    final accounts = AccountRepository(database);
    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
      talkFeatures: const <String>{
        'conversation-v4',
        'chat-v2',
        'chat-reference-id',
        'chat-replies',
        'threads',
        // The search entry point is gated on this; without it the shell has
        // no button for these tests to reach.
        'unified-search',
      },
    );
    final credentials = MemoryCredentialVault()
      ..values[account.id] = 'fixture-app-password';
    final conversation = await _insertConversation(database, account.id);
    return _LifecycleFixture(
      database: database,
      credentials: credentials,
      account: account,
      conversation: conversation,
    );
  }

  Future<void> insertNamedThreadRoot(int messageId) {
    final wire = <String, Object?>{
      'id': messageId,
      'token': conversation.token,
      'actorType': 'users',
      'actorId': 'fixture-author',
      'actorDisplayName': 'Fixture author',
      'timestamp': 1724300000 + messageId,
      'systemMessage': '',
      'messageType': 'comment',
      'isReplyable': true,
      'referenceId': 'reference-$messageId',
      'message': 'Named fixture thread',
      'messageParameters': <String, Object?>{},
      'markdown': false,
      'reactions': <String, Object?>{},
      'threadId': messageId,
      'isThread': true,
      'threadTitle': 'Named fixture thread',
    };
    return database
        .into(database.cachedChatMessages)
        .insert(
          CachedChatMessagesCompanion.insert(
            accountId: account.id,
            roomToken: conversation.token,
            messageId: messageId,
            actorType: 'users',
            actorId: 'fixture-author',
            actorDisplayName: 'Fixture author',
            timestamp: 1724300000 + messageId,
            systemMessage: '',
            messageType: 'comment',
            referenceId: 'reference-$messageId',
            displayText: 'Named fixture thread',
            deleted: false,
            threadId: Value(messageId),
            rawJson: jsonEncode(wire),
          ),
        );
  }

  Future<StoredAccount> createSecondaryAccount() {
    return AccountRepository(database).upsertAccount(
      accountId: 'account-b',
      serverUrl: 'https://account-b.example.invalid',
      loginName: 'fixture-user-b',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 2),
      talkFeatures: const <String>{
        'conversation-v4',
        'chat-v2',
        'chat-reference-id',
        'chat-replies',
        'threads',
        // The search entry point is gated on this; without it the shell has
        // no button for these tests to reach.
        'unified-search',
      },
    );
  }

  Future<void> dispose() => database.close();
}

final class _FixedSearchService implements MessageSearchService {
  const _FixedSearchService(this.result);

  final MessageSearchResult result;

  @override
  Future<List<MessageSearchResult>> search({
    required String accountId,
    required String term,
    String? roomToken,
    int limit = messageSearchDefaultLimit,
  }) async => <MessageSearchResult>[result];
}

final class _SentinelScreen extends StatelessWidget {
  const _SentinelScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      key: Key('sentinel-screen'),
      body: Center(child: Text('Sentinel')),
    );
  }
}

Future<CachedConversation> _insertConversation(
  AppDatabase database,
  String accountId,
) async {
  final fixture =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = fixture['ocs']! as Map<String, Object?>;
  final roomJson = Map<String, Object?>.from(
    (ocs['data']! as List<Object?>).first! as Map<String, Object?>,
  );
  final room = ConversationRoom.fromJson(roomJson);
  await database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: accountId,
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
  return database.select(database.cachedConversations).getSingle();
}

MessageSearchResult _threadResult() {
  return parseMessageSearchResult(<String, Object?>{
    'title': 'Fixture author',
    'subline': 'Fixture matching message',
    'resourceUrl':
        'https://cloud.example.invalid/call/rooma123?threadId=80#message_83',
    'attributes': <String, Object?>{
      'conversation': 'rooma123',
      'messageId': '83',
      'threadId': '80',
    },
  }, path: r'$');
}

MessageSearchResult _rootResult() {
  return parseMessageSearchResult(<String, Object?>{
    'title': 'Fixture author',
    'subline': 'Fixture matching message',
    'resourceUrl': 'https://cloud.example.invalid/call/rooma123#message_42',
    'attributes': <String, Object?>{
      'conversation': 'rooma123',
      'messageId': '42',
    },
  }, path: r'$');
}

MessageSearchResult _missingRoomResult() {
  return parseMessageSearchResult(<String, Object?>{
    'title': 'Fixture author',
    'subline': 'Fixture matching message',
    'resourceUrl': 'https://cloud.example.invalid/call/missing123#message_42',
    'attributes': <String, Object?>{
      'conversation': 'missing123',
      'messageId': '42',
    },
  }, path: r'$');
}

HttpNextcloudApi _notFoundApi() {
  return HttpNextcloudApi(
    client: MockClient((_) async => http.Response('', 404)),
  );
}

HttpNextcloudApi _threadFailureApi() {
  return HttpNextcloudApi(
    client: MockClient((request) async {
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return _capabilitiesResponse();
      }
      if (request.method == 'GET' &&
          request.url.path.endsWith('/apps/spreed/api/v1/chat/rooma123')) {
        return http.Response('', 503);
      }
      return http.Response('', 404);
    }),
  );
}

HttpNextcloudApi _heldThreadApi(
  Completer<http.Response> heldThreadSync,
  Completer<void> threadSyncStarted,
) {
  return HttpNextcloudApi(
    client: MockClient((request) async {
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return _capabilitiesResponse();
      }
      if (request.method == 'GET' &&
          request.url.path.endsWith('/apps/spreed/api/v1/chat/rooma123') &&
          request.url.queryParameters['threadId'] == '80') {
        if (!threadSyncStarted.isCompleted) {
          threadSyncStarted.complete();
        }
        return heldThreadSync.future;
      }
      return http.Response('', 404);
    }),
  );
}

http.Response _capabilitiesResponse() {
  return http.Response(
    jsonEncode(
      capabilitiesJson(
        talkFeatures: const <String>[
          'conversation-v4',
          'chat-v2',
          'chat-reference-id',
          'chat-replies',
          'threads',
        ],
      ),
    ),
    200,
    headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );
}

Future<void> _openFirstSearchResult(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.tap(find.byKey(const Key('open-message-search')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.enterText(
    find.byKey(const Key('message-search-field')),
    'fixture',
  );
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
  await tester.tap(find.text('Fixture author'));
  await tester.pump();
}

Future<void> _waitForResultGuard(WidgetTester tester) {
  return _pumpUntil(tester, () {
    final guard = find.byKey(
      const Key('message-search-result-guard'),
      skipOffstage: false,
    );
    return guard.evaluate().isEmpty ||
        !tester.widget<IgnorePointer>(guard).ignoring;
  });
}

Future<void> _disposeShell(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maximumPumps = 100,
}) async {
  for (var attempt = 0; attempt < maximumPumps; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (condition()) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  fail('Condition was not reached');
}
