import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

final _server = ServerBase.parse('https://cloud.example.org');

final _parameters = <String, ChatRichObjectParameter>{
  'mention-user1': ChatRichObjectParameter.fromJson(<String, Object?>{
    'type': 'user',
    'id': 'alice',
    'name': 'Alice Example',
  }),
  'file': ChatRichObjectParameter.fromJson(<String, Object?>{
    'type': 'file',
    'id': '42',
    'name': 'report.pdf',
  }),
};

String _plain(String message, {bool markdown = true}) => renderRichChatMessage(
  message: message,
  markdownEnabled: markdown,
  parameters: _parameters,
  server: _server,
).root.plainText;

void main() {
  group('RichChatSemanticNode.plainText', () {
    test('keeps every bulleted item on its own line with a marker', () {
      expect(
        _plain(
          '- hana na chodbě dostala plastiku\n'
          '- blikaj schody\n'
          '- hlavní vypínač nezhasnul',
        ),
        '- hana na chodbě dostala plastiku\n'
        '- blikaj schody\n'
        '- hlavní vypínač nezhasnul',
      );
    });

    test('numbers an ordered list from its start', () {
      expect(_plain('3. three\n4. four'), '3. three\n4. four');
    });

    test('indents a nested list under its parent item', () {
      expect(
        _plain('- fruit\n  - apple\n  - pear\n- vegetables'),
        '- fruit\n  - apple\n  - pear\n- vegetables',
      );
    });

    test('marks task items as done or open', () {
      expect(_plain('- [x] done\n- [ ] open'), '- [x] done\n- [ ] open');
    });

    test('separates paragraphs and headings by line breaks', () {
      expect(
        _plain('# Title\n\nFirst paragraph\nsecond line\n\nNext'),
        'Title\nFirst paragraph\nsecond line\nNext',
      );
    });

    test('prefixes every quoted line', () {
      expect(_plain('> first\n>\n> second'), '> first\n> second');
      expect(_plain('> - item\n> - next'), '> - item\n> - next');
    });

    test('keeps a code block verbatim without the closing newline', () {
      expect(
        _plain('Before\n\n```\nif (a) {\n  b();\n}\n```\n\nAfter'),
        'Before\nif (a) {\n  b();\n}\nAfter',
      );
    });

    test('reads mentions and files by name, links by their label', () {
      expect(
        _plain(
          'Hi {mention-user1}, see {file} and [the docs](https://example.org/d)',
        ),
        'Hi Alice Example, see report.pdf and the docs',
      );
    });

    test('joins table cells of a row', () {
      expect(_plain('| a | b |\n|---|---|\n| 1 | 2 |'), 'a | b\n1 | 2');
    });

    test('keeps plain messages and their line breaks as they are', () {
      expect(
        _plain('one {mention-user1}\ntwo', markdown: false),
        'one Alice Example\ntwo',
      );
    });
  });

  group('resolveChatMessagePlaceholders', () {
    test('replaces known placeholders and keeps the rest of the text', () {
      expect(
        resolveChatMessagePlaceholders(
          '- {mention-user1} sent {file}\n- {unknown} stays',
          _parameters,
        ),
        '- Alice Example sent report.pdf\n- {unknown} stays',
      );
    });
  });
}
