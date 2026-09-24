import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum ComposerInsertionMode { inline, separatedToken }

/// What a bare Enter pressed in the composer should do.
enum ComposerEnterAction {
  /// Send what is in the composer.
  send,

  /// Leave the key to the field, which inserts a line break.
  insertNewline,

  /// Swallow the key without sending: there is nothing to send, or a send is
  /// already in flight, and either way a stray blank line would be wrong.
  swallow,
}

/// Decides what Enter does, given the composer's state.
///
/// Pure so the rule can be asserted directly instead of through a chat pane
/// that needs a database, an account and a live room before a key can be
/// pressed.
ComposerEnterAction composerEnterAction({
  required String text,
  required int caret,
  required bool shiftPressed,
  required bool sending,

  /// An attachment waiting in the composer. It is a message on its own, with
  /// the text as its caption, so Enter sends it even with the field empty —
  /// reported on 5 September 2026, when only the Send button did.
  bool hasAttachment = false,

  /// The range the input method is still composing, if any. On Windows and
  /// macOS a Chinese or Japanese IME uses Enter to accept the candidate it is
  /// showing; the key never reaches the field's own handler, so without this
  /// the half-typed candidate was sent as a message instead of accepted.
  TextRange composing = TextRange.empty,
}) {
  // Shift+Enter is the line break, on every platform that sends on Enter.
  if (shiftPressed) {
    return ComposerEnterAction.insertNewline;
  }
  if (composing.isValid && !composing.isCollapsed) {
    return ComposerEnterAction.insertNewline;
  }
  // A caret inside an `@mention` token used to hand Enter to the suggestion
  // list. The list has no keyboard handling at all — it is a row of chips
  // with `onTap` — so nothing received it: on a desktop, typing "Ahoj @petr"
  // and pressing Enter inserted a blank line and sent nothing, and a mention
  // is the most ordinary way for a message to end. Enter sends; the list is
  // still there to be clicked while the message is being written.

  if (sending || (text.trim().isEmpty && !hasAttachment)) {
    return ComposerEnterAction.swallow;
  }
  return ComposerEnterAction.send;
}

/// Markdown the composer's format menu can put around the selection. Talk
/// renders all of these in its own clients.
enum ComposerFormat {
  bold('**'),
  italic('*'),
  strikethrough('~~'),
  inlineCode('`'),
  codeBlock('```');

  const ComposerFormat(this.marker);

  final String marker;
}

/// Wraps the selection of [value] in [format], or opens an empty pair at the
/// caret with the caret between the markers.
///
/// A code block is fenced on lines of its own, since a fence that shares a
/// line with other text is not a fence. The selection is kept on the wrapped
/// text, so the next format or the next keystroke acts on what was selected.
TextEditingValue formatComposerSelection(
  TextEditingValue value,
  ComposerFormat format,
) {
  final text = value.text;
  final selection = value.selection;
  final valid =
      selection.isValid && selection.start >= 0 && selection.end <= text.length;
  final start = valid ? selection.start : text.length;
  final end = valid ? selection.end : text.length;
  final inner = text.substring(start, end);

  final String before;
  final String after;
  if (format == ComposerFormat.codeBlock) {
    final needsLeadingBreak = start > 0 && text[start - 1] != '\n';
    final needsTrailingBreak = end < text.length && text[end] != '\n';
    before = '${needsLeadingBreak ? '\n' : ''}```\n';
    after =
        '${inner.endsWith('\n') ? '' : '\n'}```'
        '${needsTrailingBreak ? '\n' : ''}';
  } else {
    before = format.marker;
    after = format.marker;
  }

  return TextEditingValue(
    text: text.replaceRange(start, end, '$before$inner$after'),
    selection: TextSelection(
      baseOffset: start + before.length,
      extentOffset: start + before.length + inner.length,
    ),
  );
}

/// What the server accepts in one message.
const int composerMaximumCharacters = 32000;

/// Hands text that was pasted or inserted in one go, and would push the
/// message past what the server accepts, to [onOversized] instead of the
/// field. The field keeps what it held before.
///
/// Without it the field's own length limit cut the paste at 32,000 characters
/// without a word, and the tail of a log or a document was simply gone. Typing
/// is left to that limit: only an insertion of more than one character counts
/// as a paste. So is anything the formatter cannot take whole — when
/// [canDivert] says no file can be attached right now, or while an input
/// method is still composing, the insertion goes to the field as before.
final class OversizedPasteFormatter extends TextInputFormatter {
  OversizedPasteFormatter(
    this.onOversized, {
    required this.canDivert,
    this.maximumCharacters = composerMaximumCharacters,
  });

