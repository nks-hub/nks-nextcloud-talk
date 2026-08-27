import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

/// `package:markdown` produces text for an HTML document, so its text nodes
/// arrive escaped. Rendering them into plain Flutter text showed the entities
/// literally — a message with quotation marks read `&quot;like this&quot;`.
void main() {
  String render(String message, {bool markdown = true}) {
    final document = renderRichChatMessage(
      message: message,
      markdownEnabled: markdown,
      parameters: const {},
      server: ServerBase.parse('https://cloud.example.org'),
    );
    return document.nodes
        .map((node) => node.text ?? '')
        .join()
        .trim();
  }

  test('quotation marks survive markdown rendering', () {
    expect(render('Just type "/" or use "+"'), contains('"/"'));
    expect(render('Just type "/" or use "+"'), isNot(contains('&quot;')));
  });

  test('the other entities that package emits are undone too', () {
    expect(render('AT&T'), contains('AT&T'));
    expect(render("it's fine"), contains("it's"));
    for (final entity in const ['&amp;', '&#39;', '&lt;', '&gt;']) {
      expect(render('AT&T and 5 > 3 and it\'s <ok>'), isNot(contains(entity)));
    }
  });

  test('an ampersand-escaped entity is not collapsed twice', () {
    // A message that literally contains `&amp;quot;` must keep saying so
    // instead of turning into a quotation mark, which is why `&amp;` is
    // undone last.
    expect(render('literal &amp;quot; here'), contains('&quot;'));
  });

  test('markdown off leaves the text exactly as the server sent it', () {
    // Without markdown there is no escaping step, so nothing may be undone.
    expect(render('literal &quot; here', markdown: false), contains('&quot;'));
  });
}
