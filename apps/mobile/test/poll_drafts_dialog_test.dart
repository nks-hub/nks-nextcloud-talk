import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/poll_dialog.dart';
import 'package:nextcloudtalk/features/chat/poll_service.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'poll_test_support.dart';
import 'test_support.dart';

const _key = (accountId: 'account-a', roomToken: 'roomtoken', threadId: null);
const _access = PollManagementAccess(
  canListDrafts: true,
  canCreateDraft: true,
  canEditDraft: true,
  canDeleteDraft: true,
  canPublish: true,
);

void main() {
  testWidgets('a large draft stays lazy and preserves its existing vote limit', (tester) async {
    final options = List.generate(30, (index) => 'Option $index');
    final draft = pollFixture(id: 17, status: PollStatus.draft, options: options, maxVotes: 2);
    final sender = FakePollSender(access: _access)..drafts = [draft];
    await tester.pumpWidget(localizedTestApp(home: Scaffold(body: PollComposerDialog(
      sender: sender, roomKey: _key, draftToEdit: draft,
    ))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('poll-option-29')), findsNothing);
    await tester.enterText(find.byKey(const Key('poll-question')), 'Updated question');
    await tester.tap(find.byKey(const Key('poll-create-submit')));
    await tester.pumpAndSettle();
    expect(sender.editedMaxVotes, 2);
    expect(sender.editedOptions, options);
    expect(sender.editDraftCalls, 1);
  });

  testWidgets('a draft with no editable actions remains readable without an empty menu', (tester) async {
    final sender = FakePollSender(access: const PollManagementAccess(canListDrafts: true))
      ..drafts = [pollFixture(id: 17, status: PollStatus.draft)];
    await tester.pumpWidget(localizedTestApp(home: Scaffold(body: PollDraftsDialog(sender: sender, roomKey: _key))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('poll-draft-actions-17')), findsNothing);
    await tester.tap(find.byKey(const Key('poll-draft-17')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('poll-viewer-dialog')), findsOneWidget);
    expect(find.byKey(const Key('poll-viewer-vote')), findsNothing);
  });
  testWidgets(
    'draft list remains usable at double text size on a narrow phone',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sender = FakePollSender(access: _access)
        ..drafts = [
          pollFixture(
            id: 17,
            question: 'A longer question that wraps over several lines',
            status: PollStatus.draft,
          ),
        ];
      await tester.pumpWidget(
        localizedTestApp(
          textScale: 2,
          home: Scaffold(
            body: PollDraftsDialog(sender: sender, roomKey: _key),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('poll-draft-17')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  Future<void> list(WidgetTester tester, FakePollSender sender) async {
    await tester.pumpWidget(
      localizedTestApp(
        home: Scaffold(
          body: PollDraftsDialog(sender: sender, roomKey: _key),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> menu(WidgetTester tester, String action) async {
    await tester.tap(find.byKey(const Key('poll-draft-actions-17')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await tester.pumpAndSettle();
  }

  testWidgets('saving a draft does not publish a chat poll', (tester) async {
    final sender = FakePollSender(access: _access);
    await tester.pumpWidget(
      localizedTestApp(
        home: Scaffold(
          body: PollComposerDialog(sender: sender, roomKey: _key),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('poll-question')), 'Lunch?');
    await tester.enterText(find.byKey(const Key('poll-option-0')), 'Pizza');
    await tester.enterText(find.byKey(const Key('poll-option-1')), 'Salad');
    await tester.tap(find.byKey(const Key('poll-save-draft')));
    await tester.pumpAndSettle();
    expect(sender.createDraftCalls, 1);
    expect(sender.createCalls, 0);
    expect(find.text('Draft saved'), findsOneWidget);
    expect(find.byKey(const Key('poll-vote-submit')), findsNothing);
  });

  testWidgets('draft publication creates a new poll and retains the template', (
    tester,
  ) async {
    final sender = FakePollSender(access: _access)
      ..drafts = [pollFixture(id: 17, status: PollStatus.draft)];
    await list(tester, sender);
    await menu(tester, 'Publish as new poll');
    expect(sender.publishCalls, 0);
    expect(
      find.text('This creates a new poll. The draft remains available.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('poll-confirm')));
    await tester.pumpAndSettle();
    expect(sender.publishCalls, 1);
    expect(sender.drafts.single.id, 17);
    expect(
      tester.widget<PollViewerDialog>(find.byType(PollViewerDialog)).pollId,
      27,
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('poll-viewer-dialog')),
        matching: find.text('Close'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('poll-draft-17')), findsOneWidget);
  });

  testWidgets(
    'editing a server draft preserves its identity and reloads the list',
    (tester) async {
      final sender = FakePollSender(access: _access)
        ..drafts = [pollFixture(id: 17, status: PollStatus.draft)];
      await list(tester, sender);
      await menu(tester, 'Edit draft');
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('poll-question')))
            .controller!
            .text,
        'Lunch?',
      );
      await tester.enterText(find.byKey(const Key('poll-question')), 'Dinner?');
      await tester.tap(find.byKey(const Key('poll-create-submit')));
      await tester.pumpAndSettle();
      expect(sender.editDraftCalls, 1);
      expect(sender.createCalls, 0);
      expect(sender.drafts.single.id, 17);
      await tester.tap(find.byKey(const Key('poll-close')));
      await tester.pumpAndSettle();
      expect(find.text('Dinner?'), findsOneWidget);
    },
  );

  testWidgets(
    'a read-only moderator can list and delete but cannot create or publish',
    (tester) async {
      final sender = FakePollSender(
        access: const PollManagementAccess(
          canListDrafts: true,
          canDeleteDraft: true,
        ),
      )..drafts = [pollFixture(id: 17, status: PollStatus.draft)];
      await list(tester, sender);
      expect(find.byKey(const Key('poll-drafts-create')), findsNothing);
      await tester.tap(find.byKey(const Key('poll-draft-actions-17')));
      await tester.pumpAndSettle();
      expect(find.text('Edit draft'), findsNothing);
      expect(find.text('Publish as new poll'), findsNothing);
      await tester.tap(find.text('Delete draft'));
      await tester.pumpAndSettle();
      expect(sender.deleteDraftCalls, 0);
      await tester.tap(find.byKey(const Key('poll-confirm')));
      await tester.pumpAndSettle();
      expect(sender.deleteDraftCalls, 1);
      expect(find.text('No drafts in this conversation.'), findsOneWidget);
    },
  );

  testWidgets('ordinary participant draft access is visibly denied', (
    tester,
  ) async {
    await list(tester, FakePollSender());
    expect(find.byKey(const Key('poll-drafts-error')), findsOneWidget);
    expect(find.byKey(const Key('poll-drafts-create')), findsNothing);
  });
}
