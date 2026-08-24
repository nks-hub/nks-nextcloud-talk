import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/composer_text_editing.dart';

void main() {
  group('insertComposerText', () {
    test(
      'replaces the selected range and leaves the cursor after the emoji',
      () {
        final controller = TextEditingController.fromValue(
          const TextEditingValue(
            text: 'Hello world',
            selection: TextSelection(baseOffset: 6, extentOffset: 11),
            composing: TextRange(start: 0, end: 5),
          ),
        );
        addTearDown(controller.dispose);

        final inserted = insertComposerText(controller, '👋');

        expect(inserted, isTrue);
        expect(controller.text, 'Hello 👋');
        expect(controller.selection, const TextSelection.collapsed(offset: 8));
        expect(controller.value.composing, TextRange.empty);
      },
    );

    test('appends when the platform selection is outside the draft', () {
      final controller = TextEditingController(text: 'Draft')
        ..selection = const TextSelection.collapsed(offset: -1);
      addTearDown(controller.dispose);

      expect(insertComposerText(controller, '✅'), isTrue);
      expect(controller.text, 'Draft✅');
      expect(controller.selection.baseOffset, controller.text.length);
    });

    test('inserts a GIF URL as a whitespace-delimited token', () {
      final controller = TextEditingController(text: 'beforeafter')
        ..selection = const TextSelection.collapsed(offset: 6);
      addTearDown(controller.dispose);

      final inserted = insertComposerText(
        controller,
        'https://giphy.com/gifs/wave-123',
        mode: ComposerInsertionMode.separatedToken,
      );

      expect(inserted, isTrue);
      expect(controller.text, 'before https://giphy.com/gifs/wave-123 after');
      expect(controller.selection.baseOffset, 39);
    });

    test('does not mutate the draft when the character limit is exceeded', () {
      final controller = TextEditingController(text: 'abcd')
        ..selection = const TextSelection.collapsed(offset: 2);
      addTearDown(controller.dispose);
      final before = controller.value;

      final inserted = insertComposerText(
        controller,
        '👋',
        maximumCharacters: 4,
      );

      expect(inserted, isFalse);
      expect(controller.value, before);
    });

    test('counts a joined Unicode emoji as one visible character', () {
      final controller = TextEditingController(text: 'abc')
        ..selection = const TextSelection.collapsed(offset: 3);
      addTearDown(controller.dispose);

      expect(
        insertComposerText(controller, '👩‍💻', maximumCharacters: 4),
        isTrue,
      );
      expect(controller.text, 'abc👩‍💻');
    });
  });
}
