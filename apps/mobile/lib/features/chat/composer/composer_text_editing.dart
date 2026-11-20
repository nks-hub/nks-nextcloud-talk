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
    final fence = _backtickFence(inner, minimum: 3);
    final needsLeadingBreak = start > 0 && text[start - 1] != '\n';
    final needsTrailingBreak = end < text.length && text[end] != '\n';
    before = '${needsLeadingBreak ? '\n' : ''}$fence\n';
    after =
        '${inner.endsWith('\n') ? '' : '\n'}$fence'
        '${needsTrailingBreak ? '\n' : ''}';
  } else if (format == ComposerFormat.inlineCode) {
    before = _backtickFence(inner, minimum: 1);
    after = before;
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

String _backtickFence(String text, {required int minimum}) {
  var longest = 0;
  var current = 0;
  for (final codeUnit in text.codeUnits) {
    if (codeUnit == 0x60) {
      current++;
      if (current > longest) {
        longest = current;
      }
    } else {
      current = 0;
    }
  }
  final length = longest >= minimum ? longest + 1 : minimum;
  return '`' * length;
}

/// What the server accepts in one message.
const int composerMaximumCharacters = 32000;

/// Diverts pastes over 4,000 characters, 40 lines, or the message limit.
/// The existing draft stays in the field as the attachment's caption.
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
    if ((oldValue.composing.isValid && !oldValue.composing.isCollapsed) ||
        (newValue.composing.isValid && !newValue.composing.isCollapsed)) {
      return newValue;
    }
    final inserted = _insertedText(oldValue, newValue);
    if (inserted == null ||
        !_hasMoreThanCharacters(inserted, 1) ||
        !canDivert()) {
      return newValue;
    }
    if (!_hasMoreThanCharacters(inserted, 4000) &&
        '\n'.allMatches(inserted).take(40).length < 40 &&
        !_hasMoreThanCharacters(newValue.text, maximumCharacters)) {
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

bool _hasMoreThanCharacters(String value, int maximum) {
  var count = 0;
  for (final _ in value.characters) {
    count++;
    if (count > maximum) {
      return true;
    }
  }
  return false;
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
final RegExp _jsonObject = RegExp(r'^[\{\[]\s*(?:\{\s*)?"(?:[^"\\]|\\.)+"\s*:');
final List<({RegExp signature, PastedTextFile file})> _sourceTextFiles = [
  (
    signature: RegExp(
      r'''^(?:import[ \t]+['"](?:dart:|package:)|void[ \t]+main[ \t]*\(|(?:mixin|extension)[ \t]+[A-Za-z_]\w*[ \t]+on\b)''',
    ),
    file: (extension: 'dart', mimeType: 'text/plain'),
  ),
  (
    signature: RegExp(
      r'^(?:#!.*\bpython\d*\b|def[ \t]+[A-Za-z_]\w*[ \t]*\([^\n]*\)[ \t]*:|from[ \t]+[A-Za-z_]\w*(?:\.\w+)*[ \t]+import[ \t]+|if[ \t]+__name__[ \t]*==)',
    ),
    file: (extension: 'py', mimeType: 'text/plain'),
  ),
  (
    signature: RegExp(r'^(?:#!.*\b(?:ba|z|k)?sh\b|set[ \t]+-e(?:u|o|[ \t]|$))'),
    file: (extension: 'sh', mimeType: 'text/plain'),
  ),
  (
    signature: RegExp(
      r'^(?:import[ \t]+.+[ \t]+from[ \t]+["\x27]|export[ \t]+(?:default|const|function|class)\b|(?:const|let|var)[ \t]+[A-Za-z_$]\w*[ \t]*=|function[ \t]+[A-Za-z_$]\w*[ \t]*\()',
    ),
    file: (extension: 'js', mimeType: 'text/plain'),
  ),
  (
    signature: RegExp(
      r'^(?:SELECT\b[^;\n]*\bFROM\b|INSERT[ \t]+INTO\b|UPDATE\b[^;\n]*\bSET\b|CREATE[ \t]+TABLE\b)',
      caseSensitive: false,
    ),
    file: (extension: 'sql', mimeType: 'text/plain'),
  ),
  (
    signature: RegExp(r'^<!doctype[ \t]+html\b|^<html\b', caseSensitive: false),
    file: (extension: 'html', mimeType: 'text/plain'),
  ),
  (
    signature: RegExp(r'^<\?xml\b', caseSensitive: false),
    file: (extension: 'xml', mimeType: 'text/plain'),
  ),
];

/// Chooses a useful extension for a long pasted text.
///
/// Recognised source formats keep their extension. Otherwise a fence, heading
/// or table is enough for Markdown. Lists, links and emphasis each turn up in
/// plain logs too, so two of them are needed together before the text is `.md`.
/// Only the first 65,536 code units are inspected so a large paste stays bounded.
PastedTextFile pastedTextFile(String text) {
  final sample = text.length <= 65536 ? text : text.substring(0, 65536);
  final leading = sample.trimLeft();
  if (_jsonObject.hasMatch(leading)) {
    return (extension: 'json', mimeType: 'text/plain');
  }
  for (final source in _sourceTextFiles) {
    if (source.signature.hasMatch(leading)) {
      return source.file;
    }
  }
  final weak = [
    _markdownList,
    _markdownLink,
    _markdownEmphasis,
  ].where((pattern) => pattern.hasMatch(sample)).length;
  final markdown = _markdownStrong.hasMatch(sample) || weak >= 2;
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
