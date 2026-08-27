import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {
  func testFrameworkDeepLinkRoutingIsDisabled() {
    XCTAssertEqual(
      Bundle.main.object(forInfoDictionaryKey: "FlutterDeepLinkingEnabled") as? Bool,
      false
    )
  }

  func testColdLaunchLinkIsReturnedOnlyOnce() throws {
    let delivery = AppleDeepLinkDelivery()
    let wrapped = try XCTUnwrap(
      URL(string: "nctalk://open?uri=https%3A%2F%2Fcloud.example.test%2Fcall%2Froom-a")
    )

    XCTAssertTrue(delivery.open(wrapped))
    XCTAssertEqual(
      delivery.takeLaunchLink()?["uri"] as? String,
      "https://cloud.example.test/call/room-a"
    )
    XCTAssertNil(delivery.takeLaunchLink())
  }

  func testWarmLinkIsEmittedAfterLaunchLinkWasTaken() throws {
    let delivery = AppleDeepLinkDelivery()
    var emitted: [[String: Any]] = []
    delivery.attach { emitted.append($0) }

    XCTAssertNil(delivery.takeLaunchLink())
    XCTAssertTrue(
      delivery.open(
        try XCTUnwrap(URL(string: "https://cloud.example.test/index.php/call/room-b"))
      )
    )

    XCTAssertEqual(emitted.count, 1)
    XCTAssertEqual(
      emitted.first?["uri"] as? String,
      "https://cloud.example.test/index.php/call/room-b"
    )
  }

  func testInvalidWrapperIsRejected() throws {
    let delivery = AppleDeepLinkDelivery()

    XCTAssertFalse(
      delivery.open(
        try XCTUnwrap(URL(string: "nctalk://open?uri=http%3A%2F%2Fexample.test%2Fcall%2Froom"))
      )
    )
    XCTAssertFalse(
      delivery.open(try XCTUnwrap(URL(string: "nctalk://other?uri=invalid")))
    )
    XCTAssertNil(delivery.takeLaunchLink())
  }

  // MARK: - PushEnvelopeDecryptor

  private func makeTestKeyPair() throws -> (privateKey: SecKey, publicKey: SecKey) {
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeySizeInBits as String: 2048,
    ]
    var error: Unmanaged<CFError>?
    guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
      throw try XCTUnwrap(error?.takeRetainedValue() as Error?)
    }
    return (privateKey, try XCTUnwrap(SecKeyCopyPublicKey(privateKey)))
  }

  private func encrypt(_ plaintext: Data, with publicKey: SecKey) throws -> Data {
    var error: Unmanaged<CFError>?
    guard
      let ciphertext = SecKeyCreateEncryptedData(
        publicKey,
        .rsaEncryptionPKCS1,
        plaintext as CFData,
        &error
      )
    else {
      throw try XCTUnwrap(error?.takeRetainedValue() as Error?)
    }
    return ciphertext as Data
  }

  func testDecryptorRecoversThePayloadEncryptedForTheOnlyCandidateKey() throws {
    let (privateKey, publicKey) = try makeTestKeyPair()
    let plaintext = try XCTUnwrap(
      "{\"app\":\"spreed\",\"subject\":\"New message\"}".data(using: .utf8)
    )
    let ciphertext = try encrypt(plaintext, with: publicKey)

    let payload = PushEnvelopeDecryptor.decodeWakeUpPayload(
      ciphertext: ciphertext,
      candidates: [privateKey]
    )

    XCTAssertEqual(payload?["subject"] as? String, "New message")
  }

  func testDecryptorPicksTheOneCandidateThatActuallyDecryptsIt() throws {
    let (correctPrivateKey, correctPublicKey) = try makeTestKeyPair()
    let (wrongPrivateKey, _) = try makeTestKeyPair()
    let plaintext = try XCTUnwrap("{\"app\":\"spreed\"}".data(using: .utf8))
    let ciphertext = try encrypt(plaintext, with: correctPublicKey)

    let payload = PushEnvelopeDecryptor.decodeWakeUpPayload(
      ciphertext: ciphertext,
      candidates: [wrongPrivateKey, correctPrivateKey]
    )

    XCTAssertEqual(payload?["app"] as? String, "spreed")
  }

  func testDecryptorReturnsNilWhenNoCandidateKeyMatches() throws {
    let (_, publicKey) = try makeTestKeyPair()
    let (wrongPrivateKey, _) = try makeTestKeyPair()
    let plaintext = try XCTUnwrap("{\"app\":\"spreed\"}".data(using: .utf8))
    let ciphertext = try encrypt(plaintext, with: publicKey)

    XCTAssertNil(
      PushEnvelopeDecryptor.decodeWakeUpPayload(
        ciphertext: ciphertext,
        candidates: [wrongPrivateKey]
      )
    )
  }

  func testDecryptorRejectsCiphertextThatDecryptsToNonJson() throws {
    let (privateKey, publicKey) = try makeTestKeyPair()
    // A valid RSA/PKCS#1 v1.5 ciphertext whose plaintext just isn't JSON —
    // the padding check alone must not be treated as proof of a match.
    let ciphertext = try encrypt(try XCTUnwrap("not json".data(using: .utf8)), with: publicKey)

    XCTAssertNil(
      PushEnvelopeDecryptor.decodeWakeUpPayload(
        ciphertext: ciphertext,
        candidates: [privateKey]
      )
    )
  }
}
