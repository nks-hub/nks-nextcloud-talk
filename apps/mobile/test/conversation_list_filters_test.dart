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

  for (final width in [280.0, 300.0, 360.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('localized filter tabs remain reachable at '
          '${width.toInt()} dp and ${(scale * 100).toInt()} % text', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final semantics = tester.ensureSemantics();

        const filterKeys = <Key>[
          Key('conversation-filter-all'),
          Key('conversation-filter-unread'),
          Key('conversation-filter-mentions'),
          Key('conversation-filter-archived'),
        ];
        for (final locale in const [Locale('en'), Locale('cs')]) {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpWidget(
            _app(
              account: _account(withArchiveCapability: true),
              conversations: [_conversation(token: 'room0001')],
              locale: locale,
              textScale: scale,
            ),
          );
          expect(tester.takeException(), isNull, reason: '$locale');

          final bar = tester.getRect(
            find.byKey(const Key('conversation-filters')),
          );
          // Same 12 dp inset as the search field above the list.
          expect(
            tester.getRect(find.byKey(filterKeys.first)).left - bar.left,
            12,
          );
          final rects = [
            for (final key in filterKeys) tester.getRect(find.byKey(key)),
          ];
          for (var i = 0; i < rects.length; i++) {
            final chip = rects[i];
            // Every tab is fully inside the bar's insets without scrolling.
            expect(chip.left, greaterThanOrEqualTo(bar.left + 12));
            expect(chip.right, lessThanOrEqualTo(bar.right - 12 + 0.5));
            final label = tester.getRect(
              find.descendant(
                of: find.byKey(filterKeys[i]),
                matching: find.byType(Text),
              ),
            );
            expect(
              label.left - chip.left,
              greaterThanOrEqualTo(8),
              reason: 'text keeps room from the left border, $locale',
            );
            expect(
              chip.right - label.right,
              greaterThanOrEqualTo(8),
              reason: 'text keeps room from the right border, $locale',
            );
            if (i > 0) {
              final previous = rects[i - 1];
              if (previous.top == chip.top) {
                expect(chip.left - previous.right, 4, reason: 'gap, $locale');
              } else {
                expect(chip.top - previous.bottom, greaterThanOrEqualTo(2));
              }
            }
          }
          // Wrapped or not, the chips never overlap each other.
          for (var i = 0; i < rects.length; i++) {
            for (var j = i + 1; j < rects.length; j++) {
              expect(rects[i].overlaps(rects[j]), isFalse);
            }
          }
          expect(
            tester
                .getSemantics(find.byKey(const Key('conversation-filters')))
                .label,
            matches(RegExp('ilter|iltry')),
          );
        }
        semantics.dispose();
      });
    }
  }

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

  testWidgets('switching account clears its search and filters', (
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

    final search = find.byKey(const Key('conversation-name-search'));
    await tester.enterText(search, 'aunread');
    await tester.pump();

    account.value = _account(id: 'account-b');
    await tester.pump();

    expect(tester.widget<TextField>(search).controller!.text, isEmpty);
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
