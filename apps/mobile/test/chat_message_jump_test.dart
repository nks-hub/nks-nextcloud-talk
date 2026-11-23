import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
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

  group('a gap left by a jump', () {
    // Island 30-55 from an earlier jump, the newest messages from 331, and
    // three history pages of unknown messages between them.
    Future<({List<Uri> context, List<Uri> history})> gapRoom(
      WidgetTester tester, {
      List<Override> overrides = const [],
      Future<void>? firstPageHeld,
      http.Response? historyAnswer,
      Future<http.Response> Function(int around)? contextAnswer,
      bool messageContext = true,
      int? jumpTo,
    }) async {
      for (final id in [
        for (var id = 30; id <= 54; id++) id,
        for (var id = 331; id <= 338; id++) id,
      ]) {
        await _insertMessage(database, account.id, id);
      }
      await _insertScope(
        database,
        account.id,
        historyCursor: '30',
        futureCursor: '338',
        hasHistory: true,
        blocksJson: '[["30","55"],["331","338"]]',
      );
      await _insertScope(
        database,
        account.id,
        scopeKey: 'network-root',
        historyCursor: '331',
        futureCursor: '338',
        hasHistory: true,
        blocksJson: '[["331","338"]]',
      );
      final requests = (context: <Uri>[], history: <Uri>[]);
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          final capabilities = _capabilitiesResponse(
            request,
            messageContext: messageContext,
          );
          if (capabilities != null) {
            return capabilities;
          }
          if (request.url.path.endsWith('/context')) {
            requests.context.add(request.url);
            if (contextAnswer != null) {
              final segments = request.url.pathSegments;
              return contextAnswer(int.parse(segments[segments.length - 2]));
            }
            // The island already starts with the room.
            return http.Response(
              jsonEncode(_contextPage(oldest: 30, newest: 42)),
              200,
              headers: const <String, String>{'X-Chat-Last-Given': '43'},
            );
          }
          if (request.url.queryParameters['lookIntoFuture'] == '0') {
            requests.history.add(request.url);
            if (requests.history.length == 1) await firstPageHeld;
            if (historyAnswer != null) return historyAnswer;
            final anchor = int.parse(
              request.url.queryParameters['lastKnownMessageId']!,
            );
            final oldest = (anchor - 100).clamp(30, anchor - 1);
            return http.Response(
              jsonEncode(_historyPage(newest: anchor - 1, oldest: oldest)),
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
          overrides: overrides,
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
            jumpToMessageId: jumpTo,
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('chat-message-list')).evaluate().isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      return requests;
    }

    Future<void> settle(WidgetTester tester) async {
      for (var turn = 0; turn < 20; turn++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
      }
    }

    Future<void> closePane(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      for (var turn = 0; turn < 50; turn++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
      }
    }

    Future<String> viewBlocks() async => (await (database.select(
      database.chatScopes,
    )..where((scope) => scope.scopeKey.equals('root'))).getSingle()).blocksJson;

    testWidgets('closes while the reader scrolls up from the newest messages', (
      tester,
    ) async {
      final requests = await gapRoom(tester);

      for (
        var turn = 0;
        turn < 80 && await viewBlocks() != '[["30","338"]]';
        turn++
      ) {
        await tester.drag(
          find.byKey(const Key('chat-message-list')),
          const Offset(0, 600),
        );
        await settle(tester);
      }

      expect(await viewBlocks(), '[["30","338"]]');
      expect(requests.history, hasLength(3));
      // At most the one island fetch that finds the island at the room start.
      expect(requests.context.length, lessThanOrEqualTo(1));
      await settle(tester);
      expect(
        find.byKey(const Key('chat-history-gap'), skipOffstage: false),
        findsNothing,
      );
      await closePane(tester);
    });

    testWidgets('reaching the divider pages the cursor and moves no row', (
      tester,
    ) async {
      final held = Completer<void>();
      addTearDown(() {
        if (!held.isCompleted) held.complete();
      });
      final requests = await gapRoom(tester, firstPageHeld: held.future);
      final gap = find.byKey(const Key('chat-history-gap'));
      for (var turn = 0; turn < 40 && gap.evaluate().isEmpty; turn++) {
        await tester.timedDrag(
          find.byKey(const Key('chat-message-list')),
          const Offset(0, 120),
          const Duration(milliseconds: 400),
        );
        await settle(tester);
      }
      expect(gap, findsOneWidget);
      await _pumpUntil(tester, () => requests.history.isNotEmpty);
      // The bubble's bottom edge: once the gap closes in front of it the row
      // loses its divider and the bubble its author line, both above it.
      final newestOld = find.byKey(const Key('chat-message-target-331'));
      expect(newestOld, findsOneWidget);
      final before = tester.getBottomLeft(newestOld).dy;

      held.complete();
      for (
        var turn = 0;
        turn < 100 && await viewBlocks() == '[["30","55"],["331","338"]]';
        turn++
      ) {
        await settle(tester);
      }
      await settle(tester);

      expect(await viewBlocks(), '[["30","55"],["231","338"]]');
      expect(requests.context, isEmpty, reason: 'no island fetch on the way');
      expect(newestOld, findsOneWidget);
      expect(
        tester.getBottomLeft(newestOld).dy,
        moreOrLessEquals(before, epsilon: 1),
      );
      await closePane(tester);
    });

    testWidgets('the island side of the divider does not page the cursor', (
      tester,
    ) async {
      final requests = await gapRoom(tester, jumpTo: 50);
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('chat-message-target-50'))
            .evaluate()
            .isNotEmpty,
      );
      await settle(tester);
      final gap = find.byKey(
        const Key('chat-history-gap'),
        skipOffstage: false,
      );
      // The reader stays in the island and nudges towards the newer end,
      // where the divider sits below them.
      for (var turn = 0; turn < 4; turn++) {
        await tester.timedDrag(
          find.byKey(const Key('chat-message-list')),
          const Offset(0, -40),
          const Duration(milliseconds: 300),
        );
        await settle(tester);
      }
      expect(gap, findsOneWidget);
      final viewport = tester.getRect(
        find.byKey(const Key('chat-message-list')),
      );
      expect(
        tester.getTopLeft(gap).dy,
        greaterThan(viewport.center.dy),
        reason: 'the divider must still sit below the middle of the list',
      );
      expect(
        requests.history,
        isEmpty,
        reason: 'paging the cursor from here only adds the newest messages',
      );
      // Below the island the newer messages still read top to bottom.
      Finder bubble(int id) =>
          find.byKey(Key('chat-message-target-$id'), skipOffstage: false);
      final newer = [
        for (var id = 331; id <= 338; id++)
          if (bubble(id).evaluate().isNotEmpty)
            tester.getTopLeft(bubble(id)).dy,
      ];
      expect(newer.length, greaterThan(1));
      expect(newer, orderedEquals([...newer]..sort()));
      await tester.pump(const Duration(seconds: 3));
      await closePane(tester);
    });

    // A server holding every message from 30 to 338: up to 100 at or before
    // the asked id and up to 100 after it, oldest first.
    Future<http.Response> serverContext(int around) async {
      final newest = math.min(around + 100, 338);
      return http.Response(
        jsonEncode(
          _contextPage(oldest: math.max(30, around - 100), newest: newest),
        ),
        200,
        headers: <String, String>{'X-Chat-Last-Given': '$newest'},
      );
    }

    testWidgets('the island grows forward from its newer end', (tester) async {
      final firstHeld = Completer<void>();
      addTearDown(() {
        if (!firstHeld.isCompleted) firstHeld.complete();
      });
      var answered = 0;
      final requests = await gapRoom(
        tester,
        jumpTo: 50,
        contextAnswer: (around) async {
          if (answered++ == 0) await firstHeld.future;
          return serverContext(around);
        },
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('chat-message-target-50'))
            .evaluate()
            .isNotEmpty,
      );
      await settle(tester);
      Future<void> nudge() async {
        await tester.timedDrag(
          find.byKey(const Key('chat-message-list')),
          const Offset(0, -60),
          const Duration(milliseconds: 300),
        );
        await settle(tester);
      }

      // The reader reads on towards the newer end of the island.
      for (var turn = 0; turn < 10 && requests.context.isEmpty; turn++) {
        await nudge();
      }
      expect(requests.context, hasLength(1));
      expect(
        requests.context.single.path,
        endsWith('/chat/rooma123/54/context'),
      );
      final row = find.byKey(const Key('chat-message-target-52'));
      expect(row, findsOneWidget);
      final before = tester.getBottomLeft(row).dy;
      firstHeld.complete();
      for (
        var turn = 0;
        turn < 100 && await viewBlocks() == '[["30","55"],["331","338"]]';
        turn++
      ) {
        await settle(tester);
      }
      expect(await viewBlocks(), '[["30","154"],["331","338"]]');
      expect(
        tester.getBottomLeft(row).dy,
        moreOrLessEquals(before, epsilon: 1),
        reason: 'the newer messages land below the reader',
      );

      for (
        var turn = 0;
        turn < 150 && await viewBlocks() != '[["30","338"]]';
        turn++
      ) {
        await nudge();
      }
      expect(await viewBlocks(), '[["30","338"]]');
      expect(requests.context, hasLength(3), reason: 'one per 100 messages');
      expect(requests.history, isEmpty);
      final shown = [
        for (final element
            in find
                .byWidgetPredicate(
                  (widget) =>
                      widget is GestureDetector &&
                      widget.key is ValueKey<String> &&
                      (widget.key! as ValueKey<String>).value.startsWith(
                        'chat-message-target-',
                      ),
                )
                .evaluate())
          (
            id: int.parse(
              (element.widget.key! as ValueKey<String>).value.split('-').last,
            ),
            top: tester.getTopLeft(find.byWidget(element.widget)).dy,
          ),
      ]..sort((a, b) => a.top.compareTo(b.top));
      final ids = [for (final row in shown) row.id];
      expect(ids, orderedEquals([...ids]..sort()));
      await tester.pump(const Duration(seconds: 3));
      await closePane(tester);
    });

    testWidgets('a failed forward fetch waits before the next one', (
      tester,
    ) async {
      final requests = await gapRoom(
        tester,
        jumpTo: 50,
        contextAnswer: (_) async => http.Response('', 503),
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('chat-message-target-50'))
            .evaluate()
            .isNotEmpty,
      );
      await settle(tester);
      for (var turn = 0; turn < 10 && requests.context.isEmpty; turn++) {
        await tester.timedDrag(
          find.byKey(const Key('chat-message-list')),
          const Offset(0, -60),
          const Duration(milliseconds: 300),
        );
        await settle(tester);
      }
      expect(requests.context, hasLength(1));
      for (var turn = 0; turn < 4; turn++) {
        await tester.timedDrag(
          find.byKey(const Key('chat-message-list')),
          Offset(0, turn.isEven ? -20 : 20),
          const Duration(milliseconds: 100),
        );
        await settle(tester);
      }
      expect(requests.context, hasLength(1));

      await tester.pump(const Duration(seconds: 6));
      await tester.timedDrag(
        find.byKey(const Key('chat-message-list')),
        const Offset(0, -20),
        const Duration(milliseconds: 100),
      );
      await settle(tester);
      expect(requests.context, hasLength(2));
      expect(requests.history, isEmpty);
      await tester.pump(const Duration(seconds: 3));
      await closePane(tester);
    });

    testWidgets('without the context endpoint the divider stays', (
      tester,
    ) async {
      final requests = await gapRoom(tester, jumpTo: 50, messageContext: false);
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('chat-message-target-50'))
            .evaluate()
            .isNotEmpty,
      );
      await settle(tester);
      for (var turn = 0; turn < 4; turn++) {
        await tester.timedDrag(
          find.byKey(const Key('chat-message-list')),
          const Offset(0, -40),
          const Duration(milliseconds: 300),
        );
        await settle(tester);
      }
      expect(requests.context, isEmpty);
      expect(requests.history, isEmpty);
      expect(await viewBlocks(), '[["30","55"],["331","338"]]');
      await tester.pump(const Duration(seconds: 3));
      await closePane(tester);
    });

    for (final (label, answer) in [
      ('a failed', http.Response('', 503)),
      ('an empty', http.Response('', 412)),
    ]) {
      testWidgets('$label page is not asked for again on the next ticks', (
        tester,
      ) async {
        final requests = await gapRoom(tester, historyAnswer: answer);
        final gap = find.byKey(const Key('chat-history-gap'));
        for (var turn = 0; turn < 40 && requests.history.isEmpty; turn++) {
          await tester.timedDrag(
            find.byKey(const Key('chat-message-list')),
            const Offset(0, 60),
            const Duration(milliseconds: 200),
          );
          await settle(tester);
        }
        expect(requests.history, hasLength(1));
        expect(gap, findsOneWidget);

        // More scroll ticks at the divider within the pause send nothing.
        for (var turn = 0; turn < 4; turn++) {
          await tester.timedDrag(
            find.byKey(const Key('chat-message-list')),
            Offset(0, turn.isEven ? 20 : -20),
            const Duration(milliseconds: 100),
          );
          await settle(tester);
        }
        expect(requests.history, hasLength(1));

        // Once the pause is over the next tick asks again.
        await tester.pump(const Duration(seconds: 6));
        await tester.timedDrag(
          find.byKey(const Key('chat-message-list')),
          const Offset(0, 20),
          const Duration(milliseconds: 100),
        );
        await settle(tester);
        expect(requests.history, hasLength(2));
        await closePane(tester);
      });
    }

    testWidgets('a page into the gap keeps the island top on screen', (
      tester,
    ) async {
      final held = Completer<void>();
      addTearDown(() {
        if (!held.isCompleted) held.complete();
      });
      // A window just big enough for the room, so a page of newer messages
      // would push the island's oldest rows out of it.
      final requests = await gapRoom(
        tester,
        firstPageHeld: held.future,
        overrides: [chatMessageWindowProvider.overrideWith((ref, key) => 34)],
      );

      // Up to the island's oldest edge, where the reader stays while the
      // page lands.
      await tester.drag(
        find.byKey(const Key('chat-message-list')),
        const Offset(0, 6000),
      );
      await _pumpUntil(tester, () => requests.history.isNotEmpty);
      await settle(tester);
      final oldest = find.byKey(
        const ValueKey('chat-message-account-a-rooma123-30'),
      );
      expect(oldest, findsOneWidget);

      held.complete();
      for (
        var turn = 0;
        turn < 100 && await viewBlocks() == '[["30","55"],["331","338"]]';
        turn++
      ) {
        await settle(tester);
      }
      await settle(tester);

      expect(await viewBlocks(), isNot('[["30","55"],["331","338"]]'));
      expect(
        oldest,
        findsOneWidget,
        reason: 'the cached oldest message must not drop out of the window',
      );
      await closePane(tester);
    });
  });

  testWidgets('a page filling the gap below the island moves no visible row', (
    tester,
  ) async {
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
    final page = Completer<http.Response>();
    addTearDown(() {
      if (!page.isCompleted) page.complete(http.Response('', 503));
    });
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
          // The island already starts with the room.
          return http.Response(
            jsonEncode(_contextPage(oldest: 30, newest: 42)),
            200,
            headers: const <String, String>{'X-Chat-Last-Given': '43'},
          );
        }
        if (request.url.queryParameters['lookIntoFuture'] == '0') {
          historyRequests++;
          return page.future;
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
      () =>
          find.byKey(const Key('chat-message-list')).evaluate().isNotEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty,
    );

    // The reader scrolls up from the newest messages into the island; at its
    // oldest edge the history cursor is paged into the gap below them.
    await tester.drag(
      find.byKey(const Key('chat-message-list')),
      const Offset(0, 4000),
    );
    await _pumpUntil(tester, () => historyRequests == 1);
    // Settled by frames, not pumpAndSettle: its fake minutes would time the
    // held page request out.
    for (var turn = 0; turn < 60; turn++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final row = find.byKey(
      const ValueKey('chat-message-account-a-rooma123-32'),
    );
    expect(row, findsOneWidget);
    final before = tester.getTopLeft(row);

    page.complete(
      http.Response(
        jsonEncode(_historyPage(newest: 20000, oldest: 19901)),
        200,
        headers: const <String, String>{'X-Chat-Last-Given': '19901'},
      ),
    );
    Future<String> networkCursor() async =>
        (await (database.select(database.chatScopes)
                  ..where((scope) => scope.scopeKey.equals('network-root')))
                .getSingle())
            .historyCursor;
    for (var turn = 0; turn < 200 && await networkCursor() != '19901'; turn++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    expect(await networkCursor(), '19901');
    for (var turn = 0; turn < 20; turn++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(row, findsOneWidget);
    expect(tester.getTopLeft(row).dy, moreOrLessEquals(before.dy, epsilon: 1));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    for (var turn = 0; turn < 50; turn++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
    }
  });

  for (final dark in [false, true]) {
    testWidgets('the jump highlight stands out on both bubbles '
        '(${dark ? 'dark' : 'light'})', (tester) async {
      for (var id = 101; id <= 130; id++) {
        await _insertMessage(
          database,
          account.id,
          id,
          actorId: id.isEven ? 'fixture-user' : 'someone-else',
        );
      }
      await _insertScope(
        database,
        account.id,
        historyCursor: '101',
        futureCursor: '130',
        hasHistory: false,
        blocksJson: '[["101","130"]]',
      );
      final theme = dark ? AppTheme.dark() : AppTheme.light();
      final scheme = theme.colorScheme;
      // 105 is someone else's, 106 the reader's own.
      for (final target in [105, 106]) {
        final api = HttpNextcloudApi(client: MockClient(_convergedServer));
        await tester.pumpWidget(
          _app(
            database: database,
            vault: vault,
            api: api,
            theme: theme,
            home: PresenceChatRoomScreen(
              key: ValueKey(target),
              account: account,
              conversation: conversation,
              jumpToMessageId: target,
            ),
          ),
        );
        await _pumpUntil(
          tester,
          () =>
              find
                  .byKey(Key('chat-message-target-$target'))
                  .evaluate()
                  .isNotEmpty &&
              _highlightBorder(tester, target) != null,
        );
        final decoration = _bubbleDecoration(tester, target);
        final bubble = decoration.color!;
        final ring = (decoration.border! as Border).top.color;
        expect(
          _contrast(ring, bubble),
          greaterThanOrEqualTo(3),
          reason: 'the ring must show against the bubble ($target)',
        );
        final halo = decoration.boxShadow;
        expect(halo, isNotEmpty, reason: 'nothing marks the bubble outside');
        expect(
          _contrast(halo!.first.color, scheme.surface),
          greaterThanOrEqualTo(3),
          reason: 'the halo must show against the room behind ($target)',
        );
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
        api.close();
      }
    });
  }

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
  ThemeData? theme,
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
    child: localizedTestApp(home: home, theme: theme),
  );
}

double _contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  return (math.max(first, second) + 0.05) / (math.min(first, second) + 0.05);
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

BoxDecoration _bubbleDecoration(WidgetTester tester, int messageId) =>
    tester
            .widget<AnimatedContainer>(
              find.descendant(
                of: find.byKey(Key('chat-message-target-$messageId')),
                matching: find.byType(AnimatedContainer),
              ),
            )
            .decoration!
        as BoxDecoration;

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
  String actorId = 'someone-else',
}) {
  return <String, Object?>{
    'id': id,
    'token': 'rooma123',
    'actorType': 'users',
    'actorId': actorId,
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
  String actorId = 'someone-else',
}) {
  final wire = _messageJson(
    id: messageId,
    message: text ?? 'Message $messageId',
    parent: parent,
    actorId: actorId,
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
