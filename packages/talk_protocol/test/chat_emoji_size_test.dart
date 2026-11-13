import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

const _uuid = '0b0c4e0a-3f5e-4c53-8a43-2f5d9b7e6a11';

void main() {
  group('ChatEmojiSizeReference', () {
    test('encodes the step in front of the uuid and parses it back', () {
      for (var step = 1; step <= ChatEmojiSizeReference.maxStep; step++) {
        final reference = ChatEmojiSizeReference(uuid: _uuid, step: step);
        expect(reference.referenceId, 'oes1.$step.$_uuid');
        final parsed = ChatEmojiSizeReference.tryParse(reference.referenceId)!;
        expect(parsed.step, step);
        expect(parsed.uuid, _uuid);
      }
    });

    test('stays inside the 64 characters Talk keeps', () {
      expect(
        ChatEmojiSizeReference(uuid: _uuid, step: 3).referenceId.length,
        lessThanOrEqualTo(64),
      );
    });

    test('rejects steps outside the range and malformed uuids', () {
      expect(
        () => ChatEmojiSizeReference(uuid: _uuid, step: 0),
        throwsArgumentError,
      );
      expect(
        () => ChatEmojiSizeReference(
          uuid: _uuid,
          step: ChatEmojiSizeReference.maxStep + 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => ChatEmojiSizeReference(uuid: 'x', step: 1),
        throwsArgumentError,
      );
    });

    test('ignores plain ids and look-alikes', () {
      expect(ChatEmojiSizeReference.tryParse(_uuid), isNull);
      expect(ChatEmojiSizeReference.tryParse('oes1.0.$_uuid'), isNull);
      expect(ChatEmojiSizeReference.tryParse('oes1.4.$_uuid'), isNull);
      expect(ChatEmojiSizeReference.tryParse('oes1.2.${_uuid}x'), isNull);
      expect(ChatEmojiSizeReference.tryParse('xoes1.2.$_uuid'), isNull);
      expect(ChatEmojiSizeReference.tryParse('owntalk-appearance-3'), isNull);
    });

    test('is a valid outbox reference id and stays unique per uuid', () {
      final first = ChatReferenceId.parse(
        ChatEmojiSizeReference(uuid: _uuid, step: 2).referenceId,
      );
      final second = ChatReferenceId.parse(
        ChatEmojiSizeReference(
          uuid: '1b0c4e0a-3f5e-4c53-8a43-2f5d9b7e6a11',
          step: 2,
        ).referenceId,
      );
      expect(first, isNot(second));
      expect(first, ChatReferenceId.parse('oes1.2.$_uuid'));
      expect(
        () => ChatReferenceId.parse('oes1.9.$_uuid'),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });
}
