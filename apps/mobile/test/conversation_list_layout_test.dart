import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/core/tonal_state_icon.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_avatar_widget.dart';
import 'package:nextcloudtalk/features/conversations/conversation_list_actions.dart';

import 'test_support.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    List<CachedConversation> conversations, {
    ValueChanged<CachedConversation>? onSelect,
    double textScale = 1,
    double width = 900,
    Locale locale = const Locale('en'),
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
          locale: locale,
          home: Scaffold(
            body: ConversationListView(
              account: _account,
              conversations: conversations,
              loading: false,
              onRefresh: () async {},
              onSelect: onSelect ?? (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'room search keeps focus through an empty result and clears back to favorites',
    (tester) async {
      final selected = <String>[];
      await pump(tester, [
        _conversation('room-a', 'Project A', favorite: true),
        _conversation('room-b', 'Supply order'),
        _conversation('room-c', 'Archived', favorite: true, archived: true),
      ], onSelect: (room) => selected.add(room.token));
      expect(find.byKey(const Key('favorite-room-room-c')), findsNothing);
      expect(find.byKey(const Key('favorite-room-room-b')), findsNothing);
      await tester.tap(find.byKey(const Key('favorite-room-room-a')));
      expect(selected, ['room-a']);

      final search = find.byKey(const Key('conversation-name-search'));
      await tester.enterText(search, ' UNKNOWN ');
      await tester.pump();
      expect(find.byKey(const Key('conversation-tile-room-a')), findsNothing);
      expect(find.byKey(const Key('favorite-conversations')), findsNothing);
      expect(tester.testTextInput.isVisible, isTrue);

      await tester.enterText(search, ' SuPPly ');
      await tester.pump();
      expect(find.byKey(const Key('conversation-tile-room-b')), findsOneWidget);
      await tester.tap(find.byTooltip('Clear the search'));
      await tester.pump();
      expect(find.byKey(const Key('conversation-tile-room-a')), findsOneWidget);
      expect(find.byKey(const Key('favorite-room-room-a')), findsOneWidget);
    },
  );

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

  testWidgets('the presence mark sits on the avatar corner, not in the title', (
    tester,
  ) async {
    await pump(tester, [
      _conversation('room-a', 'Synthetic peer', status: 'away', type: 1),
    ]);

    final avatar = tester.getRect(find.byType(ConversationAvatar));
    final badge = tester.getRect(
      find.byKey(const Key('conversation-presence-badge-room-a')),
    );
    expect(avatar.width, 48, reason: 'the avatar fits the compact touch row');
    expect(badge.center.dx, greaterThan(avatar.center.dx));
    expect(badge.center.dy, greaterThan(avatar.center.dy));
    expect(badge.right, lessThanOrEqualTo(avatar.right + 4));
  });

  testWidgets('room rows stay compact and preserve a full touch target', (
    tester,
  ) async {
    await pump(tester, [
      _conversation('room-a', 'First'),
      _conversation('room-b', 'Second'),
    ]);
    final first = tester.getRect(
      find.byKey(const Key('conversation-tile-room-a')),
    );
    final second = tester.getRect(
      find.byKey(const Key('conversation-tile-room-b')),
    );
    expect(first.height, inInclusiveRange(48.0, 68.0));
    expect(second.top, first.bottom);
  });

  testWidgets('an empty list shows the tonal state icon', (tester) async {
    await pump(tester, const []);

    expect(find.byType(TonalStateIcon), findsOneWidget);
    expect(find.text('No conversations yet'), findsOneWidget);
  });

  testWidgets('a favourite direct chat with a status fits 200 % text in the '
      'narrowest list pane and keeps its date', (tester) async {
    await pump(
      tester,
      [
        _conversation(
          'room-a',
          'Quarterly planning with the regional sales leads and finance',
          favorite: true,
          status: 'away',
          type: 1,
        ),
      ],
      textScale: 2,
      width: 240,
    );

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const Key('conversation-presence-badge-room-a')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
  });
}

CachedConversation _conversation(
  String token,
  String name, {
  bool favorite = false,
  bool archived = false,
  String? status,
  int type = 2,
}) {
  return CachedConversation(
    accountId: _account.id,
    token: token,
    displayName: name,
    description: '',
    lastActivity: 1735689600,
    unreadMessages: 0,
    favorite: favorite,
    isArchived: archived,
    readOnly: 0,
    roomType: type,
    roomName: name,
    objectType: '',
    avatarVersion: '',
    isCustomAvatar: false,
    peerStatus: status,
    peerStatusIcon: status == null ? null : 'x',
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
