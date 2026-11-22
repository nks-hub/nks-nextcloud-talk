import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_background_theme.dart';
import 'package:nextcloudtalk/features/conversations/conversation_list_actions.dart';

import 'test_support.dart';

void main() {
  for (final theme in [AppTheme.light(), AppTheme.dark()]) {
    for (final state in ['unread', 'selected']) {
      testWidgets('the preview of a $state row keeps 4.5:1 in '
          '${theme.brightness.name}', (tester) async {
        const preview = 'Latest message in the room';
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              conversationAvatarProvider.overrideWith((ref, key) async => null),
            ],
            child: localizedTestApp(
              theme: theme,
              home: Scaffold(
                body: ConversationListView(
                  account: _account,
                  conversations: [
                    _conversation(unread: state == 'unread' ? 3 : 0),
                  ],
                  loading: false,
                  onRefresh: () async {},
                  onSelect: (_) {},
                  selectedToken: state == 'selected' ? 'room-a' : null,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final text = tester.widget<Text>(find.text(preview));
        final tile = tester.widget<Material>(
          find
              .ancestor(of: find.text(preview), matching: find.byType(Material))
              .first,
        );
        final scheme = theme.colorScheme;
        // The row colour is translucent for unread rows, so it is read over
        // the surface it is drawn on.
        final background = Color.alphaBlend(tile.color!, scheme.surface);
        expect(tile.color, isNot(Colors.transparent));
        expect(
          chatBackgroundContrast(
            Color.alphaBlend(text.style!.color!, background),
            background,
          ),
          greaterThanOrEqualTo(4.5),
        );
      });
    }
  }
}

CachedConversation _conversation({required int unread}) {
  return CachedConversation(
    accountId: _account.id,
    token: 'room-a',
    displayName: 'Synthetic peer',
    description: 'Synthetic conversation',
    lastActivity: 1724300000,
    unreadMessages: unread,
    favorite: false,
    isArchived: false,
    readOnly: 0,
    roomType: 2,
    roomName: 'synthetic-room',
    objectType: '',
    avatarVersion: '',
    isCustomAvatar: false,
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
