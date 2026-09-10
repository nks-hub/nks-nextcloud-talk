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

/// What the server accepts in one message.
const int composerMaximumCharacters = 32000;

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
