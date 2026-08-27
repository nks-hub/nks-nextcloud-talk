import Foundation

/// Holds the APNs device token and incoming notifications until Flutter is
/// ready for them.
///
/// The system hands the token over whenever it feels like it, which is
/// routinely before the Dart side exists. Queueing here keeps the ordering the
/// registration depends on: the token is delivered exactly once as the launch
/// value, and anything that arrives afterwards is emitted in order. The shape
/// deliberately mirrors `AppleDeepLinkDelivery`, which solves the same problem
/// for links.
final class ApplePushDelivery {
  private static let maximumPendingNotifications = 16

  private var launchToken: String?
  private var launchTokenWasTaken = false
  private var pendingNotifications: [[String: Any]] = []
  private var emitToken: ((String) -> Void)?
  private var emitNotification: (([String: Any]) -> Void)?

  func attach(
    onToken: @escaping (String) -> Void,
    onNotification: @escaping ([String: Any]) -> Void
  ) {
    emitToken = onToken
    emitNotification = onNotification
    deliverPendingIfReady()
  }

  /// Records a freshly issued device token.
  ///
  /// APNs reissues the token on restore and on reinstall, so a later token
  /// replaces the earlier one rather than queueing behind it: registering the
  /// stale one would send notifications to a device that no longer listens.
  func registered(deviceToken: Data) {
    let hex = Self.hexString(from: deviceToken)
    if !launchTokenWasTaken {
      launchToken = hex
      return
    }
    emitToken?(hex)
  }

  func received(notification payload: [String: Any]) {
    guard let subject = payload["subject"] as? String, !subject.isEmpty else {
      return
    }
    let message: [String: Any] = ["subject": subject]
    if launchTokenWasTaken, let emitNotification {
      emitNotification(message)
      return
    }
    if pendingNotifications.count == Self.maximumPendingNotifications {
      pendingNotifications.removeFirst()
    }
    pendingNotifications.append(message)
  }

  func takeLaunchToken() -> String? {
    launchTokenWasTaken = true
    let result = launchToken
    launchToken = nil
    deliverPendingIfReady()
    return result
  }

  private func deliverPendingIfReady() {
    guard launchTokenWasTaken, let emitNotification else {
      return
    }
    let queued = pendingNotifications
    pendingNotifications.removeAll(keepingCapacity: true)
    for notification in queued {
      emitNotification(notification)
    }
  }

  /// APNs hands the token over as raw bytes; Nextcloud wants the lowercase hex
  /// form, and its SHA-512 is what the push registration sends.
  static func hexString(from token: Data) -> String {
    token.map { String(format: "%02x", $0) }.joined()
  }
}

/// Holds notification routes until Flutter has installed its channel handler.
///
/// A route is always account-scoped by the private key that decrypted the
/// payload. Keeping the cold-launch item separate from later opens preserves
/// platform ordering without ever reconstructing an account from a server
/// host.
final class ApplePushNotificationOpenDelivery {
  private static let maximumPendingOpens = 16

  private var launchOpen: [String: Any]?
  private var launchOpenWasTaken = false
  private var pendingOpens: [[String: Any]] = []
  private var emit: (([String: Any]) -> Void)?

  func attach(_ emit: @escaping ([String: Any]) -> Void) {
    self.emit = emit
    deliverPendingOpensIfReady()
  }

  func enqueue(accountId: String, roomToken: String) {
    let payload: [String: Any] = ["accountId": accountId, "roomToken": roomToken]
    if !launchOpenWasTaken, launchOpen == nil {
      launchOpen = payload
      return
    }
    if let emit {
      emit(payload)
      return
    }
    if pendingOpens.count == Self.maximumPendingOpens {
      pendingOpens.removeFirst()
    }
    pendingOpens.append(payload)
  }

  func takeLaunchOpen() -> [String: Any]? {
    launchOpenWasTaken = true
    let result = launchOpen
    launchOpen = nil
    deliverPendingOpensIfReady()
    return result
  }

  private func deliverPendingOpensIfReady() {
    guard launchOpenWasTaken, let emit else {
      return
    }
    let opens = pendingOpens
    pendingOpens.removeAll(keepingCapacity: true)
    for open in opens {
      emit(open)
    }
  }
}

