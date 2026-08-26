import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_list_actions.dart';

import 'test_support.dart';

void main() {
  testWidgets('an active custom status is visible without replacing preview', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final conversation = _conversation(
      token: 'room-active',
      statusMessage: 'Coffee break',
      lastMessageText: 'Latest message stays visible',
    );

    await tester.pumpWidget(_app([conversation]));
    await tester.pump();

    expect(
      find.byKey(const Key('conversation-presence-message-room-active')),
      findsOneWidget,
    );
    expect(find.text('Coffee break'), findsOneWidget);
    expect(find.text('Latest message stays visible'), findsOneWidget);
    expect(
      tester
          .getSemantics(find.byKey(const Key('conversation-tile-room-active')))
          .value,
      contains('Coffee break'),
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('blank and expired custom statuses stay hidden', (tester) async {
    final blank = _conversation(
      token: 'room-blank',
      statusMessage: '   ',
      lastMessageText: 'Blank status preview',
    );
    final expired = _conversation(
      token: 'room-expired',
      statusMessage: 'Expired status',
      statusClearAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 1,
      lastMessageText: 'Expired status preview',
    );

    await tester.pumpWidget(_app([blank, expired]));
    await tester.pump();

    expect(
      find.byKey(const Key('conversation-presence-message-room-blank')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('conversation-presence-message-room-expired')),
      findsNothing,
    );
    expect(find.text('Expired status'), findsNothing);
    expect(find.text('Blank status preview'), findsOneWidget);
    expect(find.text('Expired status preview'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long status and preview use independent single-line overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final conversation = _conversation(
      token: 'room-long',
      displayName: 'A peer with a deliberately long display name',
      statusMessage:
          'A deliberately long custom status that cannot fit on one line',
      lastMessageText:
          'A deliberately long message preview that must remain independent',
    );

    await tester.pumpWidget(_app([conversation]));
    await tester.pump();

    final status = tester.widget<Text>(
      find.byKey(const Key('conversation-presence-message-room-long')),
    );
    final preview = tester.widget<Text>(
      find.text(
        'A deliberately long message preview that must remain independent',
      ),
    );
    expect(status.maxLines, 1);
    expect(status.overflow, TextOverflow.ellipsis);
    expect(preview.maxLines, 1);
    expect(preview.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });
}

Widget _app(List<CachedConversation> conversations) {
  return ProviderScope(
    overrides: [
      conversationAvatarProvider.overrideWith((ref, key) async => null),
    ],
    child: localizedTestApp(
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
  );
}

CachedConversation _conversation({
  required String token,
  String displayName = 'Synthetic peer',
  required String statusMessage,
  int? statusClearAt,
  required String lastMessageText,
}) {
  return CachedConversation(
    accountId: _account.id,
    token: token,
    displayName: displayName,
    description: 'Synthetic conversation',
    lastActivity: 1724300000,
    unreadMessages: 0,
    favorite: false,
    isArchived: false,
    readOnly: 0,
    roomType: 1,
    roomName: 'synthetic-room',
    objectType: '',
    avatarVersion: '',
    isCustomAvatar: false,
    peerStatus: 'away',
    peerStatusIcon: '☕',
    peerStatusMessage: statusMessage,
    peerStatusClearAt: statusClearAt,
    lastMessageText: lastMessageText,
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
