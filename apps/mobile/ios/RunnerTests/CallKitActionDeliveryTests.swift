import XCTest
@testable import Runner

final class CallKitActionDeliveryTests: XCTestCase {
  private let first: [String: Any] = [
    "accountId": "account-a", "roomToken": "room-a", "callId": "call-a",
  ]
  private let second: [String: Any] = [
    "accountId": "account-b", "roomToken": "room-b", "callId": "call-b",
  ]

  func testAnswerBeforeAttachmentWaitsForDartReadiness() {
    let delivery = CallKitActionDelivery()
    var emitted: [(String, [String: Any])] = []
    delivery.enqueue("callAnswered", first)
    delivery.attach { emitted.append(($0, $1)) }
    XCTAssertTrue(emitted.isEmpty)
    delivery.markReady()
    delivery.markReady()
    XCTAssertEqual(emitted.count, 1)
    XCTAssertEqual(emitted[0].0, "callAnswered")
    XCTAssertEqual(emitted[0].1["callId"] as? String, "call-a")
  }

  func testCallEndedBeforeReadinessIsNeverJoined() {
    let delivery = CallKitActionDelivery()
    var emitted: [String] = []
    delivery.attach { method, _ in emitted.append(method) }
    delivery.enqueue("callAnswered", first)
    delivery.enqueue("callEnded", first)
    delivery.markReady()
    XCTAssertTrue(emitted.isEmpty)
  }

  func testResetDropsOldAnswersAndPrecedesTheNextCall() {
    let delivery = CallKitActionDelivery()
    var emitted: [(String, [String: Any])] = []
    delivery.enqueue("callAnswered", first)
    delivery.enqueue("callEnded", [:])
    delivery.enqueue("callAnswered", second)
    delivery.attach { emitted.append(($0, $1)) }
    delivery.markReady()
    XCTAssertEqual(emitted.map { $0.0 }, ["callEnded", "callAnswered"])
    XCTAssertTrue(emitted[0].1.isEmpty)
    XCTAssertEqual(emitted[1].1["callId"] as? String, "call-b")
  }

  func testReadyDeliveryPreservesAnswerEndAndResetOrder() {
    let delivery = CallKitActionDelivery()
    var emitted: [String] = []
    delivery.attach { method, _ in emitted.append(method) }
    delivery.markReady()
    delivery.enqueue("callAnswered", first)
    delivery.enqueue("callEnded", first)
    delivery.enqueue("callEnded", [:])
    XCTAssertEqual(emitted, ["callAnswered", "callEnded", "callEnded"])
  }

  func testReattachedEngineMustConfirmReadinessAgain() {
    let delivery = CallKitActionDelivery()
    var oldEngine: [String] = []
    var newEngine: [String] = []
    delivery.attach { method, _ in oldEngine.append(method) }
    delivery.markReady()
    delivery.detach()
    delivery.enqueue("callAnswered", first)
    delivery.attach { method, _ in newEngine.append(method) }
    XCTAssertTrue(oldEngine.isEmpty)
    XCTAssertTrue(newEngine.isEmpty)
    delivery.markReady()
    XCTAssertEqual(newEngine, ["callAnswered"])
  }
}
