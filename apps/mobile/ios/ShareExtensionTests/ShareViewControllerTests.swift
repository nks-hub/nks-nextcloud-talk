import CryptoKit
import UIKit
import UniformTypeIdentifiers
import XCTest

private enum ProviderFailure: Error {
  case refused
}

/// Fails `loadFileRepresentation` so the capture has to fall back to `loadItem`.
private final class FileRepresentationFailingProvider: NSItemProvider {
  override func loadFileRepresentation(
    forTypeIdentifier typeIdentifier: String,
    completionHandler: @escaping (URL?, Error?) -> Void
  ) -> Progress {
    completionHandler(nil, ProviderFailure.refused)
    return Progress()
  }
}

/// Fails both paths, the way a provider whose source has gone away behaves.
private final class UnreadableProvider: NSItemProvider {
  override func loadFileRepresentation(
    forTypeIdentifier typeIdentifier: String,
    completionHandler: @escaping (URL?, Error?) -> Void
  ) -> Progress {
    completionHandler(nil, ProviderFailure.refused)
    return Progress()
  }

  override func loadItem(
    forTypeIdentifier typeIdentifier: String,
    options: [AnyHashable: Any]? = nil,
    completionHandler: NSItemProvider.CompletionHandler? = nil
  ) {
    completionHandler?(nil, ProviderFailure.refused)
  }
}

@MainActor
final class ShareViewControllerTests: XCTestCase {
  private var root: URL!
  private var controller: ShareViewController!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    controller = ShareViewController()
  }

  override func tearDownWithError() throws {
    controller = nil
    try? FileManager.default.removeItem(at: root)
  }

  private func makeInbox() throws -> AppleIncomingShareInbox {
    try AppleIncomingShareInbox(
      rootDirectory: root.appendingPathComponent("inbox", isDirectory: true)
    )
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  func testFileProviderIsCopiedWithItsBytesAndType() async throws {
    let bytes = Data("shared through the sheet".utf8)
    let source = root.appendingPathComponent("note.txt")
    try bytes.write(to: source)
    let inbox = try makeInbox()

    let capture = try await controller.captureFile(
      NSItemProvider(contentsOf: source)!,
      text: "caption",
      inbox: inbox
    )

    XCTAssertTrue(capture.inserted)
    XCTAssertEqual(capture.share.text, "caption")
    XCTAssertEqual(capture.share.byteLength, Int64(bytes.count))
    XCTAssertEqual(capture.share.sha256, digest(bytes))
    XCTAssertEqual(capture.share.mimeType, "text/plain")
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: capture.share.filePath!)), bytes)
    XCTAssertEqual(inbox.pending(), [capture.share])
  }

  func testCaptureFallsBackToLoadItemWhenTheFileRepresentationRefuses() async throws {
    let bytes = Data([0x1, 0x2, 0x3, 0x4, 0x5])
    let provider = FileRepresentationFailingProvider()
    provider.suggestedName = "payload.bin"
    provider.registerItem(forTypeIdentifier: UTType.data.identifier) { completion, _, _ in
      completion?(bytes as NSData, nil)
    }
    let inbox = try makeInbox()

    let capture = try await controller.captureFile(provider, text: nil, inbox: inbox)

    XCTAssertTrue(capture.inserted)
    XCTAssertEqual(capture.share.byteLength, Int64(bytes.count))
    XCTAssertEqual(capture.share.sha256, digest(bytes))
    XCTAssertEqual(capture.share.displayName, "payload.bin")
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: capture.share.filePath!)), bytes)
  }

  func testImageProviderIsCapturedAsPngBytes() async throws {
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }
    let provider = FileRepresentationFailingProvider()
    provider.suggestedName = "photo.png"
    provider.registerItem(forTypeIdentifier: UTType.png.identifier) { completion, _, _ in
      completion?(image, nil)
    }
    let inbox = try makeInbox()

    let capture = try await controller.captureFile(provider, text: nil, inbox: inbox)

    XCTAssertTrue(capture.inserted)
    XCTAssertEqual(capture.share.mimeType, "image/png")
    XCTAssertEqual(capture.share.displayName, "photo.png")
    let written = try Data(contentsOf: URL(fileURLWithPath: capture.share.filePath!))
    XCTAssertEqual(capture.share.byteLength, Int64(written.count))
    XCTAssertEqual(written.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
  }

  func testMoreThanOneFileAttachmentIsRefused() throws {
    let first = root.appendingPathComponent("one.txt")
    let second = root.appendingPathComponent("two.txt")
    try Data("one".utf8).write(to: first)
    try Data("two".utf8).write(to: second)
    let providers = [NSItemProvider(contentsOf: first)!, NSItemProvider(contentsOf: second)!]

    XCTAssertThrowsError(try controller.singleFileProvider(in: providers)) { error in
      XCTAssertEqual(error as? AppleIncomingShareError, .invalidFile)
    }
  }

  func testASingleFileAttachmentIsSelectedAndTextOnlyYieldsNone() throws {
    let source = root.appendingPathComponent("only.txt")
    try Data("only".utf8).write(to: source)
    let file = NSItemProvider(contentsOf: source)!
    let text = NSItemProvider(object: "just a caption" as NSString)

    XCTAssertTrue(try controller.singleFileProvider(in: [text, file]) === file)
    XCTAssertNil(try controller.singleFileProvider(in: [text]))
  }

  func testProviderThatFailsBothPathsThrows() async throws {
    let provider = UnreadableProvider()
    provider.suggestedName = "gone.bin"
    provider.registerItem(forTypeIdentifier: UTType.data.identifier) { completion, _, _ in
      completion?(Data() as NSData, nil)
    }
    let inbox = try makeInbox()

    do {
      _ = try await controller.captureFile(provider, text: nil, inbox: inbox)
      XCTFail("expected the capture to throw")
    } catch {
      XCTAssertTrue(inbox.pending().isEmpty)
    }
  }
}
