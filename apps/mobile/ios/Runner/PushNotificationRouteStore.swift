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
enum PushNotificationRouteStore {
  private static let suiteName = "group.com.nkshub.nextcloudtalk"
  private static let storageKey = "pushNotificationRoutes"
  private static let maximumEntries = 20

  struct Route {
    let host: String
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
    stored[identifier] = ["host": route.host, "token": route.roomToken]
    defaults.set(stored, forKey: storageKey)
  }

  /// Returns and forgets the route recorded for `identifier`, if any.
  static func take(identifier: String) -> Route? {
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return nil
    }
    var stored = defaults.dictionary(forKey: storageKey) ?? [:]
    guard let entry = stored.removeValue(forKey: identifier) as? [String: String],
      let host = entry["host"], let token = entry["token"]
    else {
      return nil
    }
    defaults.set(stored, forKey: storageKey)
    return Route(host: host, roomToken: token)
  }
}
