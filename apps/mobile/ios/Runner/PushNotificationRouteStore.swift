import Foundation
import Security

/// Hands a decrypted notification route from the Notification Service
/// Extension to the main app without exposing it in the notification payload
/// or an App Group plist.
///
/// Each route is a bounded, this-device-only Keychain item shared through the
/// same access group as the RSA push key. The notification identifier is only
/// an opaque lookup key; the stored account id and room token remain encrypted
/// at rest and are consumed on the first tap or action.
final class PushNotificationRouteStore {
  static let production = PushNotificationRouteStore(
    service: "com.nkshub.nextcloudtalk.push-route",
    maximumEntries: 20
  )

  private let service: String
  private let maximumEntries: Int
  private let accessGroup: String?
  private let useDataProtectionKeychain: Bool
  private let lock = NSLock()

  init(
    service: String,
    maximumEntries: Int,
    accessGroup: String? = PushDeviceKeyStore.sharedAccessGroup,
    useDataProtectionKeychain: Bool = true
  ) {
    precondition(!service.isEmpty)
    precondition(maximumEntries > 0)
    self.service = service
    self.maximumEntries = maximumEntries
    self.accessGroup = accessGroup
    self.useDataProtectionKeychain = useDataProtectionKeychain
  }

  struct Route {
    let accountId: String
    let roomToken: String
    /// Nextcloud notification id (`nid` in the push), so a Reply can look up
    /// which message it answers. Absent on pushes that carry none.
    var notificationId: Int? = nil
    /// Chat message the notification shows, known up front for local
    /// notifications the app builds from its own cache (macOS).
    var messageId: Int? = nil
  }

  @discardableResult
  func remember(identifier: String, route: Route) -> Bool {
    var object: [String: Any] = ["accountId": route.accountId, "token": route.roomToken]
    if let notificationId = route.notificationId, notificationId > 0 {
      object["nid"] = notificationId
    }
    if let messageId = route.messageId, messageId > 0 {
      object["messageId"] = messageId
    }
    guard !identifier.isEmpty, !route.accountId.isEmpty, !route.roomToken.isEmpty,
      let data = try? JSONSerialization.data(withJSONObject: object)
    else {
      return false
    }

    lock.lock()
    defer { lock.unlock() }
    SecItemDelete(itemQuery(identifier: identifier) as CFDictionary)
    trimOldestEntryIfNeeded()
    var item = itemQuery(identifier: identifier)
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
  }

  func take(identifier: String) -> Route? {
    guard !identifier.isEmpty else {
      return nil
    }
    lock.lock()
    defer { lock.unlock() }
    var query = itemQuery(identifier: identifier)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    SecItemDelete(itemQuery(identifier: identifier) as CFDictionary)
    guard status == errSecSuccess, let data = item as? Data,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let accountId = object["accountId"] as? String, !accountId.isEmpty,
      let token = object["token"] as? String, !token.isEmpty
    else {
      return nil
    }
    let notificationId = object["nid"] as? Int
    let messageId = object["messageId"] as? Int
    return Route(
      accountId: accountId,
      roomToken: token,
      notificationId: (notificationId ?? 0) > 0 ? notificationId : nil,
      messageId: (messageId ?? 0) > 0 ? messageId : nil
    )
  }

  func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ]
    if let accessGroup {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    if useDataProtectionKeychain {
      query[kSecUseDataProtectionKeychain as String] = true
    }
    SecItemDelete(query as CFDictionary)
  }

  private func itemQuery(identifier: String) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: identifier,
    ]
    if let accessGroup {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    if useDataProtectionKeychain {
      query[kSecUseDataProtectionKeychain as String] = true
    }
    return query
  }

  private func trimOldestEntryIfNeeded() {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    if let accessGroup {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    if useDataProtectionKeychain {
      query[kSecUseDataProtectionKeychain as String] = true
    }
    var items: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
      let attributes = items as? [[String: Any]],
      attributes.count >= maximumEntries,
      let oldest = attributes.min(by: { left, right in
        let leftDate = left[kSecAttrCreationDate as String] as? Date ?? .distantPast
        let rightDate = right[kSecAttrCreationDate as String] as? Date ?? .distantPast
        return leftDate < rightDate
      }),
      let identifier = oldest[kSecAttrAccount as String] as? String
    else {
      return
    }
    query = itemQuery(identifier: identifier)
    SecItemDelete(query as CFDictionary)
  }
}

