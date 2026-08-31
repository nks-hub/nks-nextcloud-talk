import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Keys whose Czech text is legitimately the same as the English one: product
/// and vendor names, and loanwords Czech uses unchanged. Everything else that
/// matches word for word is an untranslated string, which is how
/// `diagnosticsAppBuild` and `diagnosticsCapabilitiesSection` shipped in
/// English on a Czech screen.
const Set<String> _sharedWithEnglish = {
  'appTitle',
  'emojiPickerTitle',
  'giphyPoweredBy',
  'locationCoordinates',
  'participantAvatarBot',
  'presenceOnline',
  'profileServerLabel',
  'profileStatusOffline',
  'profileStatusOnline',
  'roomDetailsAvatarEmojiSemantics',
  'server',
  'serverAddressHint',
};

Map<String, String> _messages(String path) {
  final decoded =
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final entry in decoded.entries)
      if (!entry.key.startsWith('@') && entry.value is String)
        entry.key: entry.value as String,
  };
}

void main() {
  final czech = _messages('lib/l10n/app_cs.arb');
  final english = _messages('lib/l10n/app_en.arb');

  test('both languages define exactly the same messages', () {
    expect(
      czech.keys.toSet().difference(english.keys.toSet()),
      isEmpty,
      reason: 'Czech has messages English is missing',
    );
    expect(
      english.keys.toSet().difference(czech.keys.toSet()),
      isEmpty,
      reason: 'English has messages Czech is missing',
    );
  });

  test('no Czech message is left in English', () {
    final untranslated =
        czech.keys
            .where((key) => !_sharedWithEnglish.contains(key))
            .where((key) => czech[key] == english[key])
            .toList()
          ..sort();

    expect(
      untranslated,
      isEmpty,
      reason:
          'these messages read identically in both languages — translate them, '
          'or add the key to _sharedWithEnglish if that is deliberate',
    );
  });

  test('every message carries a placeholder set both languages agree on', () {
    final placeholder = RegExp(r'\{(\w+)\}');
    for (final key in czech.keys) {
      final inCzech = placeholder
          .allMatches(czech[key]!)
          .map((match) => match.group(1))
          .toSet();
      final inEnglish = placeholder
          .allMatches(english[key]!)
          .map((match) => match.group(1))
          .toSet();
      expect(
        inCzech,
        inEnglish,
        reason: '$key uses different placeholders in the two languages',
      );
    }
  });
}
