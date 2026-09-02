import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
  private let statusLabel = UILabel()
  private let actionButton = UIButton(type: .system)
  private let cancellation = ShareCancellation()
  private var processingTask: Task<Void, Never>?
  private var started = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    statusLabel.font = .preferredFont(forTextStyle: .body)
    statusLabel.adjustsFontForContentSizeCategory = true
    statusLabel.numberOfLines = 0
    statusLabel.textAlignment = .center
    statusLabel.text = NSLocalizedString("Preparing shared item…", comment: "Share extension status")

    actionButton.setTitle(NSLocalizedString("Cancel", comment: "Share extension action"), for: .normal)
    actionButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
    actionButton.titleLabel?.adjustsFontForContentSizeCategory = true
    actionButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
    actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

    let stack = UIStackView(arrangedSubviews: [statusLabel, actionButton])
    stack.axis = .vertical
    stack.spacing = 20
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
      stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
    ])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !started else { return }
    started = true
    processingTask = Task { await captureShare() }
  }

  deinit {
    cancellation.cancel()
    processingTask?.cancel()
  }

  @objc private func cancel() {
    if processingTask == nil {
      extensionContext?.completeRequest(returningItems: nil)
      return
    }
    cancellation.cancel()
    processingTask?.cancel()
    extensionContext?.cancelRequest(withError: CancellationError())
  }

  @MainActor
  private func captureShare() async {
    var capturedInbox: AppleIncomingShareInbox?
    var capturedShare: AppleIncomingShareCapture?
    do {
      let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
      let providers = items.flatMap { $0.attachments ?? [] }
      let fileProviders = providers.filter(isFileProvider)
      guard fileProviders.count <= 1 else {
        throw AppleIncomingShareError.invalidFile
      }
      let text = try await sharedText(from: items, providers: providers, excluding: fileProviders.first)
      let inbox = try AppleIncomingShareInbox()
      capturedInbox = inbox
      if let provider = fileProviders.first {
        capturedShare = try await captureFile(provider, text: text, inbox: inbox)
      } else {
        capturedShare = try inbox.capture(
          text: text,
          fileURL: nil,
          mimeType: nil,
          displayName: nil
        )
      }
      try Task.checkCancellation()
      processingTask = nil
      statusLabel.text = NSLocalizedString(
        "Ready. Open NKS Talk to choose a conversation.",
        comment: "Share extension completion"
      )
      actionButton.setTitle(
        NSLocalizedString("Done", comment: "Share extension action"),
        for: .normal
      )
    } catch is CancellationError {
      if let capturedShare {
        if capturedShare.inserted {
          _ = capturedInbox?.complete(id: capturedShare.share.id)
        }
      }
      return
    } catch {
      if let capturedShare {
        if capturedShare.inserted {
          _ = capturedInbox?.complete(id: capturedShare.share.id)
        }
      }
      showFailure()
    }
  }

  private func sharedText(
    from items: [NSExtensionItem],
    providers: [NSItemProvider],
    excluding fileProvider: NSItemProvider?
  ) async throws -> String? {
    if let attributed = items.compactMap(\.attributedContentText).first {
      return attributed.string
    }
    let provider = providers.first {
      $0 !== fileProvider &&
        ($0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) ||
          $0.hasItemConformingToTypeIdentifier(UTType.url.identifier))
    }
    guard let provider else { return nil }
    let type = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
      ? UTType.plainText.identifier
      : UTType.url.identifier
    return try await withCheckedThrowingContinuation { continuation in
      provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        let text: String?
        switch item {
        case let value as String:
          text = value
        case let value as NSAttributedString:
          text = value.string
        case let value as URL:
          text = value.absoluteString
        case let value as Data:
          text = String(data: value, encoding: .utf8)
        default:
          text = nil
        }
        continuation.resume(returning: text)
      }
    }
  }

  private func captureFile(
    _ provider: NSItemProvider,
    text: String?,
    inbox: AppleIncomingShareInbox
  ) async throws -> AppleIncomingShareCapture {
    guard let typeIdentifier = fileTypeIdentifier(for: provider) else {
      throw AppleIncomingShareError.invalidFile
    }
    let mimeType = UTType(typeIdentifier)?.preferredMIMEType
    do {
      return try await captureFileRepresentation(
        provider,
        typeIdentifier: typeIdentifier,
        text: text,
        mimeType: mimeType,
        inbox: inbox
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return try await captureLoadedItem(
        provider,
        typeIdentifier: typeIdentifier,
        text: text,
        mimeType: mimeType,
        inbox: inbox
      )
    }
  }

  private func captureFileRepresentation(
    _ provider: NSItemProvider,
    typeIdentifier: String,
    text: String?,
    mimeType: String?,
    inbox: AppleIncomingShareInbox
  ) async throws -> AppleIncomingShareCapture {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
        do {
          if let error { throw error }
          guard let url else { throw AppleIncomingShareError.invalidFile }
          continuation.resume(
            returning: try inbox.capture(
              text: text,
              fileURL: url,
              mimeType: mimeType,
              displayName: provider.suggestedName ?? url.lastPathComponent,
              cancelled: { [cancellation] in cancellation.isCancelled }
            )
          )
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func captureLoadedItem(
    _ provider: NSItemProvider,
    typeIdentifier: String,
    text: String?,
    mimeType: String?,
    inbox: AppleIncomingShareInbox
  ) async throws -> AppleIncomingShareCapture {
    let item: NSSecureCoding = try await withCheckedThrowingContinuation { continuation in
      provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let item {
          continuation.resume(returning: item)
        } else {
          continuation.resume(throwing: AppleIncomingShareError.invalidFile)
        }
      }
    }
    if let url = item as? URL {
      return try inbox.capture(
        text: text,
        fileURL: url,
        mimeType: mimeType,
        displayName: provider.suggestedName ?? url.lastPathComponent,
        cancelled: { [cancellation] in cancellation.isCancelled }
      )
    }
    let data: Data
    if let value = item as? Data {
      data = value
    } else if let image = item as? UIImage, let value = image.pngData() {
      data = value
    } else {
      throw AppleIncomingShareError.invalidFile
    }
    guard !cancellation.isCancelled else { throw CancellationError() }
    let type = UTType(typeIdentifier)
    let suffix = type?.preferredFilenameExtension ?? "bin"
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(suffix)
    try data.write(to: temporary, options: [.atomic])
    defer { try? FileManager.default.removeItem(at: temporary) }
    return try inbox.capture(
      text: text,
      fileURL: temporary,
      mimeType: item is UIImage ? "image/png" : mimeType,
      displayName: provider.suggestedName ?? "shared-file.\(suffix)",
      cancelled: { [cancellation] in cancellation.isCancelled }
    )
  }

  private func isFileProvider(_ provider: NSItemProvider) -> Bool {
    fileTypeIdentifier(for: provider) != nil
  }

  private func fileTypeIdentifier(for provider: NSItemProvider) -> String? {
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      return provider.registeredTypeIdentifiers.first { identifier in
        guard let type = UTType(identifier) else { return false }
        return type != .fileURL && !type.conforms(to: .url) &&
          type.conforms(to: .data)
      } ?? UTType.fileURL.identifier
    }
    guard provider.suggestedName?.isEmpty == false else { return nil }
    return provider.registeredTypeIdentifiers.first { identifier in
      guard let type = UTType(identifier) else { return false }
      return !type.conforms(to: .text) && !type.conforms(to: .url) &&
        type.conforms(to: .data)
    }
  }

  @MainActor
  private func showFailure() {
    processingTask = nil
    statusLabel.text = NSLocalizedString(
      "This item could not be shared.",
      comment: "Share extension failure"
    )
    actionButton.setTitle(NSLocalizedString("Close", comment: "Share extension action"), for: .normal)
  }
}

private final class ShareCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}
