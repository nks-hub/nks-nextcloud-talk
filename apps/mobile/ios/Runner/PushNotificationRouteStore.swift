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
  }

  @discardableResult
  func remember(identifier: String, route: Route) -> Bool {
    guard !identifier.isEmpty, !route.accountId.isEmpty, !route.roomToken.isEmpty,
      let data = try? JSONSerialization.data(
        withJSONObject: ["accountId": route.accountId, "token": route.roomToken]
      )
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
    return Route(accountId: accountId, roomToken: token)
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
