/// Number of emoji a message may hold and still be shown enlarged. Past this
/// the bubble is a string of symbols rather than a single gesture, and blowing
/// it up would push everything around it off screen.
const int _enlargedEmojiLimit = 8;

/// Font size for a message that is nothing but emoji.
const double enlargedEmojiFontSize = 40;

/// Whether [text] is nothing but emoji, so the bubble can show it enlarged.
///
/// The check is deliberately conservative: a message mixing emoji with any
/// other character, or one that carries message parameters (a mention, a
/// file, a Giphy reference), keeps its ordinary size, because those need the
/// surrounding layout to stay predictable.
bool isEmojiOnlyMessage(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return false;
  }
  var emoji = 0;
  for (final rune in trimmed.runes) {
    if (_isWhitespace(rune) || _isEmojiModifier(rune)) {
      continue;
    }
    if (!_isEmojiBase(rune)) {
      return false;
    }
    emoji++;
    if (emoji > _enlargedEmojiLimit) {
      return false;
    }
  }
  return emoji > 0;
}

bool _isWhitespace(int rune) =>
    rune == 0x20 || rune == 0x09 || rune == 0x0A || rune == 0x0D;

/// Joiners, variation selectors and keycap marks carry no glyph of their own,
/// so they neither disqualify a message nor count towards the limit.
bool _isEmojiModifier(int rune) =>
    rune == 0x200D || // zero width joiner, holds sequences together
    rune == 0xFE0E ||
    rune == 0xFE0F || // text and emoji presentation selectors
    rune == 0x20E3 || // combining enclosing keycap
    (rune >= 0x1F3FB && rune <= 0x1F3FF); // skin tone modifiers

bool _isEmojiBase(int rune) =>
    (rune >= 0x1F000 && rune <= 0x1FAFF) ||
    (rune >= 0x2600 && rune <= 0x27BF) ||
    (rune >= 0x2B00 && rune <= 0x2BFF) ||
    (rune >= 0x2194 && rune <= 0x21AA) ||
    (rune >= 0x231A && rune <= 0x23FA) ||
    (rune >= 0x25AA && rune <= 0x25FE) ||
    rune == 0x00A9 ||
    rune == 0x00AE ||
    rune == 0x2122 ||
    rune == 0x3030 ||
    rune == 0x303D;
