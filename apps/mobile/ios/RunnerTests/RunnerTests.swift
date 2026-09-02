import Contacts
import ContactsUI
import Flutter
import Speech
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

  func testUniversalLinkBrowsingActivityUsesTheExistingDelivery() throws {
    let delivery = AppleDeepLinkDelivery()
    let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    activity.webpageURL = try XCTUnwrap(
      URL(string: "https://cloud.example.test/index.php/call/room-a")
    )

    XCTAssertTrue(delivery.open(activity))
    XCTAssertEqual(
      delivery.takeLaunchLink()?["uri"] as? String,
      "https://cloud.example.test/index.php/call/room-a"
    )
  }

  func testUniversalLinkRejectsNonBrowsingActivity() throws {
    let delivery = AppleDeepLinkDelivery()
    let activity = NSUserActivity(activityType: "com.example.test.unrelated")
    activity.webpageURL = try XCTUnwrap(
      URL(string: "https://cloud.example.test/call/room-a")
    )

    XCTAssertFalse(delivery.open(activity))
    XCTAssertNil(delivery.takeLaunchLink())
  }

  func testUniversalLinkRejectsHttpAndUserInfo() throws {
    let delivery = AppleDeepLinkDelivery()

    XCTAssertFalse(
      delivery.open(try XCTUnwrap(URL(string: "http://cloud.example.test/call/room-a")))
    )
    XCTAssertFalse(
      delivery.open(
        try XCTUnwrap(URL(string: "https://user@cloud.example.test/call/room-a"))
      )
    )
    XCTAssertNil(delivery.takeLaunchLink())
  }

  func testContactPickerCancellationCompletesWithNil() {
    let presenter = ContactPickerPresentingViewController()
    let channel = ContactPickerChannel(presentingViewController: { presenter })
    var results: [Any?] = []

    channel.handle(
      FlutterMethodCall(methodName: "pickContact", arguments: nil),
      result: { results.append($0) }
    )
    XCTAssertTrue(presenter.lastPresented is CNContactPickerViewController)

    channel.contactPickerDidCancel(CNContactPickerViewController())

    XCTAssertEqual(results.count, 1)
    XCTAssertNil(results[0])
  }

  func testContactPickerRemovesPhotoFromBoundedVCard() throws {
    let presenter = ContactPickerPresentingViewController()
    let channel = ContactPickerChannel(presentingViewController: { presenter })
    var result: Any?
    channel.handle(
      FlutterMethodCall(methodName: "pickContact", arguments: nil),
      result: { result = $0 }
    )
    let contact = CNMutableContact()
    contact.givenName = "Alice"
    contact.familyName = "Example"
    contact.phoneNumbers = [
      CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+420123456"))
    ]
    contact.imageData = Data(repeating: 0x2a, count: 1024)

    channel.contactPicker(CNContactPickerViewController(), didSelect: contact)

    let payload = try XCTUnwrap(result as? [String: Any])
    let typedData = try XCTUnwrap(payload["vcard"] as? FlutterStandardTypedData)
    let text = try XCTUnwrap(String(data: typedData.data, encoding: .utf8))
    XCTAssertTrue(text.contains("BEGIN:VCARD"))
    XCTAssertFalse(text.contains("PHOTO"))
    XCTAssertLessThanOrEqual(typedData.data.count, ContactPickerChannel.maximumVCardBytes)
  }

  func testContactPickerRejectsOversizedVCard() throws {
    let presenter = ContactPickerPresentingViewController()
    let channel = ContactPickerChannel(presentingViewController: { presenter })
    var result: Any?
    channel.handle(
      FlutterMethodCall(methodName: "pickContact", arguments: nil),
      result: { result = $0 }
    )
    let contact = CNMutableContact()
    contact.givenName = String(
      repeating: "A",
      count: ContactPickerChannel.maximumVCardBytes + 1
    )

    channel.contactPicker(CNContactPickerViewController(), didSelect: contact)

    let error = try XCTUnwrap(result as? FlutterError)
    XCTAssertEqual(error.code, "invalid_contact")
  }

  func testColdAndWarmUniversalLinksKeepArrivalOrder() throws {
    let delivery = AppleDeepLinkDelivery()
    var emitted: [String] = []
    delivery.attach { payload in
      if let uri = payload["uri"] as? String {
        emitted.append(uri)
      }
    }

    XCTAssertTrue(
      delivery.open(try XCTUnwrap(URL(string: "https://cloud.example.test/call/room-a")))
    )
    XCTAssertTrue(
      delivery.open(try XCTUnwrap(URL(string: "https://cloud.example.test/call/room-b")))
    )
    XCTAssertTrue(
      delivery.open(try XCTUnwrap(URL(string: "https://cloud.example.test/call/room-c")))
    )
    XCTAssertTrue(emitted.isEmpty)

    XCTAssertEqual(
      delivery.takeLaunchLink()?["uri"] as? String,
      "https://cloud.example.test/call/room-a"
    )
    XCTAssertEqual(
      emitted,
      [
        "https://cloud.example.test/call/room-b",
        "https://cloud.example.test/call/room-c",
      ]
    )
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

  func testVoiceTranscriberRejectsRelativeAndEscapedFiles() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).m4a")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([0x01]).write(to: outside)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let escaped = root.appendingPathComponent("escaped.m4a")
    try FileManager.default.createSymbolicLink(at: escaped, withDestinationURL: outside)
    let transcriber = VoiceMessageTranscriber(
      allowedRootURL: root,
      authorizationStatus: { .authorized },
      requestAuthorization: { _ in XCTFail("Permission was already decided") },
      startRecognition: { _, _, _ in
        XCTFail("Invalid files must not reach Speech")
        return {}
      }
    )

    for path in ["relative.m4a", escaped.path] {
      var received: Any?
      transcriber.handle(
        FlutterMethodCall(
          methodName: "transcribe",
          arguments: ["filePath": path]
        ),
        result: { received = $0 }
      )
      XCTAssertEqual((received as? FlutterError)?.code, "invalidFile")
    }
  }

  func testVoiceTranscriberPassesTheLocalURLAndLocaleToSpeech() throws {
    let fixture = try voiceTranscriptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var receivedURL: URL?
    var receivedLocale: Locale?
    var callback: VoiceMessageTranscriber.RecognitionCallback?
    let transcriber = VoiceMessageTranscriber(
      allowedRootURL: fixture.root,
      authorizationStatus: { .authorized },
      requestAuthorization: { _ in XCTFail("Permission was already decided") },
      startRecognition: { request, locale, result in
        receivedURL = request.url
        receivedLocale = locale
        callback = result
        return {}
      }
    )
    var results: [Any?] = []

    transcriber.handle(
      FlutterMethodCall(
        methodName: "transcribe",
        arguments: [
          "filePath": fixture.file.path,
          "localeIdentifier": "cs-CZ",
          "timeoutMillis": 45000,
        ]
      ),
      result: { results.append($0) }
    )

    XCTAssertEqual(receivedURL, fixture.file.resolvingSymlinksInPath())
    XCTAssertEqual(receivedLocale?.identifier, "cs-CZ")
    XCTAssertTrue(results.isEmpty)
    try XCTUnwrap(callback)("spoken words", true, nil)
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first as? String, "spoken words")
  }

  func testVoiceTranscriptionRequestKeepsUpstreamOnDevicePartialFlags() throws {
    let fixture = try voiceTranscriptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let request = VoiceMessageTranscriber.makeOnDeviceRequest(fileURL: fixture.file)

    XCTAssertEqual(request.url, fixture.file)
    XCTAssertTrue(request.requiresOnDeviceRecognition)
    XCTAssertTrue(request.shouldReportPartialResults)
  }

  func testOnDeviceRecognizerFallsBackFromALanguageWithoutAModel() throws {
    // Czech has no on-device model on any iOS release so far; the device's
    // English must take over rather than the whole feature reporting itself
    // unavailable.
    guard let english = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
          english.supportsOnDeviceRecognition
    else {
      throw XCTSkip("this host has no on-device English model")
    }
    let recognizer = VoiceMessageTranscriber.onDeviceRecognizer(
      preferring: Locale(identifier: "cs")
    )
    XCTAssertNotNil(recognizer)
    XCTAssertTrue(recognizer?.supportsOnDeviceRecognition ?? false)
    XCTAssertNotEqual(recognizer?.locale.identifier, "cs")
  }

  func testVoiceTranscriberMapsDeniedRestrictedAndUnavailable() throws {
    let fixture = try voiceTranscriptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    for (status, code) in [
      (SFSpeechRecognizerAuthorizationStatus.denied, "denied"),
      (SFSpeechRecognizerAuthorizationStatus.restricted, "restricted"),
    ] {
      let transcriber = VoiceMessageTranscriber(
        allowedRootURL: fixture.root,
        authorizationStatus: { status },
        requestAuthorization: { _ in XCTFail("Permission was already decided") }
      )
      var received: Any?
      transcriber.handle(
        FlutterMethodCall(
          methodName: "transcribe",
          arguments: ["filePath": fixture.file.path]
        ),
        result: { received = $0 }
      )
      XCTAssertEqual((received as? FlutterError)?.code, code)
    }

    let unavailable = VoiceMessageTranscriber(
      allowedRootURL: fixture.root,
      authorizationStatus: { .authorized },
      requestAuthorization: { _ in XCTFail("Permission was already decided") },
      startRecognition: { _, _, _ in
        throw VoiceMessageTranscriber.StartError.unavailable
      }
    )
    var unavailableResult: Any?
    unavailable.handle(
      FlutterMethodCall(
        methodName: "transcribe",
        arguments: ["filePath": fixture.file.path]
      ),
      result: { unavailableResult = $0 }
    )
    XCTAssertEqual((unavailableResult as? FlutterError)?.code, "unavailable")
  }

  func testVoiceTranscriberSupersedesAndIgnoresTheOldCallback() throws {
    let fixture = try voiceTranscriptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var callbacks: [VoiceMessageTranscriber.RecognitionCallback] = []
    var cancellations = 0
    let transcriber = VoiceMessageTranscriber(
      allowedRootURL: fixture.root,
      authorizationStatus: { .authorized },
      requestAuthorization: { _ in XCTFail("Permission was already decided") },
      startRecognition: { _, _, callback in
        callbacks.append(callback)
        return { cancellations += 1 }
      }
    )
    var first: [Any?] = []
    var second: [Any?] = []

    transcriber.handle(
      FlutterMethodCall(
        methodName: "transcribe",
        arguments: ["filePath": fixture.file.path]
      ),
      result: { first.append($0) }
    )
    transcriber.handle(
      FlutterMethodCall(
        methodName: "transcribe",
        arguments: ["filePath": fixture.file.path]
      ),
      result: { second.append($0) }
    )

    XCTAssertEqual((first.first as? FlutterError)?.code, "cancelled")
    XCTAssertEqual(cancellations, 1)
    callbacks[0]("stale", true, nil)
    XCTAssertTrue(second.isEmpty)
    callbacks[1]("current", true, nil)
    XCTAssertEqual(second.count, 1)
    XCTAssertEqual(second.first as? String, "current")
  }

  func testVoiceTranscriberCancelDisposeAndTimeoutCompleteOnce() throws {
    let fixture = try voiceTranscriptionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var callbacks: [VoiceMessageTranscriber.RecognitionCallback] = []
    var timeouts: [() -> Void] = []
    var cancellations = 0
    let transcriber = VoiceMessageTranscriber(
      allowedRootURL: fixture.root,
      authorizationStatus: { .authorized },
      requestAuthorization: { _ in XCTFail("Permission was already decided") },
      startRecognition: { _, _, callback in
        callbacks.append(callback)
        return { cancellations += 1 }
      },
      schedule: { _, action in
        timeouts.append(action)
        return {}
      }
    )

    var cancelled: [Any?] = []
    transcriber.handle(
      FlutterMethodCall(
        methodName: "transcribe",
        arguments: ["filePath": fixture.file.path]
      ),
      result: { cancelled.append($0) }
    )
    transcriber.handle(
      FlutterMethodCall(methodName: "cancel", arguments: nil),
      result: { _ in }
    )
    callbacks[0]("late", true, nil)
    XCTAssertEqual(cancelled.count, 1)
    XCTAssertEqual((cancelled.first as? FlutterError)?.code, "cancelled")

    var timedOut: [Any?] = []
    transcriber.handle(
      FlutterMethodCall(
        methodName: "transcribe",
        arguments: ["filePath": fixture.file.path]
      ),
      result: { timedOut.append($0) }
    )
    timeouts.last?()
    callbacks[1]("late", true, nil)
    XCTAssertEqual(timedOut.count, 1)
    XCTAssertEqual((timedOut.first as? FlutterError)?.code, "failed")

    var disposed: [Any?] = []
    transcriber.handle(
      FlutterMethodCall(
        methodName: "transcribe",
        arguments: ["filePath": fixture.file.path]
      ),
      result: { disposed.append($0) }
    )
    transcriber.handle(
      FlutterMethodCall(methodName: "dispose", arguments: nil),
      result: { _ in }
    )
    callbacks[2]("late", true, nil)
    XCTAssertEqual(disposed.count, 1)
    XCTAssertEqual((disposed.first as? FlutterError)?.code, "cancelled")
    XCTAssertEqual(cancellations, 3)

    var afterDispose: [Any?] = []
    transcriber.handle(
      FlutterMethodCall(
        methodName: "transcribe",
        arguments: ["filePath": fixture.file.path]
      ),
      result: { afterDispose.append($0) }
    )
    callbacks[3]("new wrapper generation", true, nil)
    XCTAssertEqual(afterDispose.first as? String, "new wrapper generation")
  }

  private func voiceTranscriptionFixture() throws -> (root: URL, file: URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("message.m4a")
    try Data([0x00, 0x01]).write(to: file)
    return (root, file)
  }

}

private final class ContactPickerPresentingViewController: UIViewController {
  var lastPresented: UIViewController?

  override func present(
    _ viewControllerToPresent: UIViewController,
    animated flag: Bool,
    completion: (() -> Void)? = nil
  ) {
    lastPresented = viewControllerToPresent
    completion?()
  }
}
