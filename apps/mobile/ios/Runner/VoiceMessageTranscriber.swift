import Flutter
import Foundation
import Speech

final class VoiceMessageTranscriber {
  static let channelName = "com.nkshub.nextcloudtalk/voice_transcription"

  enum StartError: Error {
    case unavailable
  }

  typealias RecognitionCallback = (String?, Bool, Error?) -> Void
  typealias RecognitionStarter = (
    SFSpeechURLRecognitionRequest,
    Locale,
    @escaping RecognitionCallback
  ) throws -> () -> Void
  typealias RecognitionRequestFactory = (URL) -> SFSpeechURLRecognitionRequest
  typealias Scheduler = (
    TimeInterval,
    @escaping () -> Void
  ) -> () -> Void

  private struct Attempt {
    let generation: Int
    let result: FlutterResult
    var cancelRecognition: (() -> Void)?
    var cancelTimeout: (() -> Void)?
  }

  private let allowedRootURL: URL
  private let authorizationStatus: () -> SFSpeechRecognizerAuthorizationStatus
  private let requestAuthorization: (
    @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void
  ) -> Void
  private let startRecognition: RecognitionStarter
  private let makeRequest: RecognitionRequestFactory
  private let schedule: Scheduler
  private var channel: FlutterMethodChannel?
  private var active: Attempt?
  private var generation = 0

  init(
    messenger: FlutterBinaryMessenger? = nil,
    allowedRootURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
    authorizationStatus: @escaping () -> SFSpeechRecognizerAuthorizationStatus = {
      SFSpeechRecognizer.authorizationStatus()
    },
    requestAuthorization: @escaping (
      @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void
    ) -> Void = { completion in
      SFSpeechRecognizer.requestAuthorization(completion)
    },
    startRecognition: RecognitionStarter? = nil,
    requestFactory: @escaping RecognitionRequestFactory = VoiceMessageTranscriber.makeOnDeviceRequest,
    schedule: @escaping Scheduler = VoiceMessageTranscriber.scheduleOnMainQueue
  ) {
    self.allowedRootURL = allowedRootURL
    self.authorizationStatus = authorizationStatus
    self.requestAuthorization = requestAuthorization
    self.startRecognition = startRecognition ?? Self.startOnDeviceRecognition
    self.makeRequest = requestFactory
    self.schedule = schedule

    if let messenger {
      let methodChannel = FlutterMethodChannel(
        name: Self.channelName,
        binaryMessenger: messenger
      )
      methodChannel.setMethodCallHandler { [weak self] call, result in
        guard let self else {
          result(Self.error("cancelled", "Transcriber was released"))
          return
        }
        self.handle(call, result: result)
      }
      channel = methodChannel
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        guard let self else {
          result(Self.error("cancelled", "Transcriber was released"))
          return
        }
        self.handle(call, result: result)
      }
      return
    }

    switch call.method {
    case "transcribe":
      transcribe(call.arguments, result: result)
    case "cancel":
      generation += 1
      cancelActive(message: "Transcription cancelled")
      result(nil)
    case "dispose":
      generation += 1
      cancelActive(message: "Transcriber disposed")
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func transcribe(_ arguments: Any?, result: @escaping FlutterResult) {
    generation += 1
    cancelActive(message: "Transcription superseded")
    let requestGeneration = generation

    guard let values = arguments as? [String: Any],
          let path = values["filePath"] as? String,
          let fileURL = validatedFileURL(path)
    else {
      result(Self.error("invalidFile", "Invalid local audio file"))
      return
    }
    guard let locale = validatedLocale(values["localeIdentifier"]),
          let timeout = validatedTimeout(values["timeoutMillis"])
    else {
      result(Self.error("failed", "Invalid transcription options"))
      return
    }

    active = Attempt(
      generation: requestGeneration,
      result: result,
      cancelRecognition: nil,
      cancelTimeout: nil
    )
    let cancelTimeout = schedule(timeout) { [weak self] in
      Self.performOnMain {
        self?.finish(
          requestGeneration,
          value: Self.error("failed", "Transcription timed out"),
          cancelRecognition: true
        )
      }
    }
    setTimeoutCancellation(cancelTimeout, generation: requestGeneration)
    continueAfterAuthorization(
      authorizationStatus(),
      generation: requestGeneration,
      fileURL: fileURL,
      locale: locale
    )
  }

  private func continueAfterAuthorization(
    _ status: SFSpeechRecognizerAuthorizationStatus,
    generation: Int,
    fileURL: URL,
    locale: Locale
  ) {
    guard isActive(generation) else {
      return
    }
    switch status {
    case .authorized:
      beginRecognition(generation: generation, fileURL: fileURL, locale: locale)
    case .denied:
      finish(
        generation,
        value: Self.error("denied", "Speech recognition permission was denied"),
        cancelRecognition: false
      )
    case .restricted:
      finish(
        generation,
        value: Self.error("restricted", "Speech recognition is restricted"),
        cancelRecognition: false
      )
    case .notDetermined:
      requestAuthorization { [weak self] newStatus in
        Self.performOnMain {
          self?.continueAfterAuthorization(
            newStatus,
            generation: generation,
            fileURL: fileURL,
            locale: locale
          )
        }
      }
    @unknown default:
      finish(
        generation,
        value: Self.error("unavailable", "Speech recognition is unavailable"),
        cancelRecognition: false
      )
    }
  }

  private func beginRecognition(
    generation: Int,
    fileURL: URL,
    locale: Locale
  ) {
    do {
      let request = makeRequest(fileURL)
      let cancellation = try startRecognition(request, locale) {
        [weak self] text, isFinal, error in
        Self.performOnMain {
          self?.receiveRecognition(
            text: text,
            isFinal: isFinal,
            error: error,
            generation: generation
          )
        }
      }
      setRecognitionCancellation(cancellation, generation: generation)
    } catch StartError.unavailable {
      finish(
        generation,
        value: Self.error("unavailable", "On-device recognition is unavailable"),
        cancelRecognition: false
      )
    } catch {
      finish(
        generation,
        value: Self.error("failed", error.localizedDescription),
        cancelRecognition: false
      )
    }
  }

  private func receiveRecognition(
    text: String?,
    isFinal: Bool,
    error: Error?,
    generation: Int
  ) {
    guard isActive(generation) else {
      return
    }
    if let error {
      finish(
        generation,
        value: Self.error("failed", error.localizedDescription),
        cancelRecognition: true
      )
      return
    }
    guard isFinal else {
      return
    }
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      finish(
        generation,
        value: Self.error("failed", "Speech recognition returned no text"),
        cancelRecognition: false
      )
      return
    }
    finish(generation, value: text, cancelRecognition: false)
  }

