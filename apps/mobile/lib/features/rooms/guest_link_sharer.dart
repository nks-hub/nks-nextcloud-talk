import 'package:share_plus/share_plus.dart';
import 'package:flutter/foundation.dart';

/// Hands a conversation's guest link to the system share sheet.
///
/// This is the seam widget tests replace, because the sheet is not reachable
/// without a platform channel.
abstract interface class GuestLinkSharer {
  /// Returns false only when the sheet could not be offered at all. A sheet
  /// the user dismisses is not a failure and needs no message.
  Future<bool> share({required Uri uri, required String subject});
}

final class PlatformGuestLinkSharer implements GuestLinkSharer {
  const PlatformGuestLinkSharer();

  @override
  Future<bool> share({required Uri uri, required String subject}) async {
    try {
      final result = await SharePlus.instance.share(
        ShareParams(uri: uri, subject: subject),
      );
      return result.status != ShareResultStatus.unavailable;
    } on Object catch (error) {
      // The caller shows a generic failure, which is right — there is nothing
      // useful to tell somebody whose share sheet refused. The reason still
      // has to reach the log, or nobody can tell a missing share target from a
      // platform channel that threw.
      debugPrint('[guest-link] sharing failed: $error');
      return false;
    }
  }
}
