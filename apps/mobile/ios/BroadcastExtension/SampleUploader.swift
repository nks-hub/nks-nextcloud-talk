import CoreImage
import CoreMedia
import Foundation
import ReplayKit

/// Serialises one ReplayKit frame into the shape
/// `FlutterSocketConnectionFrameReader` parses on the other side: a framed
/// HTTP message whose headers carry the picture's size and orientation and
/// whose body is a JPEG. The reader rebuilds a `CVPixelBuffer` from it, so the
/// wire format is not ours to choose — it is read off that parser.
final class SampleUploader {
  private static let imageContext = CIContext(options: nil)

  private let connection: SocketConnection
  private let queue = DispatchQueue(
    label: "com.nkshub.nextcloudtalk.broadcast.uploader",
    qos: .userInitiated
  )

  private var message: Data?
  private var sent = 0
  private var sending = false

  init(connection: SocketConnection) {
    self.connection = connection
    self.connection.hasSpaceAvailable = { [weak self] in
      self?.queue.async { self?.writeChunk() }
    }
  }

  /// Drops the frame when the previous one is still going out — ReplayKit
  /// delivers faster than a unix socket drains, and a queue of stale pictures
  /// is worse than a lower frame rate.
  func send(sample: CMSampleBuffer) {
    queue.async { [weak self] in
      guard let self, !self.sending else { return }
      guard let data = SampleUploader.encode(sample: sample) else { return }
      self.message = data
      self.sent = 0
      self.sending = true
      self.writeChunk()
    }
  }

  private func writeChunk() {
    guard let data = message else {
      sending = false
      return
    }
    while sent < data.count {
      let written = data.withUnsafeBytes { raw -> Int in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
          return 0
        }
        return connection.writePartial(
          buffer: base.advanced(by: sent),
          maxLength: data.count - sent
        )
      }
      if written <= 0 {
        // No space right now; `hasSpaceAvailable` brings us back.
        return
      }
      sent += written
    }
    message = nil
    sent = 0
    sending = false
  }

  private static func encode(sample: CMSampleBuffer) -> Data? {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
      return nil
    }
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    guard
      let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
      let jpeg = imageContext.jpegRepresentation(
        of: image,
        colorSpace: colorSpace,
        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6]
      )
    else {
      return nil
    }

    let orientation =
      CMGetAttachment(
        sample,
        key: RPVideoSampleOrientationKey as CFString,
        attachmentModeOut: nil
      ) as? NSNumber

    guard let url = CFURLCreateWithString(kCFAllocatorDefault, "http://localhost" as CFString, nil)
    else {
      return nil
    }
    let request = CFHTTPMessageCreateRequest(
      kCFAllocatorDefault,
      "POST" as CFString,
      url,
      kCFHTTPVersion1_1
    ).takeRetainedValue()
    CFHTTPMessageSetHeaderFieldValue(
      request, "Content-Length" as CFString, String(jpeg.count) as CFString)
    CFHTTPMessageSetHeaderFieldValue(
      request, "Buffer-Width" as CFString,
      String(CVPixelBufferGetWidth(pixelBuffer)) as CFString)
    CFHTTPMessageSetHeaderFieldValue(
      request, "Buffer-Height" as CFString,
      String(CVPixelBufferGetHeight(pixelBuffer)) as CFString)
    CFHTTPMessageSetHeaderFieldValue(
      request, "Buffer-Orientation" as CFString,
      String(orientation?.intValue ?? 0) as CFString)
    CFHTTPMessageSetBody(request, jpeg as CFData)

    return CFHTTPMessageCopySerializedMessage(request)?.takeRetainedValue() as Data?
  }
}
