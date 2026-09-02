import CryptoKit
import XCTest

@testable import Runner

final class AppleIncomingShareInboxTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testTextShareIsDurableDeduplicatedAndCompletable() throws {
    let id = "00000000-0000-4000-8000-000000000001"
    let inbox = try AppleIncomingShareInbox(
      rootDirectory: root,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      makeID: { id }
    )

    let firstCapture = try inbox.capture(
      text: "  Hello  ",
      fileURL: nil,
      mimeType: nil,
      displayName: nil
    )
    let duplicateCapture = try inbox.capture(
      text: "Hello",
      fileURL: nil,
      mimeType: nil,
      displayName: nil
    )

    let first = firstCapture.share
    XCTAssertTrue(firstCapture.inserted)
    XCTAssertFalse(duplicateCapture.inserted)
    XCTAssertEqual(first.id, id)
    XCTAssertEqual(first.text, "Hello")
    XCTAssertEqual(duplicateCapture.share.id, id)
    XCTAssertEqual(try AppleIncomingShareInbox(rootDirectory: root).pending(), [first])
    XCTAssertTrue(inbox.complete(id: id))
    XCTAssertTrue(inbox.pending().isEmpty)
  }

  func testFileIsCopiedAndVerifiedBeforeTheSourceCanDisappear() throws {
    let source = root.appendingPathComponent("source.txt")
    let bytes = Data("durable share".utf8)
    try bytes.write(to: source)
    let id = "00000000-0000-4000-8000-000000000002"
    let inbox = try AppleIncomingShareInbox(
      rootDirectory: root,
      makeID: { id }
    )

    let share = try inbox.capture(
      text: "caption",
      fileURL: source,
      mimeType: "text/plain",
      displayName: "../note.txt"
    )
    try FileManager.default.removeItem(at: source)

    XCTAssertTrue(share.inserted)
    XCTAssertEqual(share.share.byteLength, Int64(bytes.count))
    XCTAssertEqual(
      share.share.sha256,
      SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    )
    XCTAssertEqual(share.share.displayName, "..note.txt")
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: share.share.filePath!)), bytes)
    XCTAssertEqual(try AppleIncomingShareInbox(rootDirectory: root).pending(), [share.share])
  }

  func testMetadataCannotRedirectTheRunnerOutsideTheInbox() throws {
    let source = root.appendingPathComponent("source.bin")
    try Data([1, 2, 3]).write(to: source)
    let id = "00000000-0000-4000-8000-000000000003"
    let inbox = try AppleIncomingShareInbox(
      rootDirectory: root,
      makeID: { id }
    )
    _ = try inbox.capture(
      text: nil,
      fileURL: source,
      mimeType: "application/octet-stream",
      displayName: "source.bin"
    )
    let metadata = root.appendingPathComponent("\(id).json")
    var value = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata))
      as! [String: Any]
    value["filePath"] = source.path
    try JSONSerialization.data(withJSONObject: value).write(to: metadata)

    XCTAssertTrue(try AppleIncomingShareInbox(rootDirectory: root).pending().isEmpty)
  }

  func testInterruptedTemporaryFilesAreRemovedOnStartup() throws {
    let payload = root.appendingPathComponent("stale.payload.tmp")
    let metadata = root.appendingPathComponent("stale.json.tmp")
    try Data([1]).write(to: payload)
    try Data([2]).write(to: metadata)

    _ = try AppleIncomingShareInbox(rootDirectory: root)

    XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
  }

  func testTextLimitMatchesDartUTF16Validation() throws {
    let inbox = try AppleIncomingShareInbox(rootDirectory: root)

    XCTAssertThrowsError(
      try inbox.capture(
        text: String(repeating: "😀", count: 16_385),
        fileURL: nil,
        mimeType: nil,
        displayName: nil
      )
    ) { error in
      XCTAssertEqual(error as? AppleIncomingShareError, .invalidCaption)
    }
  }

  func testCancelledCopyLeavesNoPayloadOrMetadata() throws {
    let source = root.appendingPathComponent("large.bin")
    try Data(repeating: 7, count: 128 * 1_024).write(to: source)
    let inbox = try AppleIncomingShareInbox(rootDirectory: root)

    XCTAssertThrowsError(
      try inbox.capture(
        text: nil,
        fileURL: source,
        mimeType: "application/octet-stream",
        displayName: "large.bin",
        cancelled: { true }
      )
    ) { error in
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertTrue(inbox.pending().isEmpty)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
      .filter { $0 != "large.bin" }
    XCTAssertTrue(leftovers.isEmpty)
  }

}
