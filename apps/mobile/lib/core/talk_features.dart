import 'dart:convert';

import '../data/app_database.dart';

/// The Talk feature names cached for [account].
///
/// A corrupt or unexpected snapshot yields an empty set rather than a guess,
/// so a caller gating a feature on it hides that feature instead of offering
/// something the server may refuse.
Set<String> talkFeaturesOf(StoredAccount account) {
  try {
    final decoded = jsonDecode(account.talkFeaturesJson);
    if (decoded is List<Object?>) {
      return {
        for (final value in decoded)
          if (value is String) value,
      };
    }
  } on FormatException {
    // Fall through to the empty set.
  }
  return const {};
}
