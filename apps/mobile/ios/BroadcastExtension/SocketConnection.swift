import Foundation

/// The extension's end of the unix-domain socket that `FlutterSocketConnection`
/// binds in the shared App Group container. The application listens, this
/// connects: ReplayKit hosts the broadcast in a process of its own, so the
/// frames have to cross a process boundary and a socket in the group container
/// is the only channel both sides can reach.
final class SocketConnection: NSObject {
  private let filePath: String
  private var socketHandle: Int32 = -1
  private var readStream: InputStream?
  private var writeStream: OutputStream?
  private var streamQueue = DispatchQueue(
    label: "com.nkshub.nextcloudtalk.broadcast.socket",
    qos: .userInitiated
  )
  private var networkThread: Thread?

  /// Called when the other end goes away — the application left the call, or
  /// it was never listening in the first place.
  var didClose: ((Error?) -> Void)?
  /// Called when the stream can take more bytes; the uploader drives its
  /// writes from this rather than blocking the ReplayKit callback.
  var didOpen: (() -> Void)?
  var hasSpaceAvailable: (() -> Void)?

  init?(filePath path: String) {
    filePath = path
    super.init()

    socketHandle = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketHandle != -1 else {
      return nil
    }
  }

  func open() -> Bool {
    guard FileManager.default.fileExists(atPath: filePath) else {
      // Nothing is listening: the application is not in a call, so there is
      // nowhere to send frames and the broadcast should end rather than run
      // invisibly.
      return false
    }
    guard connectSocket() else {
      return false
    }

    var readCF: Unmanaged<CFReadStream>?
    var writeCF: Unmanaged<CFWriteStream>?
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, socketHandle, &readCF, &writeCF)
    guard let read = readCF?.takeRetainedValue(),
      let write = writeCF?.takeRetainedValue()
    else {
      return false
    }

    let input = read as InputStream
    let output = write as OutputStream
    readStream = input
    writeStream = output
    input.delegate = self
    output.delegate = self
    input.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))
    output.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))

    let thread = Thread { [weak self] in
      guard let self else { return }
      input.schedule(in: .current, forMode: .common)
      output.schedule(in: .current, forMode: .common)
      input.open()
      output.open()
      while !Thread.current.isCancelled {
        RunLoop.current.run(mode: .common, before: .distantFuture)
      }
    }
    thread.qualityOfService = .userInitiated
    networkThread = thread
    thread.start()
    return true
  }

  func close() {
    networkThread?.cancel()
    readStream?.delegate = nil
    writeStream?.delegate = nil
    readStream?.close()
    writeStream?.close()
    readStream = nil
    writeStream = nil
    if socketHandle != -1 {
      Darwin.close(socketHandle)
      socketHandle = -1
    }
  }

  /// Writes as much of [buffer] as the stream will take right now and returns
  /// how many bytes went out; the caller resumes on `hasSpaceAvailable`.
  func writePartial(buffer: UnsafePointer<UInt8>, maxLength length: Int) -> Int {
    guard let stream = writeStream, stream.hasSpaceAvailable else {
      return 0
    }
    return stream.write(buffer, maxLength: length)
  }

  private func connectSocket() -> Bool {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(filePath.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count < capacity else {
      return false
    }
    withUnsafeMutablePointer(to: &address.sun_path) { path in
      path.withMemoryRebound(to: UInt8.self, capacity: capacity) { bytes in
        for (index, byte) in pathBytes.enumerated() {
          bytes[index] = byte
        }
        bytes[pathBytes.count] = 0
      }
    }

    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let status = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
        Darwin.connect(socketHandle, address, size)
      }
    }
    return status == 0
  }
}

extension SocketConnection: StreamDelegate {
  func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
    switch eventCode {
    case .openCompleted:
      didOpen?()
    case .hasSpaceAvailable:
      hasSpaceAvailable?()
    case .errorOccurred:
      didClose?(aStream.streamError)
    case .endEncountered:
      didClose?(nil)
    default:
      break
    }
  }
}
