import AVFoundation
import CallKit
import Flutter
import Foundation
import PushKit

#if canImport(WebRTC)
  import WebRTC
#endif

/// PushKit and CallKit: an incoming Talk call rings the system's own call UI
/// even when the app is not running at all.
///
/// A VoIP push is the only wake-up iOS delivers to a terminated app, and
/// since iOS 13 it comes with a hard rule — the process MUST report an
/// incoming call to CallKit from inside `didReceiveIncomingPushWith`, or the
/// system kills it and eventually stops delivering VoIP pushes to this app
/// entirely. So every push reports a call, including one that cannot be
/// decrypted: that one rings as an unnamed caller rather than costing the app
/// its PushKit registration.
///
/// The token is a second device token, distinct from the ordinary APNs one
/// and useless in its place; `nks-talk-notify` stores it beside the other and
/// picks it for `type=voip` pushes. Both are needed, which is why this
/// delivers its token the same queue-until-Dart-is-ready way
/// `ApplePushDelivery` delivers the ordinary one.
final class CallPushKit: NSObject {
  static let channelName = "com.nkshub.nextcloudtalk/call_kit"

  private let registry: PKPushRegistry
  private let provider: CXProvider
  private let callController = CXCallController()
  private var channel: FlutterMethodChannel?

  private var launchToken: String?
  private var launchTokenWasTaken = false
  /// The call each CallKit UUID stands for, so an answer knows what to join.
  private var routes: [UUID: [String: Any]] = [:]

  override init() {
    registry = PKPushRegistry(queue: .main)
    let configuration = CXProviderConfiguration()
    configuration.supportsVideo = true
    configuration.maximumCallsPerCallGroup = 1
    configuration.maximumCallGroups = 1
    // A Talk room token is not a phone number and not an address book entry;
    // `generic` is what CallKit offers for exactly that.
    configuration.supportedHandleTypes = [.generic]
    provider = CXProvider(configuration: configuration)
    super.init()
    provider.setDelegate(self, queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
  }

  /// Wires the Dart side up. Called again on every engine restart, which is
  /// why the token is replayed rather than assumed delivered.
  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "getVoipToken":
        result(self.takeLaunchToken())
      case "endCall":
        self.endCall(call.arguments)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  func dispose() {
    channel?.setMethodCallHandler(nil)
    channel = nil
  }

  private func takeLaunchToken() -> String? {
    launchTokenWasTaken = true
    let token = launchToken
    launchToken = nil
    return token
  }

  /// Dart asking for the ringing call to stop — the user hung up in the app,
  /// or the call ended on the server while the system UI still showed it.
  private func endCall(_ arguments: Any?) {
    guard let raw = (arguments as? [String: Any])?["callId"] as? String,
      let uuid = UUID(uuidString: raw)
    else {
      return
    }
    routes[uuid] = nil
    provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
  }

  private func emit(_ method: String, _ arguments: [String: Any]) {
    guard let channel else {
      return
    }
    channel.invokeMethod(method, arguments: arguments)
  }
}

// MARK: - PushKit

extension CallPushKit: PKPushRegistryDelegate {
  func pushRegistry(
    _ registry: PKPushRegistry,
    didUpdate credentials: PKPushCredentials,
    for type: PKPushType
  ) {
    guard type == .voIP, !credentials.token.isEmpty else {
      return
    }
    let hex = ApplePushDelivery.hexString(from: credentials.token)
    if launchTokenWasTaken {
      emit("voipTokenChanged", ["token": hex])
    } else {
      launchToken = hex
    }
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didInvalidatePushTokenFor type: PKPushType
  ) {
    // Nothing to unregister on our side: the proxy forgets a dead VoIP token
    // by itself when APNs refuses it, and the next registration brings a new
    // one. Losing the token must not lose the ordinary push registration.
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    let route = Self.route(from: payload)
    let uuid = UUID()
    let update = CXCallUpdate()
    update.hasVideo = false
    update.supportsDTMF = false
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.localizedCallerName = route?["callerName"] as? String
    update.remoteHandle = CXHandle(
      type: .generic,
      value: (route?["roomToken"] as? String) ?? "talk"
    )
    if var route {
      route["callId"] = uuid.uuidString
      routes[uuid] = route
    }
    provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
      if error != nil {
        // Reporting failed (Do Not Disturb, a blocked caller, an app the user
        // revoked the entitlement from). The call simply does not ring; there
        // is nothing to join, so the route goes with it.
        self?.routes[uuid] = nil
      }
      completion()
    }
  }

  /// The account and room a VoIP push names, or nil when nothing in it
  /// decrypts to a Talk call.
  ///
  /// Reads the same `nc-subject` envelope the Notification Service Extension
  /// does, with the same fail-closed rule: exactly one candidate key must
  /// produce a valid payload, and the payload must actually say `call`.
  private static func route(from payload: PKPushPayload) -> [String: Any]? {
    guard let subject = payload.dictionaryPayload["nc-subject"] as? String,
      let ciphertext = Data(base64Encoded: subject)
    else {
      return nil
    }
    let candidates = PushDeviceKeyStore.allKeys()
    guard
      let envelope = PushEnvelopeDecryptor.decodeWakeUpPayload(
        ciphertext: ciphertext,
        candidates: candidates.map(\.key)
      )
    else {
      return nil
    }
    let decoded = envelope.payload
    guard decoded["app"] as? String == "spreed",
      decoded["type"] as? String == "call",
      let roomToken = decoded["id"] as? String, !roomToken.isEmpty,
      let accountId = candidates[envelope.matchedKeyIndex].accountId
    else {
      return nil
    }
    var route: [String: Any] = ["accountId": accountId, "roomToken": roomToken]
    // push-v2 carries the ringing room's name as the push's own subject line.
    if let callerName = decoded["subject"] as? String, !callerName.isEmpty {
      route["callerName"] = callerName
    }
    if let notificationId = decoded["nid"] as? Int {
      route["notificationId"] = notificationId
    }
    return route
  }
}

// MARK: - CallKit

extension CallPushKit: CXProviderDelegate {
  func providerDidReset(_ provider: CXProvider) {
    routes.removeAll()
    emit("callEnded", [:])
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    guard let route = routes[action.callUUID] else {
      // Nothing decrypted for this ring, so there is no room to join. Failing
      // the action is what tells CallKit to drop the call UI instead of
      // leaving it on screen over an app that will never connect.
      action.fail()
      return
    }
    emit("callAnswered", route)
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    let route = routes.removeValue(forKey: action.callUUID) ?? [:]
    emit("callEnded", route)
    action.fulfill()
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    #if canImport(WebRTC)
      // CallKit, not the app, owns the audio session for a call it presents.
      // WebRTC has to be told the moment it becomes usable, or the tracks it
      // opened stay silent for the whole call.
      RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
      RTCAudioSession.sharedInstance().isAudioEnabled = true
    #endif
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    #if canImport(WebRTC)
      RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
      RTCAudioSession.sharedInstance().isAudioEnabled = false
    #endif
  }
}
