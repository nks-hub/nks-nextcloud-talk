import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/chat/poll_draft_actions.dart';
import 'package:nextcloudtalk/features/chat/poll_service.dart';
import 'package:nextcloudtalk/features/conversations/conversation_header_actions.dart';

import 'poll_test_support.dart';
import 'test_support.dart';

const _room = (accountId: 'account-a', roomToken: 'roomtoken', threadId: null);

void main() {
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
    await tester.tap(find.byKey(const Key('open-poll-drafts')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('poll-drafts-dialog')), findsOneWidget);
    expect(find.byKey(const Key('poll-drafts-create')), findsNothing);
    expect(find.text('No drafts in this conversation.'), findsOneWidget);
  });

  testWidgets('a header without draft authority exposes no entry', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [pollServiceProvider.overrideWithValue(FakePollSender())],
        child: localizedTestApp(home: const Scaffold(body: _Header())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open-poll-drafts')), findsNothing);
  });
}

final class _Header extends ConsumerWidget {
  const _Header();
  @override
  Widget build(BuildContext context, WidgetRef ref) => Row(
    children: conversationHeaderActions(
      pollDraftActions(context, ref, roomKey: _room, isCurrent: () => true),
      width: 500,
      titleFloor: 100,
    ),
  );
}