/// Keeps Reply and Mark-as-read alive across a cold launch until Dart can run
/// the account-scoped operation.
///
/// The OS completion handler is released only after Flutter acknowledges the
/// method call. If the bounded queue overflows, the oldest handler is
/// completed before its action is discarded so the system is never left
/// waiting indefinitely.
private final class CompletionGate {
  private let lock = NSLock()
  private let completion: () -> Void
  private var timeoutCancellation: (() -> Void)?
  private var isComplete = false

  init(completion: @escaping () -> Void) {
    self.completion = completion
  }

  func setTimeoutCancellation(_ cancellation: @escaping () -> Void) {
    lock.lock()
    if isComplete {
      lock.unlock()
      cancellation()
      return
    }
    timeoutCancellation = cancellation
    lock.unlock()
  }

  func complete() {
    lock.lock()
    guard !isComplete else {
      lock.unlock()
      return
    }
    isComplete = true
    let cancellation = timeoutCancellation
    timeoutCancellation = nil
    lock.unlock()

    cancellation?()
    completion()
  }
}

final class ApplePushNotificationActionDelivery {
  typealias Emit = ([String: Any], @escaping () -> Void) -> Void
  typealias Schedule = (TimeInterval, @escaping () -> Void) -> (() -> Void)

  private let maximumPendingActions: Int
  private let completionTimeout: TimeInterval
  private let schedule: Schedule
  private let lock = NSLock()

  private struct PendingAction {
    let id: UUID
    let payload: [String: Any]
    let completionGate: CompletionGate
  }

  private var pendingActions: [PendingAction] = []
  private var emit: Emit?
  private var flutterIsReady = false

  convenience init() {
    self.init(
      maximumPendingActions: 16,
      completionTimeout: 20,
      schedule: Self.scheduleOnMainQueue
    )
  }

  init(
    maximumPendingActions: Int,
    completionTimeout: TimeInterval,
    schedule: @escaping Schedule
  ) {
    precondition(maximumPendingActions > 0)
    precondition(completionTimeout > 0)
    self.maximumPendingActions = maximumPendingActions
    self.completionTimeout = completionTimeout
    self.schedule = schedule
  }

  func attach(_ emit: @escaping Emit) {
    lock.lock()
    self.emit = emit
    lock.unlock()
    deliverPendingActionsIfReady()
  }

  func markFlutterReady() {
    lock.lock()
    flutterIsReady = true
    lock.unlock()
    deliverPendingActionsIfReady()
  }

  private func deliverPendingActionsIfReady() {
    lock.lock()
    guard flutterIsReady, let emit else {
      lock.unlock()
      return
    }
    let actions = pendingActions
    pendingActions.removeAll(keepingCapacity: true)
    lock.unlock()
    for action in actions {
      emit(action.payload) {
        action.completionGate.complete()
      }
    }
  }

  func enqueue(
    kind: String,
    accountId: String,
    roomToken: String,
    replyText: String?,
    completion: @escaping () -> Void
  ) {
    var payload: [String: Any] = [
      "kind": kind,
      "accountId": accountId,
      "roomToken": roomToken,
    ]
    if let replyText {
      payload["replyText"] = replyText
    }

    let action = PendingAction(
      id: UUID(),
      payload: payload,
      completionGate: CompletionGate(completion: completion)
    )
    var immediateEmit: Emit?
    var evictedAction: PendingAction?

    lock.lock()
    if flutterIsReady, let emit {
      immediateEmit = emit
    } else {
      if pendingActions.count == maximumPendingActions {
        evictedAction = pendingActions.removeFirst()
      }
      pendingActions.append(action)
    }
    lock.unlock()

    evictedAction?.completionGate.complete()
    let cancelTimeout = schedule(completionTimeout) { [weak self] in
      self?.removePendingAction(id: action.id)
      action.completionGate.complete()
    }
    action.completionGate.setTimeoutCancellation(cancelTimeout)
    immediateEmit?(payload) {
      action.completionGate.complete()
    }
  }

  private func removePendingAction(id: UUID) {
    lock.lock()
    pendingActions.removeAll { $0.id == id }
    lock.unlock()
  }

  private static func scheduleOnMainQueue(
    after delay: TimeInterval,
    action: @escaping () -> Void
  ) -> () -> Void {
    let workItem = DispatchWorkItem(block: action)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    return { workItem.cancel() }
  }
}
