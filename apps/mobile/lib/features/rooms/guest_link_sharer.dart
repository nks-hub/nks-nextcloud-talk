import 'package:share_plus/share_plus.dart';

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
    } on Object {
      return false;
    }
  }
}
