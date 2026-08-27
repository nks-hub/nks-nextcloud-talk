import Cocoa
import FlutterMacOS
import Security
import XCTest
@testable import nextcloudtalk

class RunnerTests: XCTestCase {
  func testApplicationLifecycleDoesNotForwardOptionalDelegateSelectors() {
    let delegate = AppDelegate()

    delegate.applicationDidFinishLaunching(
      Notification(name: NSApplication.didFinishLaunchingNotification)
    )
    delegate.applicationWillTerminate(
      Notification(name: NSApplication.willTerminateNotification)
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

  func testKeychainRoundTripWorksForAdHocRunner() throws {
    let service = "com.nkshub.nextcloudtalk.tests.\(UUID().uuidString)"
    let account = UUID().uuidString
    let expected = Data("temporary-keychain-value".utf8)
    let baseQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrSynchronizable as String: false,
    ]

    defer {
      SecItemDelete(baseQuery as CFDictionary)
    }

    var addQuery = baseQuery
    addQuery[kSecValueData as String] = expected
    XCTAssertEqual(SecItemAdd(addQuery as CFDictionary, nil), errSecSuccess)

    var readQuery = baseQuery
    readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
    readQuery[kSecReturnData as String] = true
    var item: CFTypeRef?
    XCTAssertEqual(
      SecItemCopyMatching(readQuery as CFDictionary, &item),
      errSecSuccess
    )
    XCTAssertEqual(item as? Data, expected)

    XCTAssertEqual(SecItemDelete(baseQuery as CFDictionary), errSecSuccess)
  }

  func testApplePushDeliveryQueuesTheLaunchTokenAndNotifications() {
    let delivery = ApplePushDelivery()
    var emittedTokens: [String] = []
    var emittedSubjects: [String] = []

    delivery.registered(deviceToken: Data([0x00, 0x7f, 0xff]))
    delivery.received(notification: ["subject": "queued"])
    delivery.attach(
      onToken: { emittedTokens.append($0) },
      onNotification: { payload in
        if let subject = payload["subject"] as? String {
          emittedSubjects.append(subject)
        }
      }
    )

    XCTAssertEqual(delivery.takeLaunchToken(), "007fff")
    XCTAssertNil(delivery.takeLaunchToken())
    XCTAssertEqual(emittedSubjects, ["queued"])

    delivery.registered(deviceToken: Data([0x01, 0x02]))
    XCTAssertEqual(emittedTokens, ["0102"])
  }

  func testPushNotificationOpenKeepsTheDecryptingAccount() {
    let delivery = ApplePushNotificationOpenDelivery()
    var emitted: [[String: Any]] = []
    delivery.attach { emitted.append($0) }

    delivery.enqueue(accountId: "account-a", roomToken: "room-a")
    XCTAssertEqual(delivery.takeLaunchOpen()?["accountId"] as? String, "account-a")
    XCTAssertNil(delivery.takeLaunchOpen())

    delivery.enqueue(accountId: "account-b", roomToken: "room-b")
    XCTAssertEqual(emitted.count, 1)
    XCTAssertEqual(emitted.first?["accountId"] as? String, "account-b")
    XCTAssertEqual(emitted.first?["roomToken"] as? String, "room-b")
  }

  func testPushDeviceKeyRoundTripUsesTheSharedAccountLabel() throws {
    let handle = UUID().uuidString
    let accountId = UUID().uuidString
    let store = PushDeviceKeyStore()
    defer { store.destroyKey(handle: handle) }

    let first = try store.ensureKey(handle: handle)
    let second = try store.ensureKey(handle: handle)
    XCTAssertEqual(first, second)
    XCTAssertTrue(first.hasPrefix("-----BEGIN PUBLIC KEY-----"))

    try store.setAccount(handle: handle, accountId: accountId)
    XCTAssertTrue(PushDeviceKeyStore.allKeys().contains { $0.accountId == accountId })

    store.destroyKey(handle: handle)
    XCTAssertFalse(PushDeviceKeyStore.allKeys().contains { $0.accountId == accountId })
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
      kind: "reply",
      accountId: "account-a",
      roomToken: "room-a",
      replyText: "hello",
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
    XCTAssertEqual(emitted.first?["accountId"] as? String, "account-a")
    XCTAssertEqual(emitted.first?["roomToken"] as? String, "room-a")
    XCTAssertEqual(emitted.first?["replyText"] as? String, "hello")
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
