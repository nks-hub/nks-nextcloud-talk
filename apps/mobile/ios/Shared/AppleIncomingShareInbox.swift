import CryptoKit
import Foundation

struct AppleIncomingShare: Codable, Equatable {
  let id: String
  let text: String?
  let filePath: String?
  let mimeType: String?
  let displayName: String?
  let byteLength: Int64?
  let sha256: String?
  let sourceFingerprint: String
  let createdAtMillis: Int64

  var methodChannelValue: [String: Any] {
    var value: [String: Any] = ["id": id]
    if let text { value["text"] = text }
    if let filePath { value["filePath"] = filePath }
    if let mimeType { value["mimeType"] = mimeType }
    if let displayName { value["displayName"] = displayName }
    if let byteLength { value["byteLength"] = byteLength }
    if let sha256 { value["sha256"] = sha256 }
    return value
  }
}

struct AppleIncomingShareCapture {
  let share: AppleIncomingShare
  let inserted: Bool
}

enum AppleIncomingShareError: Error, Equatable {
  case appGroupUnavailable
  case empty
  case inboxFull
  case invalidCaption
  case invalidFile
  case fileTooLarge
}

final class AppleIncomingShareInbox {
  static let applicationGroup = "group.com.nkshub.nextcloudtalk"

  private static let maximumBytes: Int64 = 512 * 1024 * 1024
  private static let maximumPending = 16
  private static let maximumTextLength = 32_768
  private static let maximumCaptionLength = 4_000
  private static let copyBufferBytes = 64 * 1024
  private static let defaultMimeType = "application/octet-stream"
  private static let defaultDisplayName = "shared-file"

  private let root: URL
  private let fileManager: FileManager
  private let now: () -> Date
  private let makeID: () -> String

