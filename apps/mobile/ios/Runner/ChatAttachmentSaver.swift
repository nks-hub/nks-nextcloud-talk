import Flutter
import UIKit

enum AppleAttachmentSaveSourceError: String, Error {
  case invalidSource = "invalid_source"
  case tooLarge = "too_large"
}

struct AppleAttachmentSaveSourceValidator {
  static let maximumBytes = 64 * 1024 * 1024

  static func validate(
    sourcePath: String?,
    fileName: String?,
    contentType: String?,
    ownedRoots: [URL],
    fileManager: FileManager = .default
  ) throws -> URL {
    guard let sourcePath,
          let fileName,
          let contentType,
          isSafeFileName(fileName),
          isMediaType(contentType)
    else {
      throw AppleAttachmentSaveSourceError.invalidSource
    }
    let source = URL(fileURLWithPath: sourcePath)
      .resolvingSymlinksInPath()
      .standardizedFileURL
    guard source.lastPathComponent == fileName,
          ownedRoots.contains(where: { contains(source, root: $0) })
    else {
      throw AppleAttachmentSaveSourceError.invalidSource
    }
    let attributes = try fileManager.attributesOfItem(atPath: source.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
          let byteCount = (attributes[.size] as? NSNumber)?.intValue,
          byteCount > 0
    else {
      throw AppleAttachmentSaveSourceError.invalidSource
    }
    guard byteCount <= maximumBytes else {
      throw AppleAttachmentSaveSourceError.tooLarge
    }
    return source
  }

  private static func contains(_ source: URL, root: URL) -> Bool {
    let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
    let rootComponents = canonicalRoot.pathComponents
    let sourceComponents = source.pathComponents
    return sourceComponents.count > rootComponents.count &&
      Array(sourceComponents.prefix(rootComponents.count)) == rootComponents
  }

  private static func isSafeFileName(_ value: String) -> Bool {
    guard !value.hasSuffix("."), value.count <= 128 else {
      return false
    }
    return value.range(
      of: "^[A-Za-z0-9._-]+$",
      options: .regularExpression
    ) != nil
  }

  private static func isMediaType(_ value: String) -> Bool {
    value.range(
      of: "^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$",
      options: .regularExpression
    ) != nil
  }
}

final class ChatAttachmentSaver: NSObject, UIDocumentPickerDelegate {
  static let channelName = "com.nkshub.nextcloudtalk/attachment_saver"

  static func activeViewController() -> UIViewController? {
    let root = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)?
      .rootViewController
    var visible = root
    while let presented = visible?.presentedViewController {
      visible = presented
    }
    return visible
  }

  private let channel: FlutterMethodChannel?
  private let presentingViewController: () -> UIViewController?
  private let ownedRoots: [URL]
  private var pendingResult: FlutterResult?
  private weak var activePicker: UIDocumentPickerViewController?
  private var disposed = false

  init(
    messenger: FlutterBinaryMessenger,
    presentingViewController: @escaping () -> UIViewController? =
      ChatAttachmentSaver.activeViewController,
    ownedRoots: [URL]? = nil
  ) {
    let methodChannel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel = methodChannel
    self.presentingViewController = presentingViewController
    self.ownedRoots = ownedRoots ?? FileManager.default.urls(
      for: .cachesDirectory,
      in: .userDomainMask
    )
    super.init()
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  init(
    presentingViewController: @escaping () -> UIViewController?,
    ownedRoots: [URL]
  ) {
    channel = nil
    self.presentingViewController = presentingViewController
    self.ownedRoots = ownedRoots
    super.init()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "save" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard !disposed else {
      result(FlutterError(code: "cancelled", message: "The saver is closed.", details: nil))
      return
    }
    guard pendingResult == nil else {
      result(
        FlutterError(
          code: "save_in_progress",
          message: "An attachment save is already active.",
          details: nil
        )
      )
      return
    }
    guard let arguments = call.arguments as? [String: Any] else {
      result(invalidSourceError())
      return
    }
    let source: URL
    do {
      source = try AppleAttachmentSaveSourceValidator.validate(
        sourcePath: arguments["sourcePath"] as? String,
        fileName: arguments["fileName"] as? String,
        contentType: arguments["contentType"] as? String,
        ownedRoots: ownedRoots
      )
    } catch let error as AppleAttachmentSaveSourceError {
      result(
        FlutterError(
          code: error.rawValue,
          message: "The attachment source is invalid.",
          details: nil
        )
      )
      return
    } catch let error as CocoaError where error.code == .fileReadNoPermission {
      result(
        FlutterError(
          code: "permission_denied",
          message: "The attachment source cannot be accessed.",
          details: nil
        )
      )
      return
    } catch {
      // FileManager uses several Cocoa error codes for an inaccessible source.
      result(invalidSourceError())
      return
    }
    guard let presenter = presentingViewController() else {
      result(
        FlutterError(
          code: "unavailable",
          message: "No view can present the document picker.",
          details: nil
        )
      )
      return
    }
    pendingResult = result
    let picker = UIDocumentPickerViewController(forExporting: [source], asCopy: true)
    picker.delegate = self
    activePicker = picker
    presenter.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish("cancelled")
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard !urls.isEmpty else {
      finish(
        FlutterError(
          code: "storage_failed",
          message: "No document destination was returned.",
          details: nil
        )
      )
      return
    }
    finish("saved")
  }

  func dispose() {
    guard !disposed else {
      return
    }
    disposed = true
    activePicker?.dismiss(animated: false)
    activePicker = nil
    finish(
      FlutterError(
        code: "cancelled",
        message: "The attachment save was cancelled.",
        details: nil
      )
    )
    channel?.setMethodCallHandler(nil)
  }

  private func finish(_ value: Any?) {
    let result = pendingResult
    pendingResult = nil
    activePicker = nil
    result?(value)
  }

  private func invalidSourceError() -> FlutterError {
    FlutterError(
      code: "invalid_source",
      message: "The attachment source is invalid.",
      details: nil
    )
  }
}
