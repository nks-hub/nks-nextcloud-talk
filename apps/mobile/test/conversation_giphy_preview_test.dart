import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_shell.dart';

import 'test_support.dart';

void main() {
  testWidgets('stale cached Giphy preview never exposes its wire URL', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      localizedTestApp(
        home: ConversationWorkspace(
          account: _account,
          accounts: const [_account],
          conversations: const [_conversation],
          selectedConversationToken: null,
          loading: false,
          syncing: false,
          onRefresh: _complete,
          onSelectAccount: _ignoreAccount,
          onAddAccount: _noop,
          onOpenConversation: _ignoreConversation,
          onSelectConversation: _ignoreConversation,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('GIF'), findsOneWidget);
    expect(find.textContaining(_resourceUrl), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _complete() async {}

void _noop() {}

void _ignoreAccount(String _) {}

void _ignoreConversation(CachedConversation _) {}

const _resourceUrl = 'https://giphy.com/gifs/stale-cache-fixture';

const _account = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: true,
  createdAtMillis: 1767225600000,
);

const _conversation = CachedConversation(
  accountId: 'account-a',
  token: 'room-a',
  displayName: 'Fixture room',
  description: '',
  lastActivity: 1767225600,
  unreadMessages: 0,
  favorite: false,
  readOnly: 0,
  roomType: 2,
  roomName: 'fixture-room',
  objectType: '',
  avatarVersion: '',
  isCustomAvatar: false,
  lastMessageText: _resourceUrl,
  lastMessageTimestamp: 1767225600,
  rawJson: '{}',
);
