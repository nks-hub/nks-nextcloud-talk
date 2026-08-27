/// Suppresses an APNs banner that arrives right after Client Push
/// (`ClientPushCoordinator`, the notify_push websocket) already woke the app
/// up and triggered a sync for the same event — otherwise the user sees two
/// notifications for one message while the app is open.
///
/// Ports the *pattern* Android's `AndroidWebPushDeduplication` uses (a
/// short-lived, bounded record of "already handled this") rather than its
/// mechanism: Android hashes the actual FCM payload because both of its
/// channels carry content. Client Push carries none — it is a bare wake-up,
/// "something changed, go sync" — so there is nothing to fingerprint and
/// match against a push's decrypted content. What both channels share is
/// *when* they fired, so this compares timing instead: a wake-up marks
/// "just synced" for [window], and any push banner considered while that
/// window is open is presumed to be for what was just synced.
///
/// ponytail: not scoped per-account — a wake-up on any account suppresses a
/// banner for any account within the window. Cross-account false suppression
/// needs two closed-together sockets on unrelated accounts to land inside
/// the same few seconds, which is rare and merely delays a banner the app
/// already reflects on screen, never drops the underlying message. Scope to
/// account id (using `PushNotificationRouteStore`'s host, resolved back to
/// an account) if that turns out not to be quiet enough in practice.
final class ForegroundPushDeduplicator {
  ForegroundPushDeduplicator({this.window = const Duration(seconds: 5)});

  final Duration window;
  DateTime? _lastWakeUp;

  void markWakeUp({DateTime? now}) {
    _lastWakeUp = now ?? DateTime.now();
  }

  bool shouldSuppress({DateTime? now}) {
    final lastWakeUp = _lastWakeUp;
    if (lastWakeUp == null) {
      return false;
    }
    final elapsed = (now ?? DateTime.now()).difference(lastWakeUp);
    return elapsed >= Duration.zero && elapsed <= window;
  }
}
