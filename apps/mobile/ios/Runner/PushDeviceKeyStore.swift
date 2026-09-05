import Foundation
import Security

/// Generates and stores per-account RSA-2048 push keys in the iOS Keychain
/// for Nextcloud push v2 registration.
///
/// The private key is created non-extractable and never leaves the
/// Keychain; only `ensureKey`'s PEM return value crosses into Dart. The
/// Notification Service Extension looks the same Keychain item up by its
/// application tag to decrypt an incoming push — it never needs the key
/// handed to it.
final class PushDeviceKeyStore {
  private static let keyType = kSecAttrKeyTypeRSA
  private static let keySizeInBits = 2048
  private static let tagPrefix = "com.nkshub.nextcloudtalk.pushkey."

  /// Shared with the Notification Service Extension via the
  /// `keychain-access-groups` entitlement on both targets — the extension has
  /// no other way to reach a key it did not create. The team prefix comes from
  /// Info.plist (`AppIdentifierPrefix`, which Xcode fills from the signing
  /// team), so the team id itself is not in the source.
  static let sharedAccessGroup: String = {
    let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? ""
    return prefix + "com.nkshub.nextcloudtalk"
  }()

  private func applicationTag(for handle: String) -> Data {
    (Self.tagPrefix + handle).data(using: .utf8)!
  }

  /// Returns the SubjectPublicKeyInfo PEM for `handle`, generating the
  /// Keychain-resident keypair on first use and reusing it afterwards.
  func ensureKey(handle: String) throws -> String {
    let tag = applicationTag(for: handle)
    if let existing = copyPublicKey(tag: tag) {
      return try pem(from: existing)
    }
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: Self.keyType,
      kSecAttrKeySizeInBits as String: Self.keySizeInBits,
      kSecPrivateKeyAttrs as String: [
        kSecAttrIsPermanent as String: true,
        kSecAttrApplicationTag as String: tag,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecAttrAccessGroup as String: Self.sharedAccessGroup,
      ],
      kSecUseDataProtectionKeychain as String: true,
    ]
    var error: Unmanaged<CFError>?
    guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
      throw error!.takeRetainedValue() as Error
    }
    guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
      throw PushDeviceKeyStoreError.publicKeyUnavailable
    }
    return try pem(from: publicKey)
  }

  /// Deletes the Keychain-resident keypair for `handle`, if any.
  func destroyKey(handle: String) {
    let tag = applicationTag(for: handle)
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: tag,
      kSecAttrKeyType as String: Self.keyType,
      kSecAttrAccessGroup as String: Self.sharedAccessGroup,
      kSecUseDataProtectionKeychain as String: true,
    ]
    SecItemDelete(query as CFDictionary)
  }

  /// Records `accountId` as `handle`'s Keychain label, so the Notification
  /// Service Extension — which cannot otherwise tell which signed-in account
  /// a push belongs to — learns it directly once a candidate key decrypts a
  /// push (see `allKeys()`), instead of it having to be reconstructed later
  /// from the server host, which is ambiguous when two accounts share one
  /// server. A no-op if `handle` has no key yet.
  func setAccount(handle: String, accountId: String) throws {
    let tag = applicationTag(for: handle)
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: tag,
      kSecAttrKeyType as String: Self.keyType,
      kSecAttrAccessGroup as String: Self.sharedAccessGroup,
      kSecUseDataProtectionKeychain as String: true,
    ]
    let status = SecItemUpdate(
      query as CFDictionary,
      [kSecAttrLabel as String: accountId] as CFDictionary
    )
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw PushDeviceKeyStoreError.accountUpdateFailed(status: status)
    }
  }

  /// Every private key this app has ever generated in the shared access
  /// group, with the owning account id recorded at creation time (`nil` for
  /// keys created before account tracking existed). The Notification Service
  /// Extension uses this to try each candidate against an incoming push and,
  /// once one decrypts it, to learn which account the routed room token
  /// belongs to — directly, not by guessing from the server host.
  struct Candidate {
    let key: SecKey
    let accountId: String?
  }

  static func allKeys() -> [Candidate] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrKeyType as String: keyType,
      kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
      kSecAttrAccessGroup as String: sharedAccessGroup,
      kSecUseDataProtectionKeychain as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
      kSecReturnRef as String: true,
      kSecReturnAttributes as String: true,
    ]
    var items: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
      let attributeDicts = items as? [[String: Any]]
    else {
      return []
    }
    return attributeDicts.compactMap { attributes in
      guard let key = attributes[kSecValueRef as String] else {
        return nil
      }
      // The query above asked kSecReturnRef for a kSecClassKey match, so a
      // success status guarantees this cast holds.
      return Candidate(
        key: key as! SecKey,
        accountId: attributes[kSecAttrLabel as String] as? String
      )
    }
  }

  private func copyPublicKey(tag: Data) -> SecKey? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: tag,
      kSecAttrKeyType as String: Self.keyType,
      kSecAttrAccessGroup as String: Self.sharedAccessGroup,
      kSecUseDataProtectionKeychain as String: true,
      kSecReturnRef as String: true,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let privateKey = item
    else {
      return nil
    }
    // The query above asked kSecReturnRef for a kSecClassKey match, so a
    // success status guarantees `item` is a SecKey.
    return SecKeyCopyPublicKey(privateKey as! SecKey)
  }

  /// Wraps the PKCS#1 `RSAPublicKey` DER `SecKeyCopyExternalRepresentation`
  /// returns into an X.509 SubjectPublicKeyInfo, PEM-encoded — the shape
  /// `PushRsaPublicKey.parse` on the Dart side requires. Apple's Security
  /// framework only ever exports RSA public keys as PKCS#1, so the SPKI
  /// envelope has to be built by hand.
  private func pem(from key: SecKey) throws -> String {
    var error: Unmanaged<CFError>?
    guard let pkcs1 = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
      throw error!.takeRetainedValue() as Error
    }
    // rsaEncryption (1.2.840.113549.1.1.1) + NULL parameters.
    let algorithmIdentifier: [UInt8] = [
      0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
      0x05, 0x00,
    ]
    let spki = derSequence(
      derSequence(algorithmIdentifier) + derBitString([UInt8](pkcs1))
    )
    let base64 = Data(spki).base64EncodedString()
    var lines: [String] = []
    var index = base64.startIndex
    while index < base64.endIndex {
      let end =
        base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
      lines.append(String(base64[index..<end]))
      index = end
    }
    return "-----BEGIN PUBLIC KEY-----\n" + lines.joined(separator: "\n")
      + "\n-----END PUBLIC KEY-----\n"
  }

  private func derLength(_ length: Int) -> [UInt8] {
    if length < 0x80 {
      return [UInt8(length)]
    }
    var bytes: [UInt8] = []
    var remaining = length
    while remaining > 0 {
      bytes.insert(UInt8(remaining & 0xff), at: 0)
      remaining >>= 8
    }
    return [UInt8(0x80 | bytes.count)] + bytes
  }

  private func derSequence(_ content: [UInt8]) -> [UInt8] {
    [0x30] + derLength(content.count) + content
  }

  private func derBitString(_ content: [UInt8]) -> [UInt8] {
    let body: [UInt8] = [0x00] + content
    return [0x03] + derLength(body.count) + body
  }
}

enum PushDeviceKeyStoreError: Error {
  case publicKeyUnavailable
  case accountUpdateFailed(status: OSStatus)
}
