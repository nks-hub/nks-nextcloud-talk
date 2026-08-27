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
