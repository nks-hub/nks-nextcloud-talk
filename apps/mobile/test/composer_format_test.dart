import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/composer_text_editing.dart';

TextEditingValue _value(String text, int start, [int? end]) => TextEditingValue(
  text: text,
  selection: TextSelection(baseOffset: start, extentOffset: end ?? start),
);

void main() {
  test('inline formats wrap the selection and keep it selected', () {
    final result = formatComposerSelection(
      _value('say hello now', 4, 9),
      ComposerFormat.bold,
    );
    expect(result.text, 'say **hello** now');
    expect(result.selection, const TextSelection(baseOffset: 6, extentOffset: 11));

    expect(
      formatComposerSelection(_value('x', 0, 1), ComposerFormat.inlineCode).text,
      '`x`',
    );
    expect(
      formatComposerSelection(_value('x', 0, 1), ComposerFormat.strikethrough)
          .text,
      '~~x~~',
    );
  });

  test('an empty selection opens a pair with the caret inside', () {
    final result = formatComposerSelection(_value('a ', 2), ComposerFormat.italic);
    expect(result.text, 'a **');
    expect(result.selection, const TextSelection.collapsed(offset: 3));
  });

  test('a code block fences the selection on lines of its own', () {
    final result = formatComposerSelection(
      _value('look: final a = 1; done', 6, 18),
      ComposerFormat.codeBlock,
    );
    expect(result.text, 'look: \n```\nfinal a = 1;\n```\n done');
    expect(result.selection.textInside(result.text), 'final a = 1;');
  });

  test('a code block at an empty caret leaves the caret on the inner line', () {
    final result = formatComposerSelection(_value('', 0), ComposerFormat.codeBlock);
    expect(result.text, '```\n\n```');
    expect(result.selection, const TextSelection.collapsed(offset: 4));
  });

  test('a code block does not double a line break the selection ends with', () {
    final result = formatComposerSelection(
      _value('a\nb\n', 0, 4),
      ComposerFormat.codeBlock,
    );
    expect(result.text, '```\na\nb\n```');
  });
}
