import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Answers, for each glyph, whether the platform can draw it. Null means the
/// platform has no answer.
typedef EmojiGlyphProbe = Future<List<bool>?> Function(List<String> glyphs);

/// Finds the emoji the system font cannot draw, so the picker can hide them
/// instead of offering a box.
final class EmojiGlyphSupport {
  EmojiGlyphSupport({required this.probe});

  static const channelName = 'com.nkshub.nextcloudtalk/emoji_glyphs';

  /// Asks the Android font; every other platform has no answer.
  static final EmojiGlyphSupport system = EmojiGlyphSupport(probe: _askSystem);

  final EmojiGlyphProbe probe;
  Future<Set<String>>? _pending;
  Set<String>? _answer;

  /// The glyphs of [glyphs] that cannot be drawn, asked once per instance.
  ///
  /// shortcut: later calls reuse the first answer whatever they pass, which is
  /// right while the picker always passes the whole catalog.
  Future<Set<String>> unsupported(List<String> glyphs) async {
    final known = _answer;
    if (known != null) {
      return known;
    }
    return _answer = await (_pending ??= _query(glyphs));
  }

  Future<Set<String>> _query(List<String> glyphs) async {
    try {
      final answers = await probe(glyphs);
      if (answers == null || answers.length != glyphs.length) {
        return const <String>{};
      }
      return <String>{
        for (var i = 0; i < glyphs.length; i++)
          if (!answers[i]) glyphs[i],
      };
    } on Object {
      return const <String>{};
    }
  }

  /// Whether [glyph] stays visible. A skin-tone variant follows its base: it is
  /// hidden when the base is, besides being hidden when it is missing itself.
  static bool isDrawable(String glyph, Set<String> unsupported) =>
      unsupported.isEmpty ||
      !(unsupported.contains(glyph) ||
          unsupported.contains(_withoutTone(glyph)));

  static String _withoutTone(String glyph) => String.fromCharCodes(
    glyph.runes.where((rune) => rune < 0x1F3FB || rune > 0x1F3FF),
  );
}

Future<List<bool>?> _askSystem(List<String> glyphs) async {
  if (kIsWeb || !Platform.isAndroid) {
    return null;
  }
  final answers = await const MethodChannel(
    EmojiGlyphSupport.channelName,
  ).invokeListMethod<bool>('hasGlyphs', glyphs);
  return answers;
}
