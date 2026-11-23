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

  group('an island around a jump target', () {
    // The server holds messages 1 to 338; the device has the newest eight.
    // The fake server answers 25 messages a page so a test pages a few times.
    Future<
      ({
        List<Uri> context,
        List<Uri> older,
        List<Uri> newer,
        List<Uri> reads,
        ProviderContainer container,
      })
    >
    islandRoom(
      WidgetTester tester, {
      int jumpTo = 100,
      Future<void>? heldOlder,
      Future<void>? heldNewer,
      http.Response? newerAnswer,
    }) async {
      for (var id = 331; id <= 338; id++) {
        await _insertMessage(database, account.id, id);
      }
      await _insertScope(
        database,
        account.id,
        historyCursor: '331',
        futureCursor: '338',
        hasHistory: true,
        blocksJson: '[["331","338"]]',
      );
      final requests = (
        context: <Uri>[],
        older: <Uri>[],
        newer: <Uri>[],
        reads: <Uri>[],
      );
      http.Response page(List<int> ids, int lastGiven) => http.Response(
        jsonEncode(<String, Object?>{
          'ocs': <String, Object?>{
            'meta': <String, Object?>{
              'status': 'ok',
              'statuscode': 200,
              'message': 'OK',
            },
            'data': <Object?>[
              for (final id in ids)
                _messageJson(id: id, message: 'Message $id'),
            ],
          },
        }),
        200,
        headers: <String, String>{'X-Chat-Last-Given': '$lastGiven'},
      );
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          final capabilities = _capabilitiesResponse(
            request,
            messageContext: true,
          );
          if (capabilities != null) {
            return capabilities;
          }
          if (request.method == 'POST') {
            requests.reads.add(request.url);
            return http.Response('', 404);
          }
          final segments = request.url.pathSegments;
          if (request.url.path.endsWith('/context')) {
            requests.context.add(request.url);
            final around = int.parse(segments[segments.length - 2]);
            final newest = math.min(around + 12, 338);
            return page([
              for (var id = math.max(1, around - 12); id <= newest; id++) id,
            ], newest);
          }
          final known = int.tryParse(
            request.url.queryParameters['lastKnownMessageId'] ?? '',
          );
          if (known == null) {
            return http.Response('', 304);
          }
          if (request.url.queryParameters['lookIntoFuture'] == '0') {
            requests.older.add(request.url);
            await heldOlder;
            final oldest = math.max(1, known - 25);
            return known <= 1
                ? http.Response('', 304)
                : page([
                    for (var id = known - 1; id >= oldest; id--) id,
                  ], oldest);
          }
          // The live poll asks after the newest message; only pages from the
          // island's newer end are counted.
          if (known >= 338) {
            return http.Response('', 304);
          }
          requests.newer.add(request.url);
          await heldNewer;
          if (newerAnswer != null) return newerAnswer;
          final newest = math.min(known + 25, 338);
          return page([
            for (var id = known + 1; id <= newest; id++) id,
          ], newest);
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
            jumpToMessageId: jumpTo,
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () =>
            find
                .byKey(Key('chat-message-target-$jumpTo'))
                .evaluate()
                .isNotEmpty ||
            find.byKey(const Key('chat-jump-not-found')).evaluate().isNotEmpty,
      );
      await _settle(tester);
      return (
        context: requests.context,
        older: requests.older,
        newer: requests.newer,
        reads: requests.reads,
        container: ProviderScope.containerOf(
          tester.element(find.byType(PresenceChatRoomScreen)),
        ),
      );
    }

    Future<void> closePane(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(const SizedBox.shrink());
      for (var turn = 0; turn < 50; turn++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
      }
    }

    Future<String> blocks(String scopeKey) async =>
        (await (database.select(
              database.chatScopes,
            )..where((scope) => scope.scopeKey.equals(scopeKey))).getSingle())
            .blocksJson;

    Finder bubble(int id) =>
        find.byKey(Key('chat-message-target-$id'), skipOffstage: false);

    Future<void> drag(WidgetTester tester, double dy) async {
      await tester.timedDrag(
        find.byKey(const Key('chat-message-list')),
        Offset(0, dy),
        const Duration(milliseconds: 300),
      );
      await _settle(tester);
    }

    void expectAscending(WidgetTester tester) {
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
      expect(ids.toSet(), hasLength(ids.length), reason: 'no row twice');
      expect(ids, orderedEquals([...ids]..sort()));
    }

    testWidgets('a jump lists only the island around the target', (
      tester,
    ) async {
      final requests = await islandRoom(tester);

      expect(find.byKey(const Key('chat-message-target-100')), findsOneWidget);
      expect(_highlightBorder(tester, 100), isNotNull);
      expect(requests.context, hasLength(1));
      expect(bubble(331), findsNothing, reason: 'the newest stay off');
      expect(
        find.byKey(const Key('chat-history-gap'), skipOffstage: false),
        findsNothing,
      );
      expect(find.byKey(const Key('chat-jump-to-newest')), findsOneWidget);
      // The island is the pane's own; the stored history is untouched.
      expect(await blocks('root'), '[["331","338"]]');
      expect(await blocks('network-root'), '[["331","338"]]');
      expect(requests.reads, isEmpty, reason: 'no read marker on old rows');
      expectAscending(tester);
      await closePane(tester);
    });

    testWidgets('reading down grows the island into the newest messages', (
      tester,
    ) async {
      final held = Completer<void>();
      addTearDown(() {
        if (!held.isCompleted) held.complete();
      });
      final requests = await islandRoom(tester, heldNewer: held.future);

      for (var turn = 0; turn < 10 && requests.newer.isEmpty; turn++) {
        await drag(tester, -150);
      }
      expect(requests.newer, hasLength(1));
      expect(
        requests.newer.single.queryParameters['lastKnownMessageId'],
        '112',
      );
      expect(requests.newer.single.queryParameters['lookIntoFuture'], '1');
      expect(requests.newer.single.queryParameters['timeout'], '0');
      final row = bubble(110);
      expect(row, findsOneWidget);
      final before = tester.getBottomLeft(row).dy;
      held.complete();
      await _pumpUntil(tester, () => bubble(113).evaluate().isNotEmpty);
      await _settle(tester);
      expect(
        tester.getBottomLeft(row).dy,
        moreOrLessEquals(before, epsilon: 1),
        reason: 'newer rows land below the reader',
      );

      for (
        var turn = 0;
        turn < 120 && await blocks('root') == '[["331","338"]]';
        turn++
      ) {
        await drag(tester, -300);
      }
      await _settle(tester);
      // 112 + 9 pages of 25 reaches 337, past where the newest begin.
      expect(requests.newer, hasLength(9));
      expect(await blocks('network-root'), '[["88","338"]]');
      expect(await blocks('root'), '[["88","338"]]');
      expect(requests.older, isEmpty);
      expect(requests.context, hasLength(1));
      for (var turn = 0; turn < 20 && bubble(338).evaluate().isEmpty; turn++) {
        await drag(tester, -300);
      }
      expect(bubble(338), findsOneWidget, reason: 'the island became the room');
      expectAscending(tester);
      await closePane(tester);
    });

    testWidgets('reading up grows the island down to the room start', (
      tester,
    ) async {
      final held = Completer<void>();
      addTearDown(() {
        if (!held.isCompleted) held.complete();
      });
      final requests = await islandRoom(tester, heldOlder: held.future);

      for (var turn = 0; turn < 10 && requests.older.isEmpty; turn++) {
        await drag(tester, 300);
      }
      expect(requests.older, hasLength(1));
      expect(requests.older.single.queryParameters['lastKnownMessageId'], '88');
      final row = bubble(90);
      expect(row, findsOneWidget);
      final before = tester.getTopLeft(row).dy;
      held.complete();
      await _pumpUntil(tester, () => bubble(87).evaluate().isNotEmpty);
      await _settle(tester);
      // The island's former first row loses its date line once older rows
      // of the same day join it, so the rows may settle by that much.
      expect(
        tester.getTopLeft(row).dy,
        moreOrLessEquals(before, epsilon: 24),
        reason: 'older rows go on top, beyond the reader',
      );

      for (var turn = 0; turn < 120 && requests.older.length < 5; turn++) {
        await drag(tester, 600);
      }
      for (var turn = 0; turn < 10; turn++) {
        await drag(tester, 600);
      }
      // 88 → 63 → 38 → 13 → 1, then the server has nothing older.
      expect(requests.older, hasLength(5));
      expect(bubble(1), findsOneWidget);
      expect(
        find.byKey(const Key('chat-load-older'), skipOffstage: false),
        findsNothing,
      );
      expect(requests.newer, isEmpty);
      expect(await blocks('network-root'), '[["331","338"]]');
      expectAscending(tester);
      await closePane(tester);
    });

    testWidgets('jump to newest leaves the island', (tester) async {
      await islandRoom(tester);

      await tester.tap(find.byKey(const Key('chat-jump-to-newest')));
      await _settle(tester);

      expect(bubble(338), findsOneWidget);
      expect(bubble(100), findsNothing);
      expect(find.byKey(const Key('chat-jump-to-newest')), findsNothing);
      await closePane(tester);
    });

    testWidgets('messages arriving meanwhile stay off the island and count', (
      tester,
    ) async {
      await islandRoom(tester);
      final row = bubble(100);
      final before = tester.getTopLeft(row).dy;

      // What the live poll would store: one more message after the newest.
      await _insertMessage(database, account.id, 339);
      await (database.update(
        database.chatScopes,
      )..where((scope) => scope.roomToken.equals('rooma123'))).write(
        const ChatScopesCompanion(
          futureCursor: Value('339'),
          blocksJson: Value('[["331","339"]]'),
        ),
      );
      await _settle(tester);

      expect(bubble(339), findsNothing);
      expect(tester.getTopLeft(row).dy, moreOrLessEquals(before, epsilon: 1));
      expect(
        find.descendant(
          of: find.byKey(const Key('chat-jump-to-newest-count')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      await closePane(tester);
    });

    testWidgets('a failed island page waits before the next one', (
      tester,
    ) async {
      final requests = await islandRoom(
        tester,
        newerAnswer: http.Response('', 503),
      );
      for (var turn = 0; turn < 10 && requests.newer.isEmpty; turn++) {
        await drag(tester, -150);
      }
      expect(requests.newer, hasLength(1));
      for (var turn = 0; turn < 4; turn++) {
        await drag(tester, turn.isEven ? 30 : -30);
      }
      expect(requests.newer, hasLength(1));

      await tester.pump(const Duration(seconds: 6));
      await drag(tester, -40);
      expect(requests.newer, hasLength(2));
      await closePane(tester);
    });
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

/// A few frames with the real event loop turning in between, for the reads
/// and writes behind a scroll to land.
Future<void> _settle(WidgetTester tester) async {
  for (var turn = 0; turn < 20; turn++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
  }
}