  private func setRecognitionCancellation(
    _ cancellation: @escaping () -> Void,
    generation: Int
  ) {
    guard var attempt = active, attempt.generation == generation else {
      cancellation()
      return
    }
    attempt.cancelRecognition = cancellation
    active = attempt
  }

  private func setTimeoutCancellation(
    _ cancellation: @escaping () -> Void,
    generation: Int
  ) {
    guard var attempt = active, attempt.generation == generation else {
      cancellation()
      return
    }
    attempt.cancelTimeout = cancellation
    active = attempt
  }

  private func finish(
    _ generation: Int,
    value: Any?,
    cancelRecognition: Bool
  ) {
    guard let attempt = active, attempt.generation == generation else {
      return
    }
    active = nil
    attempt.cancelTimeout?()
    if cancelRecognition {
      attempt.cancelRecognition?()
    }
    attempt.result(value)
  }

  private func cancelActive(message: String) {
    guard let attempt = active else {
      return
    }
    active = nil
    attempt.cancelTimeout?()
    attempt.cancelRecognition?()
    attempt.result(Self.error("cancelled", message))
  }

  private func isActive(_ generation: Int) -> Bool {
    return active?.generation == generation
  }

  private func validatedFileURL(_ path: String) -> URL? {
    guard path.hasPrefix("/") else {
      return nil
    }
    let root = allowedRootURL.standardizedFileURL.resolvingSymlinksInPath()
    let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    let rootComponents = root.pathComponents
    let fileComponents = file.pathComponents
    guard fileComponents.count > rootComponents.count,
          Array(fileComponents.prefix(rootComponents.count)) == rootComponents
    else {
      return nil
    }
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
          !isDirectory.boolValue,
          FileManager.default.isReadableFile(atPath: file.path),
          (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    else {
      return nil
    }
    return file
  }

  private func validatedLocale(_ value: Any?) -> Locale? {
    guard let value else {
      return Locale.current
    }
    guard let identifier = value as? String,
          !identifier.isEmpty,
          identifier.utf8.count <= 128
    else {
      return nil
    }
    return Locale(identifier: identifier)
  }

  private func validatedTimeout(_ value: Any?) -> TimeInterval? {
    let milliseconds: Int
    if value == nil {
      milliseconds = 60_000
    } else if let value = value as? Int {
      milliseconds = value
    } else {
      return nil
    }
    guard (1_000...300_000).contains(milliseconds) else {
      return nil
    }
    return TimeInterval(milliseconds) / 1_000
  }

  static func makeOnDeviceRequest(
    fileURL: URL
  ) -> SFSpeechURLRecognitionRequest {
    let request = SFSpeechURLRecognitionRequest(url: fileURL)
    request.requiresOnDeviceRecognition = true
    // Talk iOS 2d31eda requests partials. This channel returns only final text
    // because the current UI exposes spinner/cancel, not streaming text.
    request.shouldReportPartialResults = true
    return request
  }

  /// The UI language comes first, but iOS ships on-device models for only a
  /// few languages, so a Czech UI would otherwise never transcribe anything.
  /// The device's own language list is the next best guess at what the
  /// speaker used; audio never leaves the phone either way.
  static func onDeviceRecognizer(preferring locale: Locale) -> SFSpeechRecognizer? {
    var candidates = [locale.identifier]
    candidates.append(contentsOf: Locale.preferredLanguages)
    candidates.append(Locale.current.identifier)
    var seen = Set<String>()
    for identifier in candidates where seen.insert(identifier).inserted {
      guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
            recognizer.isAvailable,
            recognizer.supportsOnDeviceRecognition
      else { continue }
      return recognizer
    }
    return nil
  }

  private static func startOnDeviceRecognition(
    request: SFSpeechURLRecognitionRequest,
    locale: Locale,
    callback: @escaping RecognitionCallback
  ) throws -> () -> Void {
    guard let recognizer = onDeviceRecognizer(preferring: locale) else {
      throw StartError.unavailable
    }
    var task: SFSpeechRecognitionTask?
    task = recognizer.recognitionTask(with: request) { result, error in
      callback(
        result?.bestTranscription.formattedString,
        result?.isFinal ?? false,
        error
      )
    }
    return {
      task?.cancel()
      _ = recognizer
    }
  }

  private static func scheduleOnMainQueue(
    interval: TimeInterval,
    action: @escaping () -> Void
  ) -> () -> Void {
    let work = DispatchWorkItem(block: action)
    DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    return { work.cancel() }
  }

  private static func performOnMain(_ action: @escaping () -> Void) {
    if Thread.isMainThread {
      action()
    } else {
      DispatchQueue.main.async(execute: action)
    }
  }

  private static func error(_ code: String, _ message: String) -> FlutterError {
    return FlutterError(code: code, message: message, details: nil)
  }
}
