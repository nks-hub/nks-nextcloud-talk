import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('ChatMessage.projectThreadTitle', () {
    test('projects a matching root without mutating its wire model', () {
      final root = ChatMessage.fromJson(_message(id: 120));

      final projected = root.projectThreadTitle(
        roomToken: _token('rooma123'),
        threadId: 120,
        threadTitle: 'Updated design',
      );

      expect(projected, isNot(same(root)));
      expect(projected.threadTitle, 'Updated design');
      expect(projected.wire['threadTitle'], 'Updated design');
      expect(root.threadTitle, 'Design');
      expect(root.wire['threadTitle'], 'Design');
      expect(
        () => projected.wire['threadTitle'] = 'mutated',
        throwsUnsupportedError,
      );
    });

    test('projects a matching reply while retaining its parent', () {
      final reply = ChatMessage.fromJson(
        _message(id: 121, parent: _message(id: 120)),
      );

      final projected = reply.projectThreadTitle(
        roomToken: _token('rooma123'),
        threadId: 120,
        threadTitle: 'Updated design',
      );

      expect(projected.threadTitle, 'Updated design');
      expect(projected.wire['threadTitle'], 'Updated design');
      expect(projected.parent, same(reply.parent));
    });

    test('fails closed when either the room or thread does not match', () {
      final message = ChatMessage.fromJson(_message(id: 120));

      final wrongRoom = message.projectThreadTitle(
        roomToken: _token('roomb123'),
        threadId: 120,
        threadTitle: 'Updated design',
      );
      final wrongThread = message.projectThreadTitle(
        roomToken: _token('rooma123'),
        threadId: 999,
        threadTitle: 'Updated design',
      );

      expect(wrongRoom, same(message));
      expect(wrongThread, same(message));
      expect(message.wire['threadTitle'], 'Design');
    });

    test('returns the existing immutable instance when already canonical', () {
      final message = ChatMessage.fromJson(_message(id: 120));

      final projected = message.projectThreadTitle(
        roomToken: _token('rooma123'),
        threadId: 120,
        threadTitle: 'Design',
      );

      expect(projected, same(message));
    });
  });
}

ConversationToken _token(String value) =>
    ConversationToken.parse(value, path: r'$.roomToken');

Map<String, Object?> _message({
  required int id,
  Map<String, Object?>? parent,
}) => <String, Object?>{
  'id': id,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'fixture-user',
  'actorDisplayName': 'Fixture User',
  'timestamp': 1787440000,
  'systemMessage': '',
  'messageType': 'comment',
  'isReplyable': true,
  'referenceId': 'message-$id',
  'message': 'Fixture message',
  'messageParameters': <String, Object?>{},
  'markdown': false,
  'reactions': <String, Object?>{},
  'reactionsSelf': <Object?>[],
  'deleted': null,
  'threadId': 120,
  'isThread': id == 120,
  'threadTitle': 'Design',
  'threadReplies': id == 120 ? 1 : 0,
  'parent': ?parent,
};
