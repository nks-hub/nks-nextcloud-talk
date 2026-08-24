import 'package:flutter/widgets.dart';

enum ComposerInsertionMode { inline, separatedToken }

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
