import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_list_actions.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  test('mention parsing is reused across large Drift-style emissions', () {
    var parseCount = 0;
    final cache = ConversationUnreadMentionCache(
      maximumEntries: 1024,
      parser: (conversation) {
        parseCount++;
        return conversation.rawJson.endsWith('-mention');
      },
    );
    final template = _conversation(token: 'room0000', rawJson: 'revision-0');
    final first = List<CachedConversation>.generate(
      1000,
      (index) =>
          template.copyWith(token: 'room${index.toString().padLeft(4, '0')}'),
    );

    cache.retainConversations(first);
    final firstResult = [
      for (final conversation in first) cache.hasUnreadMention(conversation),
    ];
    expect(firstResult, everyElement(isFalse));
    expect(parseCount, 1000);

    final second = [for (final conversation in first) conversation.copyWith()];
    second[500] = second[500].copyWith(rawJson: 'revision-1-mention');
    cache.retainConversations(second);
    final secondResult = [
      for (final conversation in second) cache.hasUnreadMention(conversation),
    ];

    expect(secondResult.where((value) => value), hasLength(1));
    expect(secondResult[500], isTrue);
    expect(parseCount, 1001);
    expect(cache.entryCount, 1000);
  });

  test('mention cache stays effective one room above its bound', () {
    var parseCount = 0;
    final cache = ConversationUnreadMentionCache(
      maximumEntries: 2,
      parser: (_) {
        parseCount++;
        return false;
      },
    );
    final rooms = [
      _conversation(token: 'bounded1', rawJson: 'one'),
      _conversation(token: 'bounded2', rawJson: 'two'),
      _conversation(token: 'bounded3', rawJson: 'three'),
    ];

    for (final room in rooms) {
      cache.hasUnreadMention(room);
    }
    expect(parseCount, 3);
    expect(cache.entryCount, 2);

    for (final room in rooms) {
      cache.hasUnreadMention(room.copyWith());
    }

    expect(parseCount, 4);
    expect(cache.entryCount, 2);
  });

  testWidgets('three localized filters fit a 360 dp pane or reflow', (
    tester,
  ) async {
    // Ahem draws a glyph one em wide, so these labels measure about twice what
    // they do in Roboto; 360 dp here is a pane well under 300 dp in practice.
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Future<void> pumpAt(double textScale, Locale locale) => tester.pumpWidget(
      _app(
        account: _account(withArchiveCapability: true),
        conversations: [_conversation(token: 'room0001')],
        locale: locale,
        textScale: textScale,
      ),
    );

    const filterKeys = <Key>[
      Key('conversation-filter-unread'),
      Key('conversation-filter-mentions'),
      Key('conversation-filter-archived'),
    ];

    await pumpAt(1, const Locale('en'));

    final filterBounds = tester.getRect(
      find.byKey(const Key('conversation-filters')),
    );
    final regularBounds = [
      for (final key in filterKeys) tester.getRect(find.byKey(key)),
    ];
    for (final bounds in regularBounds) {
      expect(bounds.left, greaterThanOrEqualTo(filterBounds.left));
      expect(bounds.right, lessThanOrEqualTo(filterBounds.right));
    }
    expect(
      regularBounds.map((bounds) => bounds.top).toSet(),
      hasLength(1),
      reason:
          'The normal labels should stay in one compact row: $regularBounds',
    );
    expect(find.text('Unread'), findsOneWidget);
    expect(find.text('Mentions'), findsOneWidget);
    expect(find.text('Archived'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await pumpAt(2, const Locale('cs'));

    final scaledFilterBounds = tester.getRect(
      find.byKey(const Key('conversation-filters')),
    );
    final scaledBounds = [
      for (final key in filterKeys) tester.getRect(find.byKey(key)),
    ];
    for (final bounds in scaledBounds) {
      expect(bounds.left, greaterThanOrEqualTo(scaledFilterBounds.left));
      expect(bounds.right, lessThanOrEqualTo(scaledFilterBounds.right));
    }
    expect(
      scaledBounds.map((bounds) => bounds.top).toSet().length,
      greaterThan(1),
      reason: 'Large localized labels should reflow instead of clipping.',
    );
    expect(find.text('Nepřečtené'), findsOneWidget);
    expect(find.text('Zmínky'), findsOneWidget);
    expect(find.text('Archivované'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unread and mention filters combine without exposing archives', (
    tester,
  ) async {
    final unreadMention = _conversation(
      token: 'unreadmention1',
      unreadMessages: 2,
      unreadMention: true,
    );
    final unreadOnly = _conversation(token: 'unreadonly1', unreadMessages: 3);
    final mentionOnly = _conversation(
      token: 'mentiononly1',
      unreadMention: true,
    );
    final read = _conversation(token: 'readroom1');
    final archived = _conversation(
      token: 'archivedroom1',
      unreadMessages: 4,
      unreadMention: true,
      archived: true,
    );

    await tester.pumpWidget(
      _app(
        account: _account(withArchiveCapability: true),
        conversations: [unreadMention, unreadOnly, mentionOnly, read, archived],
      ),
    );

    expect(_tile('unreadmention1'), findsOneWidget);
    expect(_tile('unreadonly1'), findsOneWidget);
    expect(_tile('mentiononly1'), findsOneWidget);
    expect(_tile('readroom1'), findsOneWidget);
    expect(_tile('archivedroom1'), findsNothing);

    await tester.tap(find.byKey(const Key('conversation-filter-unread')));
    await tester.pump();

    expect(_tile('unreadmention1'), findsOneWidget);
    expect(_tile('unreadonly1'), findsOneWidget);
    expect(_tile('mentiononly1'), findsNothing);
    expect(_tile('readroom1'), findsNothing);
    expect(_tile('archivedroom1'), findsNothing);

    await tester.tap(find.byKey(const Key('conversation-filter-mentions')));
    await tester.pump();

    expect(
      tester
          .widget<FilterChip>(
            find.byKey(const Key('conversation-filter-mentions')),
          )
          .selected,
      isTrue,
    );
    expect(
      ConversationRoom.fromJson(
        jsonDecode(unreadMention.rawJson),
      ).unreadMention,
      isTrue,
    );
    expect(_tile('unreadmention1'), findsOneWidget);
    expect(_tile('unreadonly1'), findsNothing);
    expect(_tile('mentiononly1'), findsNothing);
    expect(_tile('archivedroom1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one-to-one unread conversations match the mention filter', (
    tester,
  ) async {
    final direct = _conversation(
      token: 'directroom1',
      roomType: 1,
      unreadMessages: 1,
    );
    final formerDirect = _conversation(
      token: 'formerdirect1',
      roomType: 5,
      unreadMessages: 1,
    );
    final group = _conversation(
      token: 'grouproom1',
      roomType: 2,
      unreadMessages: 1,
    );

    await tester.pumpWidget(
      _app(account: _account(), conversations: [direct, formerDirect, group]),
    );
    await tester.tap(find.byKey(const Key('conversation-filter-mentions')));
    await tester.pump();

    expect(ConversationRoom.fromJson(jsonDecode(formerDirect.rawJson)).type, 5);
    expect(_tile('directroom1'), findsOneWidget);
    expect(_tile('formerdirect1'), findsOneWidget);
    expect(_tile('grouproom1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('archive filter is capability-gated and combines with unread', (
    tester,
  ) async {
    final active = _conversation(token: 'activeroom1', unreadMessages: 2);
    final archivedUnread = _conversation(
      token: 'archivedunread1',
      unreadMessages: 2,
      archived: true,
    );
    final archivedRead = _conversation(token: 'archivedread1', archived: true);

    await tester.pumpWidget(
      _app(
        account: _account(withArchiveCapability: true),
        conversations: [active, archivedUnread, archivedRead],
      ),
    );
    expect(
      find.byKey(const Key('conversation-filter-archived')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('conversation-filter-archived')));
    await tester.pump();
    expect(_tile('activeroom1'), findsNothing);
    expect(_tile('archivedunread1'), findsOneWidget);
    expect(_tile('archivedread1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('conversation-filter-unread')));
    await tester.pump();
    expect(_tile('archivedunread1'), findsOneWidget);
    expect(_tile('archivedread1'), findsNothing);

    await tester.pumpWidget(
      _app(
        account: _account(),
        conversations: [active, archivedUnread, archivedRead],
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('conversation-filter-archived')), findsNothing);
    expect(_tile('activeroom1'), findsOneWidget);
    expect(_tile('archivedunread1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching account clears account-specific filters', (
    tester,
  ) async {
    final account = ValueNotifier<StoredAccount>(_account());
    addTearDown(account.dispose);
    final roomsByAccount = <String, List<CachedConversation>>{
      'account-a': [
        _conversation(token: 'aunread1', unreadMessages: 1),
        _conversation(token: 'aread000'),
      ],
      'account-b': [_conversation(token: 'bread000', accountId: 'account-b')],
    };

    await tester.pumpWidget(
      _switchableApp(account: account, roomsByAccount: roomsByAccount),
    );
    await tester.tap(find.byKey(const Key('conversation-filter-unread')));
    await tester.pump();
    expect(_tile('aunread1'), findsOneWidget);
    expect(_tile('aread000'), findsNothing);

    account.value = _account(id: 'account-b');
    await tester.pump();

    expect(_tile('bread000'), findsOneWidget);
    final chip = tester.widget<FilterChip>(
      find.byKey(const Key('conversation-filter-unread')),
    );
    expect(chip.selected, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching account resets the conversation list scroll offset', (
    tester,
  ) async {
    final account = ValueNotifier<StoredAccount>(_account());
    addTearDown(account.dispose);
    final roomsByAccount = <String, List<CachedConversation>>{
      'account-a': List.generate(
        20,
        (index) =>
            _conversation(token: 'aroom${index.toString().padLeft(2, '0')}'),
      ),
      'account-b': List.generate(
        20,
        (index) => _conversation(
          token: 'broom${index.toString().padLeft(2, '0')}',
          accountId: 'account-b',
        ),
      ),
    };

    await tester.pumpWidget(
      _switchableApp(account: account, roomsByAccount: roomsByAccount),
    );

    Finder verticalScrollable() => find.descendant(
      of: find.byType(ConversationListView),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
    );

    expect(verticalScrollable(), findsOneWidget);
    await tester.drag(verticalScrollable(), const Offset(0, -1000));
    await tester.pump();
    expect(
      tester.state<ScrollableState>(verticalScrollable()).position.pixels,
      greaterThan(0),
    );

    account.value = _account(id: 'account-b');
    await tester.pump();

    expect(
      tester.state<ScrollableState>(verticalScrollable()).position.pixels,
      0,
    );
    expect(_tile('broom00'), findsOneWidget);
  });

  testWidgets('switching account releases a pending pull-to-refresh', (
    tester,
  ) async {
    final account = ValueNotifier<StoredAccount>(_account());
    addTearDown(account.dispose);
    final firstRefresh = Completer<void>();
    final secondRefresh = Completer<void>();
    addTearDown(() {
      if (!firstRefresh.isCompleted) firstRefresh.complete();
      if (!secondRefresh.isCompleted) secondRefresh.complete();
    });
    final refreshed = <String>[];

    await tester.pumpWidget(
      _switchableApp(
        account: account,
        roomsByAccount: {
          'account-a': [_conversation(token: 'aroom001')],
          'account-b': [
            _conversation(token: 'broom001', accountId: 'account-b'),
          ],
        },
        refreshByAccount: {
          'account-a': () {
            refreshed.add('account-a');
            return firstRefresh.future;
          },
          'account-b': () {
            refreshed.add('account-b');
            return secondRefresh.future;
          },
        },
      ),
    );

    final firstIndicator = tester.state<RefreshIndicatorState>(
      find.byType(RefreshIndicator),
    );
    unawaited(firstIndicator.show());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(refreshed, ['account-a']);

    account.value = _account(id: 'account-b');
    await tester.pump();
    final secondIndicator = tester.state<RefreshIndicatorState>(
      find.byType(RefreshIndicator),
    );
    unawaited(secondIndicator.show());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(refreshed, ['account-a', 'account-b']);
    secondRefresh.complete();
    firstRefresh.complete();
  });

  testWidgets('corrupt room payload fails closed for mention filtering', (
    tester,
  ) async {
    final corrupt = _conversation(token: 'corruptroom1', rawJson: '{}');
    final valid = _conversation(token: 'validroom1', unreadMention: true);

    await tester.pumpWidget(
      _app(account: _account(), conversations: [corrupt, valid]),
    );
    await tester.tap(find.byKey(const Key('conversation-filter-mentions')));
    await tester.pump();

    expect(_tile('corruptroom1'), findsNothing);
    expect(_tile('validroom1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _app({
  required StoredAccount account,
  required List<CachedConversation> conversations,
  Locale locale = const Locale('en'),
  double textScale = 1,
}) {
  return ProviderScope(
    overrides: [
      conversationAvatarProvider.overrideWith((ref, key) async => null),
    ],
    child: localizedTestApp(
      locale: locale,
      textScale: textScale,
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

Widget _switchableApp({
  required ValueNotifier<StoredAccount> account,
  required Map<String, List<CachedConversation>> roomsByAccount,
  Map<String, Future<void> Function()> refreshByAccount = const {},
}) {
  return ProviderScope(
    overrides: [
      conversationAvatarProvider.overrideWith((ref, key) async => null),
    ],
    child: localizedTestApp(
      home: Scaffold(
        body: ValueListenableBuilder<StoredAccount>(
          valueListenable: account,
          builder: (context, value, child) => ConversationListView(
            account: value,
            conversations: roomsByAccount[value.id] ?? const [],
            loading: false,
            onRefresh: refreshByAccount[value.id] ?? () async {},
            onSelect: (_) {},
          ),
        ),
      ),
    ),
  );
}

Finder _tile(String token) => find.byKey(Key('conversation-tile-$token'));

StoredAccount _account({
  String id = 'account-a',
  bool withArchiveCapability = false,
}) {
  return StoredAccount(
    id: id,
    serverUrl: 'https://example.invalid',
    loginName: 'fixture-user',
    serverProductName: 'Nextcloud',
    talkFeaturesJson: jsonEncode([
      if (withArchiveCapability) 'archived-conversations-v2',
    ]),
    selected: true,
    createdAtMillis: 0,
  );
}

CachedConversation _conversation({
  required String token,
  String accountId = 'account-a',
  int roomType = 2,
  int unreadMessages = 0,
  bool unreadMention = false,
  bool archived = false,
  String? rawJson,
}) {
  final wire = _roomWire()
    ..['token'] = token
    ..['type'] = roomType
    ..['unreadMessages'] = unreadMessages
    ..['unreadMention'] = unreadMention
    ..['isArchived'] = archived;
  final lastMessage = wire['lastMessage'];
  if (lastMessage is Map<String, Object?>) {
    wire['lastMessage'] = Map<String, Object?>.from(lastMessage)
      ..['token'] = token;
  }
  return CachedConversation(
    accountId: accountId,
    token: token,
    displayName: token,
    description: '',
    lastActivity: 1,
    unreadMessages: unreadMessages,
    favorite: false,
    isArchived: archived,
    readOnly: 0,
    roomType: roomType,
    roomName: token,
    objectType: '',
    avatarVersion: '',
    isCustomAvatar: false,
    lastMessageText: 'Preview',
    lastMessageTimestamp: 1,
    rawJson: rawJson ?? jsonEncode(wire),
  );
}

Map<String, Object?> _roomWire() {
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
