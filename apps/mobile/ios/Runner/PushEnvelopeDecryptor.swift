import Foundation
import Security

/// Decrypts an APNs push's `nc-subject` field and validates the wake-up
/// payload it decodes to.
///
/// Nextcloud encrypts with the device's own RSA-2048 public key
/// (`PushDeviceKeyStore`), and the proxy forwards only the ciphertext — no
/// signature travels with it (see `nks-talk-notify/app/apns.py::build_payload`:
/// `{"aps": ..., "nc-subject": encrypted_subject_b64}`). A raw PKCS#1 v1.5
/// decrypt has no built-in integrity check, so a candidate key only counts as
/// a match once its plaintext also parses as a non-empty JSON object — the
/// same fail-closed, exactly-one-match rule the pure Dart router
/// (`packages/talk_protocol/lib/src/push/routing.dart`) applies for the
/// signed variant of this problem.
enum PushEnvelopeDecryptor {
  /// A payload decrypted by exactly one of the offered candidates, plus that
  /// candidate's position in `candidates` — callers that track per-key
  /// metadata (e.g. which account's server a key belongs to) use the index to
  /// look that metadata back up without this type needing to know about it.
  struct DecodedEnvelope {
    let payload: [String: Any]
    let matchedKeyIndex: Int
  }

  /// An RSA-2048 ciphertext is always exactly this many bytes — the
  /// ciphertext length equals the modulus size regardless of padding
  /// (PKCS#1 v1.5 or OAEP). `nc-subject` reaches this code straight from an
  /// APNs payload anyone who knows the device token can send, so this is
  /// checked before the first RSA call rather than trusted from the proxy's
  /// own 344-character base64 cap.
  private static let expectedCiphertextLength = 256

  /// Tries every RSA private key in `candidates` against `ciphertext`,
  /// PKCS#1 v1.5 first (Nextcloud's default), then OAEP-SHA1 (its only
  /// configurable alternative). Returns the decoded payload only if exactly
  /// one candidate produces a valid one — zero or multiple matches both
  /// count as "not routable" rather than picking one at random.
  static func decodeWakeUpPayload(
    ciphertext: Data,
    candidates: [SecKey]
  ) -> DecodedEnvelope? {
    guard ciphertext.count == expectedCiphertextLength else {
      return nil
    }
    let matches = candidates.indices.compactMap { index -> DecodedEnvelope? in
      guard
        let payload = decrypt(ciphertext: ciphertext, with: candidates[index])
          .flatMap(validWakeUpPayload)
      else {
        return nil
      }
      return DecodedEnvelope(payload: payload, matchedKeyIndex: index)
    }
    return matches.count == 1 ? matches[0] : nil
  }

  private static func decrypt(ciphertext: Data, with key: SecKey) -> Data? {
    for algorithm: SecKeyAlgorithm in [.rsaEncryptionPKCS1, .rsaEncryptionOAEPSHA1] {
      guard SecKeyIsAlgorithmSupported(key, .decrypt, algorithm) else { continue }
      if let plaintext = SecKeyCreateDecryptedData(key, algorithm, ciphertext as CFData, nil) {
        return plaintext as Data
      }
    }
    return nil
  }

  /// Nextcloud's plaintext wake-up payload is small JSON — `app`, `subject`,
  /// `type`, `id`/`nid`, or one of the `delete*` flags
  /// (`Push::encryptAndSign()` / `decodePushWakeUpPayload` on the Dart side).
  /// `app` is the one field every real payload carries (push-v2.md's own
  /// examples all include it), so requiring it — not just "parses as some
  /// non-empty JSON object" — is what actually distinguishes a genuine
  /// decrypt from PKCS#1 v1.5 padding that happened to unwrap into valid but
  /// unrelated JSON.
  private static func validWakeUpPayload(from plaintext: Data) -> [String: Any]? {
    guard plaintext.count <= 4096,
      let object = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
      let app = object["app"] as? String, !app.isEmpty
    else {
      return nil
    }
    return object
  }
}
