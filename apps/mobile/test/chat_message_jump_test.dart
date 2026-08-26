import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

/// Covers the jump-to-message path shared by message search and by tapping a
/// quoted original: reveal a cached message, page back for one that is not
/// cached yet, and fail out loud when it cannot be reached at all.
void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;
  late StoredAccount account;
  late CachedConversation conversation;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault();
    account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    vault.values[account.id] = 'fixture-app-password-never-use';
    // The service parses the stored room wire format before every fetch, so
    // the cached row has to carry a real conversation payload.
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
    conversation = await database
        .select(database.cachedConversations)
        .getSingle();
  });

  tearDown(() => database.close());

  testWidgets('reveals and highlights a cached message far up the timeline', (
    tester,
  ) async {
    for (var id = 101; id <= 130; id++) {
      await _insertMessage(database, account.id, id);
    }
    await _insertScope(
      database,
      account.id,
      historyCursor: '101',
      futureCursor: '130',
      hasHistory: false,
      blocksJson: '[["101","130"]]',
    );
    final api = HttpNextcloudApi(client: MockClient(_convergedServer));
    addTearDown(api.close);

    await tester.pumpWidget(
      _app(
        database: database,
        vault: vault,
        api: api,
        home: PresenceChatRoomScreen(
          account: account,
          conversation: conversation,
          jumpToMessageId: 105,
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('chat-message-target-105'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.pumpAndSettle();

    final target = find.byKey(const Key('chat-message-target-105'));
    expect(target, findsOneWidget);
    final bounds = tester.getRect(target);
    final viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(
      bounds.top,
      greaterThanOrEqualTo(0),
      reason: 'The jump target must be scrolled into view, not above it',
    );
    expect(bounds.bottom, lessThanOrEqualTo(viewport.height));
    expect(
      find.byKey(const Key('chat-message-target-130')),
      findsNothing,
      reason: 'The timeline must have left the newest message behind',
    );
    expect(_highlightBorder(tester, 105), isNotNull);
    expect(find.byKey(const Key('chat-jump-not-found')), findsNothing);
    expect(tester.takeException(), isNull);

    // The highlight fades on its own; letting it expire keeps the timer out
    // of the teardown and proves it is not permanent.
    await tester.pump(const Duration(seconds: 3));
    expect(_highlightBorder(tester, 105), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('fetches an older page to reach a message outside the cache', (
    tester,
  ) async {
    for (var id = 110; id <= 118; id++) {
      await _insertMessage(database, account.id, id);
    }
    await _insertScope(
      database,
      account.id,
      historyCursor: '110',
      futureCursor: '118',
      hasHistory: true,
      blocksJson: '[["110","118"]]',
    );
    final historyRequests = <Uri>[];
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        final capabilities = _capabilitiesResponse(request);
        if (capabilities != null) {
          return capabilities;
        }
        if (request.url.queryParameters['lookIntoFuture'] == '0') {
          historyRequests.add(request.url);
          return http.Response(
            jsonEncode(_historyPage(newest: 109, oldest: 100)),
            200,
            headers: const <String, String>{
              'X-Chat-Last-Given': '100',
              'X-Chat-Last-Common-Read': '110',
            },
          );
        }
        return http.Response('', 304);
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      _app(
        database: database,
        vault: vault,
        api: api,
        home: PresenceChatRoomScreen(
          account: account,
          conversation: conversation,
          jumpToMessageId: 105,
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () =>
          find
              .byKey(const Key('chat-message-target-105'))
              .evaluate()
              .isNotEmpty ||
          find.byKey(const Key('chat-jump-not-found')).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    final rootView = await (database.select(
      database.chatScopes,
    )..where((scope) => scope.scopeKey.equals('root'))).getSingle();
    final networkRoot = await (database.select(
      database.chatScopes,
    )..where((scope) => scope.scopeKey.equals('network-root'))).getSingle();
    for (final scope in [rootView, networkRoot]) {
      expect(
        scope.lastSyncError,
        isNull,
        reason: 'the history page must merge cleanly',
      );
      expect(scope.blocksJson, '[["100","118"]]');
    }
    expect(historyRequests, hasLength(1));
    expect(historyRequests.single.queryParameters['lastKnownMessageId'], '110');
    expect(historyRequests.single.queryParameters['lookIntoFuture'], '0');
    expect(find.byKey(const Key('chat-message-target-105')), findsOneWidget);
    expect(_highlightBorder(tester, 105), isNotNull);
    expect(find.byKey(const Key('chat-jump-not-found')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('rechecks a target fetched on the final allowed history page', (
    tester,
  ) async {
    for (var id = 1101; id <= 1108; id++) {
      await _insertMessage(database, account.id, id);
    }
    await _insertScope(
      database,
      account.id,
      historyCursor: '1101',
      futureCursor: '1108',
      hasHistory: true,
      blocksJson: '[["1101","1108"]]',
    );
    var historyRequests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        final capabilities = _capabilitiesResponse(request);
        if (capabilities != null) {
          return capabilities;
        }
        if (request.url.queryParameters['lookIntoFuture'] == '0') {
          historyRequests++;
          final anchor = int.parse(
            request.url.queryParameters['lastKnownMessageId']!,
          );
          final newest = anchor - 1;
          final oldest = (anchor - 100).clamp(1, newest);
          return http.Response(
            jsonEncode(_historyPage(newest: newest, oldest: oldest)),
            200,
            headers: <String, String>{
              'X-Chat-Last-Given': '$oldest',
              'X-Chat-Last-Common-Read': '1101',
            },
          );
        }
        return http.Response('', 304);
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      _app(
        database: database,
        vault: vault,
        api: api,
        home: PresenceChatRoomScreen(
          account: account,
          conversation: conversation,
          jumpToMessageId: 42,
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () =>
          find
              .byKey(const Key('chat-message-target-42'))
              .evaluate()
              .isNotEmpty ||
          find.byKey(const Key('chat-jump-not-found')).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    expect(historyRequests, 11);
    expect(find.byKey(const Key('chat-message-target-42')), findsOneWidget);
    expect(find.byKey(const Key('chat-jump-not-found')), findsNothing);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('says so instead of failing silently when nothing can be found', (
    tester,
  ) async {
    for (var id = 110; id <= 118; id++) {
      await _insertMessage(database, account.id, id);
    }
    await _insertScope(
      database,
      account.id,
      historyCursor: '110',
      futureCursor: '118',
      hasHistory: false,
      blocksJson: '[["110","118"]]',
    );
    final api = HttpNextcloudApi(client: MockClient(_convergedServer));
    addTearDown(api.close);

    await tester.pumpWidget(
      _app(
        database: database,
        vault: vault,
        api: api,
        home: PresenceChatRoomScreen(
          account: account,
          conversation: conversation,
          jumpToMessageId: 42,
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('chat-jump-not-found')).evaluate().isNotEmpty,
    );

    expect(
      find.text('That message is no longer available in this conversation.'),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('tapping a quoted original jumps to it', (tester) async {
    for (var id = 101; id <= 129; id++) {
      await _insertMessage(database, account.id, id);
    }
    await _insertMessage(
      database,
      account.id,
      130,
      parent: _messageJson(id: 104, message: 'Message 104'),
    );
    await _insertScope(
      database,
      account.id,
      historyCursor: '101',
      futureCursor: '130',
      hasHistory: false,
      blocksJson: '[["101","130"]]',
    );
    final api = HttpNextcloudApi(client: MockClient(_convergedServer));
    addTearDown(api.close);

    await tester.pumpWidget(
      _app(
        database: database,
        vault: vault,
        api: api,
        home: PresenceChatRoomScreen(
          account: account,
          conversation: conversation,
        ),
      ),
    );
    // The sync progress bar is an indeterminate animation, so waiting for the
    // quote itself is the only way to reach a settled tree.
    await _pumpUntil(
      tester,
      () =>
          find.byKey(const Key('chat-reply-jump-130')).evaluate().isNotEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty,
    );

    final quote = find.byKey(const Key('chat-reply-jump-130'));
    expect(quote, findsOneWidget);
    await tester.tap(quote);
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('chat-message-target-104'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.pumpAndSettle();

    expect(_highlightBorder(tester, 104), isNotNull);
    expect(find.byKey(const Key('chat-jump-not-found')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

Widget _app({
  required AppDatabase database,
  required MemoryCredentialVault vault,
  required HttpNextcloudApi api,
  required Widget home,
}) {
  return ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      credentialVaultProvider.overrideWithValue(vault),
      nextcloudApiProvider.overrideWithValue(api),
      // This suite covers jumping, not attachment transport. Resolving the
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

/// A server that only ever reports "nothing new", so a test can exercise the
/// jump without the timeline moving underneath it.
Future<http.Response> _convergedServer(http.Request request) async {
  return _capabilitiesResponse(request) ?? http.Response('', 304);
}

http.Response? _capabilitiesResponse(http.Request request) {
  if (request.url.path.endsWith('/cloud/capabilities')) {
    return http.Response(
      jsonEncode(
        capabilitiesJson(
          talkFeatures: const <String>[
            'conversation-v4',
            'chat-v2',
            'chat-reference-id',
          ],
        ),
      ),
      200,
    );
  }
  if (request.url.path.contains('/avatar/')) {
    return http.Response('', 404);
  }
  return null;
}

Border? _highlightBorder(WidgetTester tester, int messageId) {
  final container = tester.widget<AnimatedContainer>(
    find.descendant(
      of: find.byKey(Key('chat-message-target-$messageId')),
      matching: find.byType(AnimatedContainer),
    ),
  );
  return (container.decoration! as BoxDecoration).border as Border?;
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
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

Map<String, Object?> _conversationRoomJson() {
  final root =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  return Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
}

Map<String, Object?> _messageJson({
  required int id,
  required String message,
  Map<String, Object?>? parent,
}) {
  return <String, Object?>{
    'id': id,
    'token': 'rooma123',
    'actorType': 'users',
    'actorId': 'someone-else',
    'actorDisplayName': 'Other person',
    'timestamp': 1724300000 + id,
    'systemMessage': '',
    'messageType': 'comment',
    'isReplyable': true,
    'referenceId': 'reference-$id',
    'message': message,
    'messageParameters': <String, Object?>{},
    'markdown': false,
    'reactions': <String, Object?>{},
    'parent': ?parent,
  };
}

Map<String, Object?> _historyPage({required int newest, required int oldest}) {
  return <String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <Object?>[
        for (var id = newest; id >= oldest; id--)
          _messageJson(id: id, message: 'Message $id'),
      ],
    },
  };
}

Future<void> _insertMessage(
  AppDatabase database,
  String accountId,
  int messageId, {
  Map<String, Object?>? parent,
}) {
  final wire = _messageJson(
    id: messageId,
    message: 'Message $messageId',
    parent: parent,
  );
  return database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: accountId,
          roomToken: wire['token']! as String,
          messageId: messageId,
          actorType: wire['actorType']! as String,
          actorId: wire['actorId']! as String,
          actorDisplayName: wire['actorDisplayName']! as String,
          timestamp: wire['timestamp']! as int,
          systemMessage: '',
          messageType: 'comment',
          referenceId: wire['referenceId']! as String,
          displayText: 'Message $messageId',
          deleted: false,
          rawJson: jsonEncode(wire),
        ),
      );
}

Future<void> _insertScope(
  AppDatabase database,
  String accountId, {
  required String historyCursor,
  required String futureCursor,
  required bool hasHistory,
  required String blocksJson,
}) {
  return database
      .into(database.chatScopes)
      .insert(
        ChatScopesCompanion.insert(
          accountId: accountId,
          roomToken: 'rooma123',
          scopeKey: 'root',
          historyCursor: historyCursor,
          futureCursor: futureCursor,
          lastCommonRead: futureCursor,
          lastReadMessage: 0,
          unreadMessages: 0,
          hasHistory: hasHistory,
          futureConverged: false,
          blocksJson: blocksJson,
          // A scope that has already synchronized once skips the initial
          // history page, so each test drives exactly the fetches it asserts.
          lastSyncedAtMillis: const Value(1724300000000),
        ),
      );
}
