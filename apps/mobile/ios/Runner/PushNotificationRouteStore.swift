import Foundation

/// Hands a decrypted push's routing info from the Notification Service
/// Extension to the main app when the user taps the banner.
///
/// `UNMutableNotificationContent.userInfo` cannot carry new keys — it stays
/// exactly what APNs delivered, even after the extension rewrites `title`/
/// `body` — so there is no way to smuggle the decrypted room token back
/// through the notification itself. The two processes share nothing else
/// but the Keychain (already used for the device key) and this App Group's
/// `UserDefaults` suite, which is the standard way around that limitation.
/// Entries are keyed by the notification's own `request.identifier`, which
/// both processes see unchanged.
///
/// ponytail: stored unencrypted in a plist, not the Keychain. What lives
/// here is an opaque account id and a room token — a routing hint, not a
/// credential or the message content, and it self-evicts (bounded to
/// `maximumEntries`, consumed on the first tap). Move to a Keychain access
/// group shared with the extension if that stops being an acceptable
/// exposure for a room token specifically.
enum PushNotificationRouteStore {
  private static let suiteName = "group.com.nkshub.nextcloudtalk"
  private static let storageKey = "pushNotificationRoutes"
  private static let maximumEntries = 20

  /// [accountId] is the account whose key actually decrypted the push —
  /// known for certain at decrypt time. Carrying it through here, rather
  /// than having the tap/action handler reconstruct "which account" from the
  /// server host afterwards, is what keeps this correct when two signed-in
  /// accounts share a server: a host match alone cannot tell them apart, but
  /// the decrypting key already could.
  struct Route {
    let accountId: String
    let roomToken: String
  }

  /// Records where a decrypted notification should route to, evicting the
  /// oldest entry once `maximumEntries` is exceeded — mirrors
  /// `AppleDeepLinkDelivery`'s bounded pending-link queue, for the same
  /// reason: a tap that never lands must not leak memory forever.
  static func remember(identifier: String, route: Route) {
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return
    }
    var stored = defaults.dictionary(forKey: storageKey) ?? [:]
    if stored.count >= maximumEntries, stored[identifier] == nil {
      if let oldest = stored.keys.first {
        stored.removeValue(forKey: oldest)
      }
    }
    stored[identifier] = ["accountId": route.accountId, "token": route.roomToken]
    defaults.set(stored, forKey: storageKey)
  }

  /// Returns and forgets the route recorded for `identifier`, if any.
  static func take(identifier: String) -> Route? {
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return nil
    }
    var stored = defaults.dictionary(forKey: storageKey) ?? [:]
    guard let entry = stored.removeValue(forKey: identifier) as? [String: String],
      let accountId = entry["accountId"], let token = entry["token"]
    else {
      return nil
    }
    defaults.set(stored, forKey: storageKey)
    return Route(accountId: accountId, roomToken: token)
  }
}