  convenience init() throws {
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: Self.applicationGroup
    ) else {
      throw AppleIncomingShareError.appGroupUnavailable
    }
    try self.init(
      rootDirectory: container
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("share-inbox-v1", isDirectory: true)
    )
  }

  init(
    rootDirectory: URL,
    fileManager: FileManager = .default,
    now: @escaping () -> Date = Date.init,
    makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
  ) throws {
    root = rootDirectory.standardizedFileURL
    self.fileManager = fileManager
    self.now = now
    self.makeID = makeID
    try fileManager.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: nil
    )
    removeInterruptedWrites()
  }

  func capture(
    text rawText: String?,
    fileURL: URL?,
    mimeType rawMimeType: String?,
    displayName rawDisplayName: String?,
    cancelled: () -> Bool = { false }
  ) throws -> AppleIncomingShareCapture {
    let text = normalizedText(rawText)
    if fileURL == nil, text == nil {
      throw AppleIncomingShareError.empty
    }
    if fileURL == nil, let text, text.utf16.count > Self.maximumTextLength {
      throw AppleIncomingShareError.invalidCaption
    }
    if fileURL != nil, let text, text.utf16.count > Self.maximumCaptionLength {
      throw AppleIncomingShareError.invalidCaption
    }
    let existingShares = pending()
    let id = makeID()
    guard UUID(uuidString: id) != nil else {
      throw AppleIncomingShareError.invalidFile
    }
    let createdAtMillis = Int64(now().timeIntervalSince1970 * 1_000)
    let payloadURL = payloadURL(for: id)
    let payloadTemporaryURL = payloadTemporaryURL(for: id)

    do {
      let copied = try fileURL.map {
        try copyFile(
          from: $0,
          to: payloadTemporaryURL,
          finalURL: payloadURL,
          mimeType: rawMimeType,
          displayName: rawDisplayName,
          cancelled: cancelled
        )
      }
      let fingerprint = sourceFingerprint(
        text: text,
        mimeType: copied?.mimeType,
        displayName: copied?.displayName,
        fileDigest: copied?.sha256
      )
      if let duplicate = existingShares.first(where: {
        $0.sourceFingerprint == fingerprint
      }), fileManager.fileExists(atPath: metadataURL(for: duplicate.id).path) {
        try? fileManager.removeItem(at: payloadTemporaryURL)
        try? fileManager.removeItem(at: payloadURL)
        return AppleIncomingShareCapture(share: duplicate, inserted: false)
      }
      if existingShares.count >= Self.maximumPending {
        throw AppleIncomingShareError.inboxFull
      }
      let share = AppleIncomingShare(
        id: id,
        text: text,
        filePath: copied == nil ? nil : payloadURL.path,
        mimeType: copied?.mimeType,
        displayName: copied?.displayName,
        byteLength: copied?.byteLength,
        sha256: copied?.sha256,
        sourceFingerprint: fingerprint,
        createdAtMillis: createdAtMillis
      )
      try writeMetadata(share)
      return AppleIncomingShareCapture(share: share, inserted: true)
    } catch {
      try? fileManager.removeItem(at: payloadTemporaryURL)
      try? fileManager.removeItem(at: payloadURL)
      try? fileManager.removeItem(at: metadataTemporaryURL(for: id))
      try? fileManager.removeItem(at: metadataURL(for: id))
      throw error
    }
  }

  func pending() -> [AppleIncomingShare] {
    guard let files = try? fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }
    return files
      .filter { $0.pathExtension == "json" }
      .compactMap(readMetadata)
      .sorted { $0.createdAtMillis < $1.createdAtMillis }
      .prefix(Self.maximumPending)
      .map { $0 }
  }

  @discardableResult
  func complete(id: String) -> Bool {
    guard UUID(uuidString: id) != nil else { return false }
    let existed = fileManager.fileExists(atPath: metadataURL(for: id).path)
    try? fileManager.removeItem(at: payloadTemporaryURL(for: id))
    try? fileManager.removeItem(at: payloadURL(for: id))
    try? fileManager.removeItem(at: metadataTemporaryURL(for: id))
    try? fileManager.removeItem(at: metadataURL(for: id))
    return existed
  }

  private func copyFile(
    from sourceURL: URL,
    to temporaryURL: URL,
    finalURL: URL,
    mimeType: String?,
    displayName: String?,
    cancelled: () -> Bool
  ) throws -> (
    byteLength: Int64,
    sha256: String,
    mimeType: String,
    displayName: String
  ) {
    guard sourceURL.isFileURL else {
      throw AppleIncomingShareError.invalidFile
    }
    let resourceLength = try? sourceURL.resourceValues(
      forKeys: [.fileSizeKey]
    ).fileSize
    if let resourceLength, Int64(resourceLength) > Self.maximumBytes {
      throw AppleIncomingShareError.fileTooLarge
    }

    let securityScoped = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if securityScoped { sourceURL.stopAccessingSecurityScopedResource() }
    }
    _ = fileManager.createFile(atPath: temporaryURL.path, contents: nil)
    let input = try FileHandle(forReadingFrom: sourceURL)
    let output = try FileHandle(forWritingTo: temporaryURL)
    defer {
      try? input.close()
      try? output.close()
    }
    var hasher = SHA256()
    var byteLength: Int64 = 0
    while let chunk = try input.read(upToCount: Self.copyBufferBytes),
          !chunk.isEmpty
    {
      if cancelled() { throw CancellationError() }
      byteLength += Int64(chunk.count)
      if byteLength > Self.maximumBytes {
        throw AppleIncomingShareError.fileTooLarge
      }
      hasher.update(data: chunk)
      try output.write(contentsOf: chunk)
    }
    guard byteLength > 0 else {
      throw AppleIncomingShareError.invalidFile
    }
    try output.synchronize()
    try output.close()
    try input.close()
    try fileManager.moveItem(at: temporaryURL, to: finalURL)
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return (
      byteLength: byteLength,
      sha256: digest,
      mimeType: normalizedMimeType(mimeType),
      displayName: normalizedDisplayName(
        displayName ?? sourceURL.lastPathComponent
      )
    )
  }

  private func writeMetadata(_ share: AppleIncomingShare) throws {
    let id = share.id
    let temporaryURL = metadataTemporaryURL(for: id)
    let data = try JSONEncoder().encode(share)
    try data.write(to: temporaryURL, options: [.withoutOverwriting])
    let file = try FileHandle(forWritingTo: temporaryURL)
    try file.synchronize()
    try file.close()
    try fileManager.moveItem(at: temporaryURL, to: metadataURL(for: id))
  }

  private func readMetadata(_ url: URL) -> AppleIncomingShare? {
    guard let data = try? Data(contentsOf: url),
          let share = try? JSONDecoder().decode(AppleIncomingShare.self, from: data),
          UUID(uuidString: share.id) != nil,
          url.standardizedFileURL == metadataURL(for: share.id),
          share.sourceFingerprint.count == 64,
          share.sourceFingerprint.allSatisfy({ $0.isHexDigit }),
          validText(share.text, hasFile: share.filePath != nil)
    else {
      return nil
    }
    if let filePath = share.filePath {
      let expected = payloadURL(for: share.id).standardizedFileURL
      let actual = URL(fileURLWithPath: filePath).standardizedFileURL
      let payloadSize = (try? expected.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        .map { Int64($0) }
      guard actual == expected,
            share.byteLength ?? 0 > 0,
            share.byteLength ?? 0 <= Self.maximumBytes,
            payloadSize == share.byteLength,
            share.sha256?.count == 64,
            share.sha256?.allSatisfy({ $0.isHexDigit }) == true,
            isValidMimeType(share.mimeType),
            !(share.displayName ?? "").isEmpty
      else {
        return nil
      }
    } else if share.byteLength != nil || share.sha256 != nil ||
                share.mimeType != nil || share.displayName != nil
    {
      return nil
    }
    return share
  }

  private func validText(_ text: String?, hasFile: Bool) -> Bool {
    guard let text else { return hasFile }
    return !text.isEmpty &&
      text.utf16.count <= (hasFile ? Self.maximumCaptionLength : Self.maximumTextLength)
  }

  private func normalizedText(_ value: String?) -> String? {
    let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return text?.isEmpty == false ? text : nil
  }

  private func normalizedMimeType(_ value: String?) -> String {
    let mimeType = value?.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return isValidMimeType(mimeType) ? mimeType! : Self.defaultMimeType
  }

  private func isValidMimeType(_ value: String?) -> Bool {
    guard let value, value.count <= 255 else { return false }
    return value.range(
      of: #"^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$"#,
      options: .regularExpression
    ) != nil
  }

  private func normalizedDisplayName(_ value: String) -> String {
    let scalars = value.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0) &&
        $0.value != 47 && $0.value != 92
    }
    let name = String(String.UnicodeScalarView(scalars))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return prefixUTF16(name.isEmpty ? Self.defaultDisplayName : name, limit: 255)
  }

  private func prefixUTF16(_ value: String, limit: Int) -> String {
    var result = ""
    var count = 0
    for character in value {
      let width = String(character).utf16.count
      if count + width > limit { break }
      result.append(character)
      count += width
    }
    return result
  }

  private func sourceFingerprint(
    text: String?,
    mimeType: String?,
    displayName: String?,
    fileDigest: String?
  ) -> String {
    let value = [text ?? "", mimeType ?? "", displayName ?? "", fileDigest ?? ""]
      .joined(separator: "\0")
    return SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private func removeInterruptedWrites() {
    guard let files = try? fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil
    ) else {
      return
    }
    for file in files where file.pathExtension == "tmp" {
      try? fileManager.removeItem(at: file)
    }
  }

  private func payloadURL(for id: String) -> URL {
    root.appendingPathComponent("\(id).payload")
  }

  private func payloadTemporaryURL(for id: String) -> URL {
    root.appendingPathComponent("\(id).payload.tmp")
  }

  private func metadataURL(for id: String) -> URL {
    root.appendingPathComponent("\(id).json")
  }

  private func metadataTemporaryURL(for id: String) -> URL {
    root.appendingPathComponent("\(id).json.tmp")
  }
}
