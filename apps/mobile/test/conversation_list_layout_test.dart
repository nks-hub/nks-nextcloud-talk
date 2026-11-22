import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/core/tonal_state_icon.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_list_actions.dart';

import 'test_support.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    List<CachedConversation> conversations, {
    double textScale = 1,
    double width = 900,
  }) async {
    tester.view
      ..physicalSize = Size(width, 700)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationAvatarProvider.overrideWith((ref, key) async => null),
        ],
        child: localizedTestApp(
          textScale: textScale,
          home: Scaffold(
            body: ConversationListView(
              account: _account,
              conversations: conversations,
              loading: false,
              onRefresh: () async {},
              onSelect: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the date sits at the right edge of a wide row', (tester) async {
    await pump(tester, [_conversation('room-a', 'Synthetic peer')]);

    final tile = tester.getRect(
      find.byKey(const Key('conversation-tile-room-a')),
    );
    final date = tester.getRect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            RegExp(r'^\d+/\d+/\d{4}$').hasMatch(widget.data ?? ''),
      ),
    );
    expect(
      tile.right - date.right,
      lessThan(32),
      reason: 'the date belongs at the edge, not floating mid-row',
    );
  });

  testWidgets(
    'filters are regular chips on a phone and tight in a narrow pane',
    (tester) async {
      double? labelSize() => tester
          .widget<FilterChip>(
            find.byKey(const Key('conversation-filter-unread')),
          )
          .labelStyle
          ?.fontSize;

      await pump(tester, [
        _conversation('room-a', 'Synthetic peer'),
      ], width: 390);
      expect(labelSize(), 14);

      await pump(tester, [
        _conversation('room-a', 'Synthetic peer'),
      ], width: 300);
      expect(labelSize(), 11);
    },
  );

  testWidgets('rows are separated by space, not by divider lines', (
    tester,
  ) async {
    await pump(tester, [
      _conversation('room-a', 'First'),
      _conversation('room-b', 'Second'),
    ]);

    expect(find.byType(Divider), findsNothing);
  });

  testWidgets('an empty list shows the tonal state icon', (tester) async {
    await pump(tester, const []);

    expect(find.byType(TonalStateIcon), findsOneWidget);
    expect(find.text('No conversations yet'), findsOneWidget);
  });

  testWidgets('a favourite with a status and a long name fits 200 % text in '
      'the narrowest list pane', (tester) async {
    await pump(
      tester,
      [
        _conversation(
          'room-a',
          'Quarterly planning with the regional sales leads and finance',
          favorite: true,
          status: 'away',
        ),
      ],
      textScale: 2,
      width: 240,
    );

    expect(tester.takeException(), isNull);
  });
}

CachedConversation _conversation(
  String token,
  String name, {
  bool favorite = false,
  String? status,
}) {
  return CachedConversation(
    accountId: _account.id,
    token: token,
    displayName: name,
    description: '',
    lastActivity: 1735689600,
    unreadMessages: 0,
    favorite: favorite,
    isArchived: false,
    readOnly: 0,
    roomType: 2,
    roomName: name,
    objectType: '',
    avatarVersion: '',
    isCustomAvatar: false,
    peerStatus: status,
    peerStatusIcon: status == null ? null : '*',
    lastMessageText: 'Latest message in the room',
    rawJson: '{}',
  );
}

const _account = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://example.invalid',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: true,
  createdAtMillis: 0,
);
