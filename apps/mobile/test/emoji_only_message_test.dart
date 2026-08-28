import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/emoji_only_message.dart';

void main() {
  test('a bubble holding nothing but emoji is enlarged', () {
    expect(isEmojiOnlyMessage('👍'), isTrue);
    expect(isEmojiOnlyMessage('😀😀😀'), isTrue);
    expect(isEmojiOnlyMessage('  🎉  '), isTrue);
    expect(isEmojiOnlyMessage('🔥 🚀 ✨'), isTrue);
  });

  test('sequences held together by joiners count as one emoji', () {
    // Family and profession emoji are several code points joined by U+200D;
    // counting the parts would push them over the limit for no reason.
    expect(isEmojiOnlyMessage('👨‍👩‍👧‍👦'), isTrue);
    expect(isEmojiOnlyMessage('👩🏽‍💻'), isTrue);
    expect(isEmojiOnlyMessage('❤️'), isTrue);
  });

  test('anything mixed with text keeps its ordinary size', () {
    expect(isEmojiOnlyMessage('👍 ok'), isFalse);
    expect(isEmojiOnlyMessage('ok'), isFalse);
    expect(isEmojiOnlyMessage('Dobré ráno 🌅'), isFalse);
    expect(isEmojiOnlyMessage('5'), isFalse);
  });

  test('an empty or blank message is never enlarged', () {
    expect(isEmojiOnlyMessage(''), isFalse);
    expect(isEmojiOnlyMessage('   '), isFalse);
  });

  test('a long string of emoji stays at the ordinary size', () {
    // Nine emoji would take a screenful once blown up to 40 points.
    expect(isEmojiOnlyMessage('😀' * 8), isTrue);
    expect(isEmojiOnlyMessage('😀' * 9), isFalse);
  });
}
