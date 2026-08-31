import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/poll_dialog.dart';
import 'package:nextcloudtalk/features/chat/poll_service.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  testWidgets('creates a poll and submits a real selected vote', (
    tester,
  ) async {
    final sender = _FakePollSender();
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
    final sender = _FakePollSender(failCreate: true);
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
}

final class _FakePollSender implements PollSender {
  _FakePollSender({this.failCreate = false});
  final bool failCreate;
  int createCalls = 0;
  String? createdQuestion;
  List<int>? votedOptions;

  @override
  Future<bool> isAvailable(PollRoomKey key) async => true;

  @override
  Future<TalkPoll> create({
    required PollRoomKey key,
    required String question,
    required List<String> options,
    required PollResultMode resultMode,
    required int maxVotes,
  }) async {
    createCalls++;
    createdQuestion = question;
    if (failCreate) {
      throw const PollServiceException(PollServiceError.ambiguous);
    }
    return _poll(votedSelf: const []);
  }

  @override
  Future<TalkPoll> vote({
    required PollRoomKey key,
    required TalkPoll poll,
    required List<int> optionIds,
  }) async {
    votedOptions = optionIds;
    return _poll(votedSelf: optionIds);
  }

  TalkPoll _poll({required List<int> votedSelf}) => TalkPoll.fromJson({
    'id': 7,
    'question': 'Lunch?',
    'options': ['Pizza', 'Salad'],
    'actorType': 'users',
    'actorId': 'fixture-user',
    'actorDisplayName': 'Fixture User',
    'status': 0,
    'resultMode': 0,
    'maxVotes': 1,
    'votedSelf': votedSelf,
    'votes': {'option-1': votedSelf.isEmpty ? 0 : 1},
    'numVoters': votedSelf.isEmpty ? 0 : 1,
  });
}
