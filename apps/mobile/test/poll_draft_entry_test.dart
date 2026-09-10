import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/poll_draft_actions.dart';
import 'package:nextcloudtalk/features/chat/poll_service.dart';
import 'package:nextcloudtalk/features/conversations/conversation_header_actions.dart';

import 'poll_test_support.dart';
import 'test_support.dart';

const _room = (accountId: 'account-a', roomToken: 'roomtoken', threadId: null);

void main() {
  const account = StoredAccount(
    id: 'account-a',
    serverUrl: 'https://cloud.example.invalid',
    loginName: 'fixture-user',
    serverProductName: 'Nextcloud',
    talkFeaturesJson: '["talk-polls","talk-polls-drafts"]',
    selected: true,
    createdAtMillis: 0,
  );
  CachedConversation room(int role) => CachedConversation(
    accountId: account.id,
    token: 'roomtoken',
    displayName: 'Room',
    description: '',
    lastActivity: 0,
    unreadMessages: 0,
    favorite: false,
    isArchived: false,
    readOnly: 1,
    roomType: 2,
    roomName: 'Room',
    objectType: '',
    avatarVersion: '',
    isCustomAvatar: false,
    rawJson: jsonEncode({'token': 'roomtoken', 'participantType': role}),
  );
  test(
    'cached header hint admits only advertised moderator roles without requiring write access',
    () {
      for (final role in [1, 2, 6]) {
        expect(pollDraftEntryAvailable(account, room(role)), isTrue);
      }
      for (final role in [0, 3, 4, 5]) {
        expect(pollDraftEntryAvailable(account, room(role)), isFalse);
      }
      expect(
        pollDraftEntryAvailable(
          account.copyWith(talkFeaturesJson: '[]'),
          room(1),
        ),
        isFalse,
      );
      expect(
        pollDraftEntryAvailable(
          account,
          room(1).copyWith(accountId: 'account-b'),
        ),
        isFalse,
      );
      expect(
        pollDraftEntryAvailable(account, room(1).copyWith(rawJson: '{')),
        isFalse,
      );
      expect(
        pollDraftEntryAvailable(
          account,
          room(
            1,
          ).copyWith(rawJson: '{"token":"elsewhere","participantType":1}'),
        ),
        isFalse,
      );
    },
  );

  testWidgets(
    'a cached hint never bypasses the fresh dialog permission check',
    (tester) async {
      final sender = FakePollSender();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [pollServiceProvider.overrideWithValue(sender)],
          child: localizedTestApp(home: const Scaffold(body: _Header())),
        ),
      );
      await tester.pumpAndSettle();
      expect(sender.managementAccessCalls, 0);
      await tester.tap(find.byKey(const Key('open-poll-drafts')));
      await tester.pumpAndSettle();
      expect(sender.managementAccessCalls, 1);
      expect(find.byKey(const Key('poll-drafts-error')), findsOneWidget);
      expect(find.byKey(const Key('poll-drafts-create')), findsNothing);
    },
  );
  testWidgets('a read-only draft moderator has an independent header entry', (
    tester,
  ) async {
    final sender = FakePollSender(
      access: const PollManagementAccess(canListDrafts: true),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [pollServiceProvider.overrideWithValue(sender)],
        child: localizedTestApp(home: const Scaffold(body: _Header())),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      sender.managementAccessCalls,
      0,
      reason: 'header rendering must not open a service request',
    );
    await tester.tap(find.byKey(const Key('open-poll-drafts')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('poll-drafts-dialog')), findsOneWidget);
    expect(sender.managementAccessCalls, 1);
    expect(find.byKey(const Key('poll-drafts-create')), findsNothing);
    expect(find.text('No drafts in this conversation.'), findsOneWidget);
  });

  testWidgets('a header without draft authority exposes no entry', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [pollServiceProvider.overrideWithValue(FakePollSender())],
        child: localizedTestApp(
          home: const Scaffold(body: _Header(available: false)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open-poll-drafts')), findsNothing);
  });
}

final class _Header extends ConsumerWidget {
  const _Header({this.available = true});
  final bool available;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Row(
    children: conversationHeaderActions(
      pollDraftActions(
        context,
        ref,
        roomKey: _room,
        available: available,
        isCurrent: () => true,
      ),
      width: 500,
      titleFloor: 100,
      actionExtent: kMinInteractiveDimension,
    ),
  );
}