  final void Function(String text) onOversized;
  final bool Function() canDivert;
  final int maximumCharacters;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Code units never undercount characters, so the cheap length settles
    // every ordinary keystroke before the grapheme count is paid for.
    if (newValue.text.length <= maximumCharacters ||
        newValue.text.characters.length <= maximumCharacters ||
        (newValue.composing.isValid && !newValue.composing.isCollapsed)) {
      return newValue;
    }
    final inserted = _insertedText(oldValue, newValue);
    if (inserted == null || inserted.characters.length < 2 || !canDivert()) {
      return newValue;
    }
    onOversized(inserted);
    return oldValue;
  }

  /// What replaced the old selection, read from where the selection was and
  /// where the caret landed. Comparing the two texts from both ends instead
  /// is ambiguous when the paste begins with the character after the caret:
  /// the text handed over came out shifted by that character.
  static String? _insertedText(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final before = oldValue.selection;
    final after = newValue.selection;
    if (!before.isValid || !after.isValid || !after.isCollapsed) {
      return null;
    }
    final start = before.start;
    final end = after.end;
    final removed = before.end - before.start;
    if (start < 0 ||
        end < start ||
        end > newValue.text.length ||
        newValue.text.length - (end - start) !=
            oldValue.text.length - removed ||
        newValue.text.substring(0, start) !=
            oldValue.text.substring(0, start) ||
        newValue.text.substring(end) != oldValue.text.substring(before.end)) {
      return null;
    }
    return newValue.text.substring(start, end);
  }
}

/// The file a long paste is sent as.
typedef PastedTextFile = ({String extension, String mimeType});

final RegExp _markdownStrong = RegExp(
  r'^```|^#{1,6} \S|^\|.*\|\s*$\n^\|?\s*:?-{3,}',
  multiLine: true,
);
final RegExp _markdownList = RegExp(r'^\s*(?:[-*+]|\d+\.) \S', multiLine: true);
final RegExp _markdownLink = RegExp(r'\[[^\]\n]+\]\([^)\s]+\)');
final RegExp _markdownEmphasis = RegExp(r'\*\*[^*\n]+\*\*|`[^`\n]+`');

/// `.md` when [text] reads as Markdown, `.txt` otherwise.
///
/// A fence, a heading or a table is enough on its own. Lists, links and
/// emphasis each turn up in plain logs and prose too, so two of them are
/// needed together before the text counts as Markdown.
PastedTextFile pastedTextFile(String text) {
  final weak = [
    _markdownList,
    _markdownLink,
    _markdownEmphasis,
  ].where((pattern) => pattern.hasMatch(text)).length;
  final markdown = _markdownStrong.hasMatch(text) || weak >= 2;
  return markdown
      ? (extension: 'md', mimeType: 'text/markdown')
      : (extension: 'txt', mimeType: 'text/plain');
}

bool insertComposerText(
  TextEditingController controller,
  String text, {
  ComposerInsertionMode mode = ComposerInsertionMode.inline,
  int maximumCharacters = composerMaximumCharacters,
}) {
  if (text.isEmpty || maximumCharacters < 1) {
    return false;
  }

  final current = controller.value;
  final source = current.text;
  final selection = current.selection;
  final hasValidSelection =
      selection.start >= 0 &&
      selection.end >= selection.start &&
      selection.end <= source.length;
  final start = hasValidSelection ? selection.start : source.length;
  final end = hasValidSelection ? selection.end : source.length;
  final insertion = switch (mode) {
    ComposerInsertionMode.inline => text,
    ComposerInsertionMode.separatedToken => _separatedToken(
      source,
      start: start,
      end: end,
      token: text.trim(),
    ),
  };
  if (insertion.isEmpty) {
    return false;
  }

  final result = source.replaceRange(start, end, insertion);
  if (result.characters.length > maximumCharacters) {
    return false;
  }

  controller.value = TextEditingValue(
    text: result,
    selection: TextSelection.collapsed(offset: start + insertion.length),
    composing: TextRange.empty,
  );
  return true;
}

String _separatedToken(
  String source, {
  required int start,
  required int end,
  required String token,
}) {
  if (token.isEmpty) {
    return '';
  }
  final needsLeadingSpace =
      start > 0 && !_isWhitespace(source.substring(start - 1, start));
  final needsTrailingSpace =
      end == source.length || !_isWhitespace(source.substring(end, end + 1));
  return '${needsLeadingSpace ? ' ' : ''}$token${needsTrailingSpace ? ' ' : ''}';
}

bool _isWhitespace(String value) => RegExp(r'\s').hasMatch(value);