/// The room name the Notification Service Extension puts on a communication
/// notification, written by the app when it caches a conversation.
///
/// The encrypted push carries `app`, `subject`, `type`, `id` and `nid` and
/// nothing else - `PushWakeUpPayload` rejects any other key - so the extension
/// knows the room's token and never its name. An `INSendMessageIntent` needs a
/// name to show, so the app leaves one here for each room it knows.
///
/// Shares the file with `PushNotificationRouteStore` deliberately: the project
/// compiles this file into both the Runner and the extension already, and a
/// new file would have to be added to two targets by hand. It shares the
/// mechanism for the same reason that store gives - a bounded, this-device-only
/// Keychain item in the access group both processes hold, so a room name is
/// encrypted at rest rather than sitting in an App Group plist.
final class ConversationIdentityStore {
  static let production = ConversationIdentityStore(
    service: "com.nkshub.nextcloudtalk.room-identity",
    maximumEntries: 200
  )

  private let service: String
  private let maximumEntries: Int
  private let accessGroup: String?
  private let useDataProtectionKeychain: Bool
  private let lock = NSLock()

  init(
    service: String,
    maximumEntries: Int,
    accessGroup: String? = PushDeviceKeyStore.sharedAccessGroup,
    useDataProtectionKeychain: Bool = true
  ) {
    precondition(!service.isEmpty)
    precondition(maximumEntries > 0)
    self.service = service
    self.maximumEntries = maximumEntries
    self.accessGroup = accessGroup
    self.useDataProtectionKeychain = useDataProtectionKeychain
  }

  /// One room, addressed the way the extension can address it: by the account
  /// the push key belongs to and the token the push carries.
  static func identifier(accountId: String, roomToken: String) -> String {
    "\(accountId)|\(roomToken)"
  }

  @discardableResult
  func remember(accountId: String, roomToken: String, displayName: String) -> Bool {
    let name = String(displayName.prefix(128))
    guard !accountId.isEmpty, !roomToken.isEmpty, !name.isEmpty,
      let data = try? JSONSerialization.data(withJSONObject: ["name": name])
    else {
      return false
    }
    let identifier = Self.identifier(accountId: accountId, roomToken: roomToken)
    lock.lock()
    defer { lock.unlock() }
    SecItemDelete(itemQuery(identifier: identifier) as CFDictionary)
    trimOldestEntryIfNeeded()
    var item = itemQuery(identifier: identifier)
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
  }

  /// Reads without consuming: a room keeps its name across notifications.
  func displayName(accountId: String, roomToken: String) -> String? {
    guard !accountId.isEmpty, !roomToken.isEmpty else {
      return nil
    }
    let identifier = Self.identifier(accountId: accountId, roomToken: roomToken)
    lock.lock()
    defer { lock.unlock() }
    var query = itemQuery(identifier: identifier)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let name = object["name"] as? String, !name.isEmpty
    else {
      return nil
    }
    return name
  }

  func forget(accountId: String, roomToken: String) {
    let identifier = Self.identifier(accountId: accountId, roomToken: roomToken)
    lock.lock()
    defer { lock.unlock() }
    SecItemDelete(itemQuery(identifier: identifier) as CFDictionary)
  }

  func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ]
    if let accessGroup {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    if useDataProtectionKeychain {
      query[kSecUseDataProtectionKeychain as String] = true
    }
    SecItemDelete(query as CFDictionary)
  }

  private func itemQuery(identifier: String) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: identifier,
    ]
    if let accessGroup {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    if useDataProtectionKeychain {
      query[kSecUseDataProtectionKeychain as String] = true
    }
    return query
  }

  private func trimOldestEntryIfNeeded() {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    if let accessGroup {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    if useDataProtectionKeychain {
      query[kSecUseDataProtectionKeychain as String] = true
    }
    var items: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
      let attributes = items as? [[String: Any]],
      attributes.count >= maximumEntries,
      let oldest = attributes.min(by: { left, right in
        let leftDate = left[kSecAttrCreationDate as String] as? Date ?? .distantPast
        let rightDate = right[kSecAttrCreationDate as String] as? Date ?? .distantPast
        return leftDate < rightDate
      }),
      let identifier = oldest[kSecAttrAccount as String] as? String
    else {
      return
    }
    query = itemQuery(identifier: identifier)
    SecItemDelete(query as CFDictionary)
  }
}
