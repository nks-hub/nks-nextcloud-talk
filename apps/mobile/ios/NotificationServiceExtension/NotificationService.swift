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
    guard
      let payload = PushEnvelopeDecryptor.decodeWakeUpPayload(
        ciphertext: ciphertext,
        candidates: allDevicePrivateKeys()
      )
    else {
      return
    }
    if let subject = payload["subject"] as? String, !subject.isEmpty {
      content.body = subject
    }
  }

  override func serviceExtensionTimeWillExpire() {
    if let contentHandler, let bestAttemptContent {
      contentHandler(bestAttemptContent)
    }
  }

  /// Every RSA private key this app has ever generated for push, shared via
  /// the `keychain-access-groups` entitlement both targets declare
  /// (`PushDeviceKeyStore.sharedAccessGroup`). The extension has no other way
  /// to know which of possibly several signed-in accounts a push belongs to
  /// — it tries them all and keeps whichever one actually decrypts.
  private func allDevicePrivateKeys() -> [SecKey] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
      kSecAttrAccessGroup as String: PushDeviceKeyStore.sharedAccessGroup,
      kSecMatchLimit as String: kSecMatchLimitAll,
      kSecReturnRef as String: true,
    ]
    var items: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
      let keys = items as? [SecKey]
    else {
      return []
    }
    return keys
  }
}
