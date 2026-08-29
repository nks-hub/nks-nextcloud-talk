import 'package:flutter_test/flutter_test.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  test('a caption rides along on the share, trimmed', () {
    // Measured against Nextcloud 34 before this was wired: a share carrying
    // `talkMetaData.caption` came back as a `comment` whose message IS the
    // caption, with `actor` and `file` among the parameters. Diacritics
    // survived the round trip.
    final metadata = AttachmentMetadata(
      kind: AttachmentMessageKind.file,
      caption: '  Popisek k příloze ěščřž  ',
      replyTo: null,
      threadId: null,
      silent: false,
    );
    expect(metadata.caption, 'Popisek k příloze ěščřž');
  });

  test('a blank caption is no caption', () {
    for (final blank in const <String?>[null, '', '   ', '\n\t']) {
      final metadata = AttachmentMetadata(
        kind: AttachmentMessageKind.file,
        caption: blank,
        replyTo: null,
        threadId: null,
        silent: false,
      );
      expect(
        metadata.caption,
        isNull,
        reason: 'an empty field must not send an empty message',
      );
    }
  });

  test('a caption longer than the server accepts is refused outright', () {
    expect(
      () => AttachmentMetadata(
        kind: AttachmentMessageKind.file,
        caption: 'a' * 4001,
        replyTo: null,
        threadId: null,
        silent: false,
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });
}
