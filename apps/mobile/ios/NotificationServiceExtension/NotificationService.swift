import Security
import UserNotifications

/// Decrypts `nc-subject` from an APNs push and replaces the placeholder
/// title/body with the real message before iOS shows the banner.
///
/// The proxy forwards ciphertext only
/// (`nks-talk-notify/app/apns.py::build_payload`) — decryption is the only
/// thing standing between "Nextcloud Talk" + nothing and an actual
/// notification. `PushEnvelopeDecryptor` (shared source with the Runner
/// target — an extension is a separate process, so it needs its own compiled
/// copy) does the actual crypto; this class only wires it to the extension
/// lifecycle and the Keychain.
final class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttemptContent: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    let content =
      (request.content.mutableCopy() as? UNMutableNotificationContent)
      ?? UNMutableNotificationContent()
    bestAttemptContent = content

    defer { contentHandler(content) }

    guard let subjectBase64 = request.content.userInfo["nc-subject"] as? String,
      let ciphertext = Data(base64Encoded: subjectBase64)
    else {
      return
    }
    let candidates = PushDeviceKeyStore.allKeys()
    guard
      let envelope = PushEnvelopeDecryptor.decodeWakeUpPayload(
        ciphertext: ciphertext,
        candidates: candidates.map(\.key)
      )
    else {
      return
    }
    let payload = envelope.payload
    if let subject = payload["subject"] as? String, !subject.isEmpty {
      content.body = subject
    }
    // ponytail: the encrypted payload only ever carries an app id ("spreed"
    // for every Talk push), never a room name — Nextcloud's push envelope is
    // deliberately minimal for privacy. A real conversation title would need
    // an authenticated API round-trip from inside the extension, which risks
    // blowing the ~30s NSE time budget; skipped until that's needed.
    //
    // Matches Android's AndroidWebPushNotifier.kt exactly (own app: the
    // display name; anything else: the raw app id) so the two platforms
    // never show different text for the same push. "NKS Talk" duplicates
    // Runner's Info.plist CFBundleDisplayName — this extension has its own
    // bundle (CFBundleDisplayName "NotificationService"), so Bundle.main
    // here can't read Runner's; update both if the app is ever renamed.
    if let app = payload["app"] as? String {
      content.title = app == "spreed" ? "NKS Talk" : app
    }

    // Chat pushes carry the room token as `id` (push-v2.md:
    // {"app":"spreed","type":"chat","id":"<room token>", ...}). Stash it so
    // a tap can route straight there — see PushNotificationRouteStore for
    // why this can't just be added to content.userInfo.
    if payload["app"] as? String == "spreed", payload["type"] as? String == "chat",
      let roomToken = payload["id"] as? String, !roomToken.isEmpty,
      let accountId = candidates[envelope.matchedKeyIndex].accountId
    {
      PushNotificationRouteStore.remember(
        identifier: request.identifier,
        route: PushNotificationRouteStore.Route(accountId: accountId, roomToken: roomToken)
      )
      // Matches AppDelegate's registered category — without this the banner
      // offers no Reply/Mark-as-read actions at all.
      content.categoryIdentifier = "TALK_MESSAGE"
    }
  }

  override func serviceExtensionTimeWillExpire() {
    if let contentHandler, let bestAttemptContent {
      contentHandler(bestAttemptContent)
    }
  }
}
