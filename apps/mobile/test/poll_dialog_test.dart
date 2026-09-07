import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/poll_dialog.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';
import 'poll_test_support.dart';

void main() {
  testWidgets('creates a poll and submits a real selected vote', (
    tester,
  ) async {
    final sender = FakePollSender();
    await tester.pumpWidget(
      localizedTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (_) => PollComposerDialog(
                  sender: sender,
                  roomKey: const (
                    accountId: 'account-a',
                    roomToken: 'roomtoken',
                    threadId: null,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('poll-question')), 'Lunch?');
    await tester.enterText(find.byKey(const Key('poll-option-0')), 'Pizza');
    await tester.enterText(find.byKey(const Key('poll-option-1')), 'Salad');
    await tester.tap(find.byKey(const Key('poll-create-submit')));
    await tester.pumpAndSettle();

    expect(sender.createdQuestion, 'Lunch?');
    expect(find.text('Poll created'), findsOneWidget);
    await tester.tap(find.byKey(const Key('poll-vote-option-1')));
    await tester.tap(find.byKey(const Key('poll-vote-submit')));
    await tester.pumpAndSettle();

    expect(sender.votedOptions, [1]);
  });

  testWidgets('keeps ambiguous create visible and does not retry', (
    tester,
  ) async {
    final sender = FakePollSender(failCreate: true);
    await tester.pumpWidget(
      localizedTestApp(
        home: PollComposerDialog(
          sender: sender,
          roomKey: const (
            accountId: 'account-a',
            roomToken: 'roomtoken',
            threadId: 42,
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('poll-question')), 'Lunch?');
    await tester.enterText(find.byKey(const Key('poll-option-0')), 'Pizza');
    await tester.enterText(find.byKey(const Key('poll-option-1')), 'Salad');
    await tester.tap(find.byKey(const Key('poll-create-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('poll-error')), findsOneWidget);
    expect(sender.createCalls, 1);
  });

  testWidgets('viewer loads later and disables radio while voting', (
    tester,
  ) async {
    final sender = FakePollSender()..voteCompleter = Completer<TalkPoll>();
    await tester.pumpWidget(
      localizedTestApp(
        home: PollViewerDialog(
          sender: sender,
          roomKey: const (
            accountId: 'participant-b',
            roomToken: 'roomtoken',
            threadId: null,
          ),
          pollId: 7,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(sender.loadCalls, 1);

    await tester.tap(find.byKey(const Key('poll-viewer-option-1')));
    await tester.tap(find.byKey(const Key('poll-viewer-vote')));
    await tester.pump();

    final radio = tester.widget<RadioListTile<int>>(
      find.byKey(const Key('poll-viewer-option-1')),
    );
    expect(radio.enabled, isFalse);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('poll-viewer-vote')))
          .onPressed,
      isNull,
    );
    sender.voteCompleter!.complete(pollFixture(votedSelf: const [1]));
    await tester.pumpAndSettle();
  });
}
