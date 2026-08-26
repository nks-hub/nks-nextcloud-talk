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
}
