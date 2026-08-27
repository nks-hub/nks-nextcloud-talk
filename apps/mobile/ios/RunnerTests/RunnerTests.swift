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

    let envelope = PushEnvelopeDecryptor.decodeWakeUpPayload(
      ciphertext: ciphertext,
      candidates: [privateKey]
    )

    XCTAssertEqual(envelope?.payload["subject"] as? String, "New message")
    XCTAssertEqual(envelope?.matchedKeyIndex, 0)
  }

  func testDecryptorPicksTheOneCandidateThatActuallyDecryptsIt() throws {
    let (correctPrivateKey, correctPublicKey) = try makeTestKeyPair()
    let (wrongPrivateKey, _) = try makeTestKeyPair()
    let plaintext = try XCTUnwrap("{\"app\":\"spreed\"}".data(using: .utf8))
    let ciphertext = try encrypt(plaintext, with: correctPublicKey)

    let envelope = PushEnvelopeDecryptor.decodeWakeUpPayload(
      ciphertext: ciphertext,
      candidates: [wrongPrivateKey, correctPrivateKey]
    )

    XCTAssertEqual(envelope?.payload["app"] as? String, "spreed")
    XCTAssertEqual(envelope?.matchedKeyIndex, 1)
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

  func testDecryptorRejectsInputThatIsNotExactlyOneRsaBlock() throws {
    let (privateKey, _) = try makeTestKeyPair()

    // Anyone who knows the device token can send `nc-subject` — this must
    // never reach SecKeyCreateDecryptedData at all, not just fail to match.
    XCTAssertNil(
      PushEnvelopeDecryptor.decodeWakeUpPayload(
        ciphertext: Data(repeating: 0, count: 4096),
        candidates: [privateKey]
      )
    )
    XCTAssertNil(
      PushEnvelopeDecryptor.decodeWakeUpPayload(
        ciphertext: Data(),
        candidates: [privateKey]
      )
    )
  }

  func testDecryptorRejectsJsonWithoutAnAppField() throws {
    let (privateKey, publicKey) = try makeTestKeyPair()
    // Valid JSON, valid padding, but none of Nextcloud's real payloads ever
    // omit `app` — this is what actually tells a genuine decrypt apart from
    // padding that happened to unwrap into unrelated JSON.
    let plaintext = try XCTUnwrap("{\"subject\":\"New message\"}".data(using: .utf8))
    let ciphertext = try encrypt(plaintext, with: publicKey)

    XCTAssertNil(
      PushEnvelopeDecryptor.decodeWakeUpPayload(
        ciphertext: ciphertext,
        candidates: [privateKey]
      )
    )
  }

  func testColdNotificationOpenKeepsTheDecryptingAccount() {
    let delivery = ApplePushNotificationOpenDelivery()
    var emitted: [[String: Any]] = []
    delivery.attach { emitted.append($0) }

    delivery.enqueue(accountId: "account-a", roomToken: "room-a")
    XCTAssertEqual(delivery.takeLaunchOpen()?["accountId"] as? String, "account-a")
    XCTAssertNil(delivery.takeLaunchOpen())

    delivery.enqueue(accountId: "account-b", roomToken: "room-b")
    XCTAssertEqual(emitted.first?["accountId"] as? String, "account-b")
    XCTAssertEqual(emitted.first?["roomToken"] as? String, "room-b")
  }

  func testColdNotificationActionWaitsForFlutterAndCompletesOnce() {
    var timeout: (() -> Void)?
    let delivery = ApplePushNotificationActionDelivery(
      maximumPendingActions: 16,
      completionTimeout: 20,
      schedule: { _, action in
        timeout = action
        return {}
      }
    )
    var emitted: [[String: Any]] = []
    var completions = 0

    delivery.enqueue(
      kind: "markRead",
      accountId: "account-a",
      roomToken: "room-a",
      replyText: nil,
      completion: { completions += 1 }
    )
    XCTAssertTrue(emitted.isEmpty)
    XCTAssertEqual(completions, 0)

    delivery.attach { payload, completion in
      emitted.append(payload)
      completion()
      completion()
    }
    XCTAssertTrue(emitted.isEmpty)
    XCTAssertEqual(completions, 0)

    delivery.markFlutterReady()
    delivery.markFlutterReady()
    XCTAssertEqual(emitted.first?["kind"] as? String, "markRead")
    XCTAssertEqual(emitted.first?["accountId"] as? String, "account-a")
    XCTAssertEqual(emitted.count, 1)
    XCTAssertEqual(completions, 1)
    timeout?()
    XCTAssertEqual(completions, 1)
  }

  func testNotificationActionTimesOutBeforeFlutterIsReady() {
    var timeout: (() -> Void)?
    let delivery = ApplePushNotificationActionDelivery(
      maximumPendingActions: 16,
      completionTimeout: 20,
      schedule: { _, action in
        timeout = action
        return {}
      }
    )
    var emitted = 0
    var completions = 0

    delivery.enqueue(
      kind: "markRead",
      accountId: "account-a",
      roomToken: "room-a",
      replyText: nil,
      completion: { completions += 1 }
    )
    timeout?()
    delivery.attach { _, completion in
      emitted += 1
      completion()
    }
    delivery.markFlutterReady()

    XCTAssertEqual(emitted, 0)
    XCTAssertEqual(completions, 1)
  }

  func testNotificationActionTimeoutWinsOverLateAcknowledgement() throws {
    var timeout: (() -> Void)?
    var acknowledgement: (() -> Void)?
    let delivery = ApplePushNotificationActionDelivery(
      maximumPendingActions: 16,
      completionTimeout: 20,
      schedule: { _, action in
        timeout = action
        return {}
      }
    )
    var completions = 0
    delivery.attach { _, completion in acknowledgement = completion }
    delivery.markFlutterReady()

    delivery.enqueue(
      kind: "reply",
      accountId: "account-a",
      roomToken: "room-a",
      replyText: "hello",
      completion: { completions += 1 }
    )
    timeout?()
    try XCTUnwrap(acknowledgement)()

    XCTAssertEqual(completions, 1)
  }

  func testNotificationActionAcknowledgementCancelsItsTimeout() {
    var timeout: (() -> Void)?
    var cancellations = 0
    let delivery = ApplePushNotificationActionDelivery(
      maximumPendingActions: 16,
      completionTimeout: 20,
      schedule: { _, action in
        timeout = action
        return { cancellations += 1 }
      }
    )
    var completions = 0
    delivery.attach { _, completion in completion() }
    delivery.markFlutterReady()

    delivery.enqueue(
      kind: "markRead",
      accountId: "account-a",
      roomToken: "room-a",
      replyText: nil,
      completion: { completions += 1 }
    )

    XCTAssertEqual(completions, 1)
    XCTAssertEqual(cancellations, 1)
    timeout?()
    XCTAssertEqual(completions, 1)
  }

  func testNotificationActionOverflowCompletesOnlyTheOldestAction() {
    var timeouts: [() -> Void] = []
    let delivery = ApplePushNotificationActionDelivery(
      maximumPendingActions: 2,
      completionTimeout: 20,
      schedule: { _, action in
        timeouts.append(action)
        return {}
      }
    )
    var completions = [0, 0, 0]

    for index in completions.indices {
      delivery.enqueue(
        kind: "markRead",
        accountId: "account-\(index)",
        roomToken: "room-\(index)",
        replyText: nil,
        completion: { completions[index] += 1 }
      )
    }
    XCTAssertEqual(completions, [1, 0, 0])

    delivery.attach { _, completion in completion() }
    delivery.markFlutterReady()
    XCTAssertEqual(completions, [1, 1, 1])
    timeouts.forEach { $0() }
    XCTAssertEqual(completions, [1, 1, 1])
  }

  func testNotificationRouteRoundTripIsConsumedFromTheKeychain() throws {
    let store = PushNotificationRouteStore(
      service: "com.nkshub.nextcloudtalk.tests.\(UUID().uuidString)",
      maximumEntries: 20,
      accessGroup: nil,
      useDataProtectionKeychain: false
    )
    defer { store.removeAll() }
    let identifier = UUID().uuidString
    store.remember(
      identifier: identifier,
      route: PushNotificationRouteStore.Route(
        accountId: "account-a",
        roomToken: "room-a"
      )
    )

    let route = try XCTUnwrap(store.take(identifier: identifier))
    XCTAssertEqual(route.accountId, "account-a")
    XCTAssertEqual(route.roomToken, "room-a")
    XCTAssertNil(store.take(identifier: identifier))
  }

  func testNotificationRoutesSurviveConcurrentIndependentWrites() throws {
    let store = PushNotificationRouteStore(
      service: "com.nkshub.nextcloudtalk.tests.\(UUID().uuidString)",
      maximumEntries: 8,
      accessGroup: nil,
      useDataProtectionKeychain: false
    )
    defer { store.removeAll() }
    let routes = (0..<8).map { index in
      (
        identifier: UUID().uuidString,
        accountId: "account-\(index)",
        roomToken: "room-\(index)"
      )
    }

    DispatchQueue.concurrentPerform(iterations: routes.count) { index in
      let route = routes[index]
      store.remember(
        identifier: route.identifier,
        route: PushNotificationRouteStore.Route(
          accountId: route.accountId,
          roomToken: route.roomToken
        )
      )
    }

    for route in routes {
      let stored = try XCTUnwrap(
        store.take(identifier: route.identifier)
      )
      XCTAssertEqual(stored.accountId, route.accountId)
      XCTAssertEqual(stored.roomToken, route.roomToken)
      XCTAssertNil(store.take(identifier: route.identifier))
    }
  }

  func testNotificationRouteStoreRetainsAtMostTwentyEntries() {
    let store = PushNotificationRouteStore(
      service: "com.nkshub.nextcloudtalk.tests.\(UUID().uuidString)",
      maximumEntries: 20,
      accessGroup: nil,
      useDataProtectionKeychain: false
    )
    defer { store.removeAll() }
    let identifiers = (0..<25).map { _ in UUID().uuidString }
    for (index, identifier) in identifiers.enumerated() {
      store.remember(
        identifier: identifier,
        route: PushNotificationRouteStore.Route(
          accountId: "account-\(index)",
          roomToken: "room-\(index)"
        )
      )
    }

    let retained = identifiers.compactMap {
      store.take(identifier: $0)
    }
    XCTAssertEqual(retained.count, 20)
  }

  func testNotificationRouteNamespacesDoNotShareEntries() throws {
    let first = PushNotificationRouteStore(
      service: "com.nkshub.nextcloudtalk.tests.\(UUID().uuidString)",
      maximumEntries: 1,
      accessGroup: nil,
      useDataProtectionKeychain: false
    )
    let second = PushNotificationRouteStore(
      service: "com.nkshub.nextcloudtalk.tests.\(UUID().uuidString)",
      maximumEntries: 1,
      accessGroup: nil,
      useDataProtectionKeychain: false
    )
    defer {
      first.removeAll()
      second.removeAll()
    }
    let identifier = UUID().uuidString
    first.remember(
      identifier: identifier,
      route: .init(accountId: "account-a", roomToken: "room-a")
    )
    second.remember(
      identifier: identifier,
      route: .init(accountId: "account-b", roomToken: "room-b")
    )

    XCTAssertEqual(try XCTUnwrap(first.take(identifier: identifier)).accountId, "account-a")
    XCTAssertEqual(try XCTUnwrap(second.take(identifier: identifier)).accountId, "account-b")
  }

}
