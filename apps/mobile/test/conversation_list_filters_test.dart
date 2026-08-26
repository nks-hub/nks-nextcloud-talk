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
}) {
  return ProviderScope(
    overrides: [
      conversationAvatarProvider.overrideWith((ref, key) async => null),
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

Widget _switchableApp({
  required ValueNotifier<StoredAccount> account,
  required Map<String, List<CachedConversation>> roomsByAccount,
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
            onRefresh: () async {},
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
