import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/conversation_avatar_repository.dart';
import 'package:nextcloudtalk/features/conversations/conversation_avatar_widget.dart';

void main() {
  testWidgets('uses initials for a server-generated direct avatar', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationAvatarProvider.overrideWith(
            (ref, key) async => ConversationAvatarImage(
              body: base64Decode(_transparentGif),
              contentType: 'image/gif',
              isCustomAvatar: false,
            ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: ConversationAvatar(
              account: _account,
              conversation: _conversation,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Image), findsNothing);
    expect(find.text('OB'), findsOneWidget);
  });
}

const _account = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '["avatar"]',
  selected: true,
  createdAtMillis: 1767225600000,
);

const _conversation = CachedConversation(
  accountId: 'account-a',
  token: 'room-a',
  displayName: 'OpenClaw Bot',
  description: '',
  lastActivity: 1724300000,
  unreadMessages: 0,
  favorite: false,
  readOnly: 0,
  roomType: 1,
  roomName: 'openclaw-bot',
  objectType: '',
  avatarVersion: '',
  isCustomAvatar: false,
  rawJson: '{}',
);

const _transparentGif = 'R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==';
