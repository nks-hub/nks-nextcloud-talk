import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/composer_text_editing.dart';

TextEditingValue _at(String text, [int? caret]) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: caret ?? text.length),
);

void main() {
  group('OversizedPasteFormatter', () {
    late List<String> handed;
    late bool canDivert;
    late OversizedPasteFormatter formatter;

    setUp(() {
      handed = [];
      canDivert = true;
      formatter = OversizedPasteFormatter(
        handed.add,
        canDivert: () => canDivert,
        maximumCharacters: 20,
      );
    });

    test('a paste that would overflow the message goes out as a file', () {
      final old = _at('hi ');
      final pasted = 'x' * 30;
      final result = formatter.formatEditUpdate(old, _at('hi $pasted'));
      expect(result, old);
      expect(handed, [pasted]);
    });

    test('a paste into the middle hands over only what was inserted', () {
      final old = _at('ab', 1);
      final pasted = 'y' * 25;
      final result = formatter.formatEditUpdate(
        old,
        _at('a${pasted}b', 1 + pasted.length),
      );
      expect(result, old);
      expect(handed, [pasted]);
    });

    test('a paste that still fits stays text', () {
      final next = _at('hi there');
      expect(formatter.formatEditUpdate(_at('hi '), next), next);
      expect(handed, isEmpty);
    });

    test('a paste that begins with the character after the caret is exact', () {
      // Compared from both ends, "A|x" + "xxxx…" matched one character too
      // many and handed over a text shifted by it.
      final old = _at('Ax', 1);
      final pasted = 'x${'y' * 24}';
      formatter.formatEditUpdate(old, _at('A${pasted}x', 1 + pasted.length));
      expect(handed, [pasted]);
    });

    test('a paste over a selection hands over only the new text', () {
      final old = TextEditingValue(
        text: 'keep OLD keep',
        selection: const TextSelection(baseOffset: 5, extentOffset: 8),
      );
      final pasted = 'z' * 25;
      formatter.formatEditUpdate(
        old,
        _at('keep $pasted keep', 5 + pasted.length),
      );
      expect(handed, [pasted]);
    });

    test('nothing is diverted when no file can be attached', () {
      canDivert = false;
      final next = _at('x' * 30);
      expect(formatter.formatEditUpdate(_at(''), next), next);
      expect(handed, isEmpty);
    });

    test('an input method still composing is left alone', () {
      final next = TextEditingValue(
        text: 'x' * 30,
        selection: const TextSelection.collapsed(offset: 30),
        composing: const TextRange(start: 20, end: 30),
      );
      expect(formatter.formatEditUpdate(_at('x' * 20), next), next);
      expect(handed, isEmpty);
    });

    test('one typed character at the limit is left to the length limit', () {
      final next = _at('a' * 21);
      expect(formatter.formatEditUpdate(_at('a' * 20), next), next);
      expect(handed, isEmpty);
    });
  });

  group('pastedTextFile', () {
    test('Markdown is recognised by a fence, a heading or a table', () {
      expect(pastedTextFile('```\ncode\n```').extension, 'md');
      expect(pastedTextFile('# Title\n\nbody').extension, 'md');
      expect(pastedTextFile('| a | b |\n|---|---|\n| 1 | 2 |').extension, 'md');
    });

    test('two lighter signals together are Markdown too', () {
      expect(pastedTextFile('- one\n- two\nsee [docs](https://x.y)').extension, 'md');
    });

    test('a plain log or prose is a text file', () {
      final file = pastedTextFile('2026-09-24 12:00 INFO started\n- not a list');
      expect(file.extension, 'txt');
      expect(file.mimeType, 'text/plain');
    });

    test('a Markdown file says so in its type', () {
      expect(pastedTextFile('# a').mimeType, 'text/markdown');
    });
  });
}
