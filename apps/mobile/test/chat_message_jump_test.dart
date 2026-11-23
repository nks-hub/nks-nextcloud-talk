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
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_service.dart';
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

  testWidgets('reveals a message among rows with very different heights', (
    tester,
  ) async {
    for (var id = 1; id <= 100; id++) {
      await _insertMessage(
        database,
        account.id,
        id,
        text: id > 50 ? 'Long message\n' * 45 : 'Message $id',
      );
    }
    await _insertScope(
      database,
      account.id,
      historyCursor: '1',
      futureCursor: '100',
      hasHistory: false,
      blocksJson: '[["1","100"]]',
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
          jumpToMessageId: 25,
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () =>
          find
              .byKey(const Key('chat-message-target-25'))
              .evaluate()
              .isNotEmpty ||
          find.byKey(const Key('chat-jump-not-found')).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-jump-not-found')), findsNothing);
    final target = find.byKey(const Key('chat-message-target-25'));
    expect(target, findsOneWidget);
    final viewport = tester.getRect(find.byKey(const Key('chat-message-list')));
    expect(viewport.contains(tester.getCenter(target)), isTrue);
    expect(_highlightBorder(tester, 25), isNotNull);
    await tester.pump(const Duration(seconds: 3));
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

  testWidgets('reaches a message far past ten pages through its context', (
    tester,
  ) async {
    for (var id = 20001; id <= 20008; id++) {
      await _insertMessage(database, account.id, id);
    }
    await _insertScope(
      database,
      account.id,
      historyCursor: '20001',
      futureCursor: '20008',
      hasHistory: true,
      blocksJson: '[["20001","20008"]]',
    );
    final contextRequests = <Uri>[];
    var historyRequests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        final capabilities = _capabilitiesResponse(
          request,
          messageContext: true,
        );
        if (capabilities != null) {
          return capabilities;
        }
        if (request.url.path.endsWith('/context')) {
          contextRequests.add(request.url);
          final segments = request.url.pathSegments;
          final around = int.parse(segments[segments.length - 2]);
          return http.Response(
            jsonEncode(
              _contextPage(
                oldest: (around - 12).clamp(1, around),
                newest: around + 12,
              ),
            ),
            200,
            headers: <String, String>{'X-Chat-Last-Given': '${around + 13}'},
          );
        }
        if (request.url.queryParameters['lookIntoFuture'] == '0') {
          historyRequests++;
          final anchor = int.parse(
            request.url.queryParameters['lastKnownMessageId']!,
          );
          return http.Response(
            jsonEncode(_historyPage(newest: anchor - 1, oldest: anchor - 100)),
            200,
            headers: <String, String>{'X-Chat-Last-Given': '${anchor - 100}'},
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

    expect(find.byKey(const Key('chat-message-target-42')), findsOneWidget);
    expect(_highlightBorder(tester, 42), isNotNull);
    expect(find.byKey(const Key('chat-jump-not-found')), findsNothing);
    expect(historyRequests, 0);
    expect(contextRequests.single.path, endsWith('/chat/rooma123/42/context'));
    final rootView = await (database.select(
      database.chatScopes,
    )..where((scope) => scope.scopeKey.equals('root'))).getSingle();
    final networkRoot = await (database.select(
      database.chatScopes,
    )..where((scope) => scope.scopeKey.equals('network-root'))).getSingle();
    // The view shows the fetched range beside the newest one; paging still
    // continues from where the network cursor left off.
    expect(rootView.blocksJson, '[["30","55"],["20001","20008"]]');
    expect(rootView.hasHistory, isTrue);
    expect(networkRoot.blocksJson, '[["20001","20008"]]');
    expect(networkRoot.historyCursor, '20001');
    expect(networkRoot.futureCursor, '20008');
    expect(networkRoot.hasHistory, isTrue);
    expect(tester.takeException(), isNull);

    // Scrolling to the oldest edge of the island loads older messages right
    // there, and the network cursor is still paged, so the gap between the
    // two keeps closing.
    await tester.drag(
      find.byKey(const Key('chat-message-list')),
      const Offset(0, 4000),
    );
    await _pumpUntil(
      tester,
      () => contextRequests.length >= 2 && historyRequests >= 1,
    );
    await tester.pumpAndSettle();
    expect(contextRequests[1].path, endsWith('/chat/rooma123/30/context'));
    final grownView = await (database.select(
      database.chatScopes,
    )..where((scope) => scope.scopeKey.equals('root'))).getSingle();
    final grownBlocks = decodeChatScopeBlocks(grownView.blocksJson);
    expect(int.parse(grownBlocks.first.start.value), lessThanOrEqualTo(18));
    Future<StoredChatScope> networkRow() => (database.select(
      database.chatScopes,
    )..where((scope) => scope.scopeKey.equals('network-root'))).getSingle();
    var networkAfter = await networkRow();
    // The page is counted when it is asked for; its merge lands a moment later.
    for (
      var turn = 0;
      turn < 200 && networkAfter.historyCursor == '20001';
      turn++
    ) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      networkAfter = await networkRow();
    }
    expect(int.parse(networkAfter.historyCursor), lessThan(20001));

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('pages past ten pages when the server has no context endpoint', (
    tester,
  ) async {
    for (var id = 2001; id <= 2008; id++) {
      await _insertMessage(database, account.id, id);
    }
    await _insertScope(
      database,
      account.id,
      historyCursor: '2001',
      futureCursor: '2008',
      hasHistory: true,
      blocksJson: '[["2001","2008"]]',
    );
    var historyRequests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        final capabilities = _capabilitiesResponse(request);
        if (capabilities != null) {
          return capabilities;
        }
        if (request.url.path.endsWith('/context')) {
          return http.Response('', 404);
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
              'X-Chat-Last-Common-Read': '2001',
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
      () => find.byKey(const Key('chat-jump-progress')).evaluate().isNotEmpty,
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

    expect(historyRequests, 20);
    expect(find.byKey(const Key('chat-message-target-42')), findsOneWidget);
    expect(_highlightBorder(tester, 42), isNotNull);
    expect(find.byKey(const Key('chat-jump-not-found')), findsNothing);
    expect(find.byKey(const Key('chat-jump-progress')), findsNothing);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  group('a context answer the jump cannot use', () {
    Future<int> jumpWith(
      WidgetTester tester,
      http.Response Function() contextAnswer,
    ) async {
      for (var id = 201; id <= 208; id++) {
        await _insertMessage(database, account.id, id);
      }
      await _insertScope(
        database,
        account.id,
        historyCursor: '201',
        futureCursor: '208',
        hasHistory: true,
        blocksJson: '[["201","208"]]',
      );
      var historyRequests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          final capabilities = _capabilitiesResponse(
            request,
            messageContext: true,
          );
          if (capabilities != null) {
            return capabilities;
          }
          if (request.url.path.endsWith('/context')) {
            return contextAnswer();
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
              headers: <String, String>{'X-Chat-Last-Given': '$oldest'},
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
      expect(
        find.text(
          'Saved messages are kept, but the latest chat response was '
          'rejected.',
        ),
        findsNothing,
      );
      return historyRequests;
    }

    Future<void> closePane(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    }

    testWidgets('an answer outside the documented shape falls back to paging', (
      tester,
    ) async {
      // No X-Chat-Last-Given: the range the answer covers cannot be told.
      final historyRequests = await jumpWith(
        tester,
        () => http.Response(
          jsonEncode(_contextPage(oldest: 30, newest: 54)),
          200,
        ),
      );

      expect(historyRequests, 2);
      expect(find.byKey(const Key('chat-message-target-42')), findsOneWidget);
      expect(find.byKey(const Key('chat-jump-not-found')), findsNothing);
      await closePane(tester);
    });

    testWidgets('a 404 only says the message is not available', (tester) async {
      final historyRequests = await jumpWith(
        tester,
        () => http.Response(
          jsonEncode(<String, Object?>{
            'ocs': <String, Object?>{
              'meta': <String, Object?>{
                'status': 'failure',
                'statuscode': 404,
                'message': '',
              },
              'data': <String, Object?>{'error': 'thread'},
            },
          }),
          404,
        ),
      );

      expect(historyRequests, 0);
      expect(find.byKey(const Key('chat-jump-not-found')), findsOneWidget);
      await closePane(tester);
    });
  });

  for (final messageContext in [true, false]) {
    testWidgets('a jump the reader leaves mid-fetch resumes when they are back '
        '(${messageContext ? 'context' : 'paging'})', (tester) async {
      for (var id = 2001; id <= 2008; id++) {
        await _insertMessage(database, account.id, id);
      }
      await _insertScope(
        database,
        account.id,
        historyCursor: '2001',
        futureCursor: '2008',
        hasHistory: true,
        blocksJson: '[["2001","2008"]]',
      );
      final readerActive = StateProvider<bool>((ref) => true);
      ProviderContainer? container;
      var fetches = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          final capabilities = _capabilitiesResponse(
            request,
            messageContext: messageContext,
          );
          if (capabilities != null) {
            return capabilities;
          }
          final contextFetch = request.url.path.endsWith('/context');
          final historyFetch =
              request.url.queryParameters['lookIntoFuture'] == '0';
          if (!contextFetch && !historyFetch) {
            return http.Response('', 304);
          }
          // The window loses focus while the first fetch is in flight.
          if (++fetches == 1) {
            container!.read(readerActive.notifier).state = false;
          }
          if (contextFetch) {
            return http.Response(
              jsonEncode(_contextPage(oldest: 30, newest: 54)),
              200,
              headers: const <String, String>{'X-Chat-Last-Given': '55'},
            );
          }
          final anchor = int.parse(
            request.url.queryParameters['lastKnownMessageId']!,
          );
          final newest = anchor - 1;
          final oldest = (anchor - 100).clamp(1, newest);
          return http.Response(
            jsonEncode(_historyPage(newest: newest, oldest: oldest)),
            200,
            headers: <String, String>{'X-Chat-Last-Given': '$oldest'},
          );
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        _app(
          database: database,
          vault: vault,
          api: api,
          overrides: [
            windowActiveProvider.overrideWith((ref) => ref.watch(readerActive)),
          ],
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
            jumpToMessageId: 42,
          ),
        ),
      );
      container = ProviderScope.containerOf(
        tester.element(find.byType(PresenceChatRoomScreen)),
      );
      await _pumpUntil(tester, () => fetches >= 1);
      for (var turn = 0; turn < 30; turn++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(
        find.byKey(const Key('chat-jump-not-found')),
        findsNothing,
        reason: 'leaving the window is not a missing message',
      );
      expect(find.byKey(const Key('chat-message-target-42')), findsNothing);
      final fetchesWhileAway = fetches;

      container.read(readerActive.notifier).state = true;
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

      expect(fetches, greaterThan(fetchesWhileAway));
      expect(find.byKey(const Key('chat-message-target-42')), findsOneWidget);
      expect(_highlightBorder(tester, 42), isNotNull);
      expect(find.byKey(const Key('chat-jump-not-found')), findsNothing);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  }

  group('loading older below a jump island', () {
    Future<({List<Uri> context, List<Uri> history})> islandRoom(
      WidgetTester tester, {
      required http.Response Function(int around) contextAnswer,
    }) async {
      for (final id in [
        for (var id = 30; id <= 54; id++) id,
        for (var id = 20001; id <= 20008; id++) id,
      ]) {
        await _insertMessage(database, account.id, id);
      }
      await _insertScope(
        database,
        account.id,
        historyCursor: '30',
        futureCursor: '20008',
        hasHistory: true,
        blocksJson: '[["30","55"],["20001","20008"]]',
      );
      await _insertScope(
        database,
        account.id,
        scopeKey: 'network-root',
        historyCursor: '20001',
        futureCursor: '20008',
        hasHistory: true,
        blocksJson: '[["20001","20008"]]',
      );
      final requests = (context: <Uri>[], history: <Uri>[]);
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          final capabilities = _capabilitiesResponse(
            request,
            messageContext: true,
          );
          if (capabilities != null) {
            return capabilities;
          }
          if (request.url.path.endsWith('/context')) {
            requests.context.add(request.url);
            final segments = request.url.pathSegments;
            return contextAnswer(int.parse(segments[segments.length - 2]));
          }
          if (request.url.queryParameters['lookIntoFuture'] == '0') {
            requests.history.add(request.url);
            return http.Response(
              jsonEncode(_historyPage(newest: 20000, oldest: 19901)),
              200,
              headers: const <String, String>{'X-Chat-Last-Given': '19901'},
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
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      return requests;
    }

    Future<ChatFetchOutcome> loadOlder(
      WidgetTester tester, {
      bool growIsland = false,
    }) async {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PresenceChatRoomScreen)),
      );
      ChatFetchOutcome? outcome;
      container
          .read(chatServiceProvider)
          .loadOlder(
            accountId: account.id,
            roomToken: 'rooma123',
            growIsland: growIsland,
          )
          .then((value) => outcome = value)
          .ignore();
      await _pumpUntil(tester, () => outcome != null);
      return outcome!;
    }

    // The pane's live loop and its last writes finish on the real event loop;
    // closing the database under them would stall the next test's database.
    Future<void> closePane(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      for (var turn = 0; turn < 50; turn++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
      }
    }

    testWidgets('a failing island fetch still pages the history cursor', (
      tester,
    ) async {
      final requests = await islandRoom(
        tester,
        contextAnswer: (_) => http.Response('', 503),
      );

      expect(await loadOlder(tester, growIsland: true), ChatFetchOutcome.done);

      expect(requests.context, hasLength(1));
      expect(requests.history, hasLength(1));
      final scopes = {
        for (final row in await database.select(database.chatScopes).get())
          row.scopeKey: row,
      };
      expect(scopes['network-root']!.blocksJson, '[["19901","20008"]]');
      expect(scopes['root']!.blocksJson, '[["30","55"],["19901","20008"]]');
      expect(scopes['root']!.lastSyncError, isNull);
      expect(scopes['network-root']!.lastSyncError, isNull);
      await closePane(tester);
    });

    testWidgets('the island grows only when the reader is at its edge', (
      tester,
    ) async {
      final requests = await islandRoom(
        tester,
        contextAnswer: (around) => http.Response(
          jsonEncode(_contextPage(oldest: around - 12, newest: around + 12)),
          200,
          headers: <String, String>{'X-Chat-Last-Given': '${around + 13}'},
        ),
      );

      await loadOlder(tester);

      expect(requests.context, isEmpty);
      expect(requests.history, hasLength(1));
      await closePane(tester);
    });

    testWidgets('an island at the start of the room is not asked again', (
      tester,
    ) async {
      // Nothing older than 30 exists: the context starts at the island.
      final requests = await islandRoom(
        tester,
        contextAnswer: (around) => http.Response(
          jsonEncode(_contextPage(oldest: around, newest: around + 12)),
          200,
          headers: <String, String>{'X-Chat-Last-Given': '${around + 13}'},
        ),
      );

      await loadOlder(tester, growIsland: true);
      await loadOlder(tester, growIsland: true);

      expect(requests.context, hasLength(1));
      expect(requests.history, hasLength(2));
      await closePane(tester);
    });
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
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: [
      ...overrides,
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

http.Response? _capabilitiesResponse(
  http.Request request, {
  bool messageContext = false,
}) {
  if (request.url.path.endsWith('/cloud/capabilities')) {
    return http.Response(
      jsonEncode(
        capabilitiesJson(
          talkFeatures: <String>[
            'conversation-v4',
            'chat-v2',
            'chat-reference-id',
            if (messageContext) 'chat-get-context',
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

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) =>
    pumpUntilCondition(
      tester,
      condition,
      reason: 'the jump target or unavailable state did not appear',
      step: const Duration(milliseconds: 1),
    );

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

/// The context endpoint answers oldest first, unlike a history page.
Map<String, Object?> _contextPage({required int oldest, required int newest}) {
  return <String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <Object?>[
        for (var id = oldest; id <= newest; id++)
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
  String? text,
}) {
  final wire = _messageJson(
    id: messageId,
    message: text ?? 'Message $messageId',
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
  String scopeKey = 'root',
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
          scopeKey: scopeKey,
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
