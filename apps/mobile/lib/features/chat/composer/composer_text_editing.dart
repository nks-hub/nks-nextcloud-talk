import 'package:flutter/widgets.dart';

import 'mention_suggestions.dart';

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
}) {
  // Shift+Enter is the line break, on every platform that sends on Enter.
  if (shiftPressed) {
    return ComposerEnterAction.insertNewline;
  }
  // The suggestion list is open over an `@mention` token and Enter belongs to
  // it, not to sending a half-typed name.
  if (caret >= 0 && extractMentionQuery(text, caret) != null) {
    return ComposerEnterAction.insertNewline;
  }
  if (sending || (text.trim().isEmpty && !hasAttachment)) {
    return ComposerEnterAction.swallow;
  }
  return ComposerEnterAction.send;
}

bool insertComposerText(
  TextEditingController controller,
  String text, {
  ComposerInsertionMode mode = ComposerInsertionMode.inline,
  int maximumCharacters = 32000,
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
