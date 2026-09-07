part of 'chat_message_content_test.dart';

final _pollMessage = ChatMessage.fromJson(<String, Object?>{
  ..._message.wire,
  'id': 50,
  'referenceId': 'reference-50',
  'systemMessage': '',
  'message': '{object}',
  'messageParameters': <String, Object?>{
    'object': <String, Object?>{
      'type': 'talk-poll',
      'id': '7',
      'name': 'Lunch?',
    },
  },
});

final _detachedPollMessage = ChatMessage.fromJson(<String, Object?>{
  ..._pollMessage.wire,
  'id': 52,
  'referenceId': 'reference-52',
  'message': 'Lunch?',
});

final _invalidPollMessage = ChatMessage.fromJson(<String, Object?>{
  ..._pollMessage.wire,
  'id': 51,
  'referenceId': 'reference-51',
  'messageParameters': <String, Object?>{
    'object': <String, Object?>{
      'type': 'talk-poll',
      'id': '07',
      'name': 'Lunch?',
    },
  },
});

final class _ContentPollSender extends FakePollSender {
  final List<int> loadedPollIds = [];

  @override
  Future<bool> isAvailable(PollRoomKey key) async => true;

  @override
  Future<TalkPoll> create({
    required PollRoomKey key,
    required String question,
    required List<String> options,
    required PollResultMode resultMode,
    required int maxVotes,
  }) => throw UnimplementedError();

  @override
  Future<TalkPoll> load({required PollRoomKey key, required int pollId}) async {
    loadedPollIds.add(pollId);
    return TalkPoll.fromJson({
      'id': pollId,
      'question': 'Lunch?',
      'options': ['Pizza', 'Salad'],
      'actorType': 'users',
      'actorId': 'user-a',
      'actorDisplayName': 'User A',
      'status': 0,
      'resultMode': 0,
      'maxVotes': 1,
      'votedSelf': <int>[],
      'votes': <Object?>[],
      'numVoters': 0,
    });
  }

  @override
  Future<TalkPoll> vote({
    required PollRoomKey key,
    required TalkPoll poll,
    required List<int> optionIds,
  }) => throw UnimplementedError();
}
