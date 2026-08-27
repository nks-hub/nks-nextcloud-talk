import Flutter
import UIKit
import UserNotifications

final class AppleDeepLinkDelivery {
  private static let maximumPendingLinks = 16

  private var launchLink: [String: Any]?
  private var launchLinkWasTaken = false
  private var pendingLinks: [[String: Any]] = []
  private var emit: (([String: Any]) -> Void)?

  func attach(_ emit: @escaping ([String: Any]) -> Void) {
    self.emit = emit
    deliverPendingLinksIfReady()
  }

  func open(_ url: URL) -> Bool {
    guard let payload = payload(for: url) else {
      return false
    }

    if !launchLinkWasTaken, launchLink == nil {
      launchLink = payload
      return true
    }
    if let emit {
      emit(payload)
      return true
    }
    if pendingLinks.count == Self.maximumPendingLinks {
      pendingLinks.removeFirst()
    }
    pendingLinks.append(payload)
    return true
  }

  func takeLaunchLink() -> [String: Any]? {
    launchLinkWasTaken = true
    let result = launchLink
    launchLink = nil
    deliverPendingLinksIfReady()
    return result
  }

  private func deliverPendingLinksIfReady() {
    guard launchLinkWasTaken, let emit else {
      return
    }
    let links = pendingLinks
    pendingLinks.removeAll(keepingCapacity: true)
    for link in links {
      emit(link)
    }
  }

  private func payload(for incomingURL: URL) -> [String: Any]? {
    let targetURL: URL
    if incomingURL.scheme?.lowercased() == "nctalk" {
      guard incomingURL.host?.lowercased() == "open",
            let components = URLComponents(url: incomingURL, resolvingAgainstBaseURL: false),
            let rawTarget = components.queryItems?.first(where: { $0.name == "uri" })?.value,
            let wrappedTarget = URL(string: rawTarget)
      else {
        return nil
      }
      targetURL = wrappedTarget
    } else {
      targetURL = incomingURL
    }

    guard targetURL.scheme?.lowercased() == "https",
          targetURL.host?.isEmpty == false,
          targetURL.user == nil,
          targetURL.password == nil
    else {
      return nil
    }
    return ["uri": targetURL.absoluteString]
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Matches `NotificationService.swift`'s `content.categoryIdentifier`,
  /// which is how iOS knows to offer these two actions on a Talk chat
  /// notification's banner/long-press instead of showing no actions at all.
  static let messageCategoryIdentifier = "TALK_MESSAGE"
  static let replyActionIdentifier = "REPLY_ACTION"
  static let markReadActionIdentifier = "MARK_READ_ACTION"

  let deepLinks = AppleDeepLinkDelivery()
  let push = ApplePushDelivery()
  let deviceKeys = PushDeviceKeyStore()
  private var deepLinkChannel: FlutterMethodChannel?
  private var pushChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Must be set before `super`'s own launch handling returns, so a tap
    // that cold-launched the app is not delivered before anything is
    // listening for it — iOS holds it until a delegate exists.
    UNUserNotificationCenter.current().delegate = self
    registerNotificationCategories()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Registering ahead of time (rather than only when permission is granted)
  /// costs nothing and means a category is never missing because of
  /// ordering — `UNUserNotificationCenter.setNotificationCategories` is safe
  /// to call before authorization is requested.
  private func registerNotificationCategories() {
    let reply = UNTextInputNotificationAction(
      identifier: Self.replyActionIdentifier,
      title: NSLocalizedString("Reply", comment: "Notification action"),
      options: [.authenticationRequired]
    )
    let markRead = UNNotificationAction(
      identifier: Self.markReadActionIdentifier,
      title: NSLocalizedString("Mark as Read", comment: "Notification action"),
      options: []
    )
    let category = UNNotificationCategory(
      identifier: Self.messageCategoryIdentifier,
      actions: [reply, markRead],
      intentIdentifiers: [],
      options: []
    )
    UNUserNotificationCenter.current().setNotificationCategories([category])
  }

  /// Routes a tapped push notification to the conversation it decrypted to,
  /// by replaying it through the same `AppleDeepLinkDelivery` queue a
  /// universal link would use — cold start included, since that queue
  /// already handles "opened before the Flutter engine exists" — or, for the
  /// Reply/Mark-as-read banner actions, hands the action straight to Dart.
  ///
  /// The room token only exists because the Notification Service Extension
  /// decrypted it and stashed it in `PushNotificationRouteStore`
  /// (`content.userInfo` cannot carry it — see that type's doc comment). A
  /// push with no matching route (decrypt failed, or this build predates
  /// route tracking) is silently not routed rather than treated as an error.
  ///
  /// `FlutterAppDelegate` already conforms to `UNUserNotificationCenterDelegate`
  /// and forwards this to any plugin that registered for it, so a plain tap
  /// does its own routing first and then defers to `super` for that
  /// forwarding and the single `completionHandler()` call, instead of also
  /// calling it here. A Reply/Mark-as-read action instead waits for Dart to
  /// finish before calling the completion handler at all — iOS gives this
  /// method a limited window to keep the app alive for exactly that, and
  /// letting `super` release the handler immediately risked the process
  /// being suspended before the reply actually sent.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let route = PushNotificationRouteStore.take(
      identifier: response.notification.request.identifier
    )
    let url = route.flatMap { URL(string: "https://\($0.host)/call/\($0.roomToken)") }

    switch response.actionIdentifier {
    case Self.replyActionIdentifier, Self.markReadActionIdentifier:
      guard let url, let pushChannel else {
        completionHandler()
        return
      }
      let kind = response.actionIdentifier == Self.replyActionIdentifier ? "reply" : "markRead"
      let replyText = (response as? UNTextInputNotificationResponse)?.userText
      pushChannel.invokeMethod(
        "notificationAction",
        arguments: [
          "kind": kind,
          "uri": url.absoluteString,
          "replyText": replyText as Any,
        ]
      ) { _ in
        completionHandler()
      }
    default:
      if let url {
        _ = deepLinks.open(url)
      }
      super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
    }
  }

  /// Suppresses the foreground banner for a push that Client Push (the
  /// notify_push websocket, see `ClientPushCoordinator`) already caused the
  /// app to sync moments earlier — otherwise the user sees the same message
  /// announced twice while the app is open. The decision itself lives in
  /// Dart (`ForegroundPushDeduplicator`), since Client Push's wake-ups are
  /// Dart-side and this native layer has no view of them on its own.
  ///
  /// Deferring to `super` on every path except "suppress" — rather than
  /// deciding the presentation options here — keeps whatever Flutter's own
  /// default and any other registered plugin would otherwise do; this only
  /// ever intervenes to say "not this one".
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    guard let pushChannel else {
      super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
      return
    }
    pushChannel.invokeMethod("shouldSuppressForegroundNotification", arguments: nil) { response in
      if (response as? Bool) == true {
        completionHandler([])
      } else {
        super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
      }
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "com.nkshub.nextcloudtalk/deep_link",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "getLaunchLink" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let payload = self?.deepLinks.takeLaunchLink()
      #if DEBUG
        if payload != nil {
          NSLog("Launch deep link returned to Flutter")
        }
      #endif
      result(payload)
    }
    deepLinks.attach { [weak channel] payload in
      channel?.invokeMethod("linkOpened", arguments: payload) { response in
        #if DEBUG
          if response == nil {
            NSLog("Warm deep link acknowledged by Flutter")
          }
        #endif
      }
    }
    deepLinkChannel = channel

    let pushMethods = FlutterMethodChannel(
      name: "com.nkshub.nextcloudtalk/apple_push",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    pushMethods.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "requestPermission":
        self?.requestNotificationPermission(result)
      case "getDeviceToken":
        result(self?.push.takeLaunchToken())
      case "generateDeviceKey":
        self?.generateDeviceKey(call.arguments, result)
      case "destroyDeviceKey":
        self?.destroyDeviceKey(call.arguments, result)
      case "recordDeviceKeyHost":
        self?.recordDeviceKeyHost(call.arguments, result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    push.attach(
      onToken: { [weak pushMethods] token in
        pushMethods?.invokeMethod("deviceTokenChanged", arguments: token)
      },
      onNotification: { [weak pushMethods] payload in
        pushMethods?.invokeMethod("notificationReceived", arguments: payload)
      }
    )
    pushChannel = pushMethods
  }

  /// Asks for notification permission and, only once granted, registers with
  /// APNs.
  ///
  /// Registering without permission still yields a token but the user never
  /// sees anything, which reads as "notifications are broken" rather than
  /// "notifications are off". Reporting the decision back lets the Dart side
  /// leave the account unregistered instead of holding a token it must not use.
  private func requestNotificationPermission(_ result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .badge, .sound]
    ) { granted, error in
      DispatchQueue.main.async {
        if let error {
          result(
            FlutterError(
              code: "permission_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
          return
        }
        if granted {
          UIApplication.shared.registerForRemoteNotifications()
        }
        result(granted)
      }
    }
  }

  /// Generates (or reuses) this account's push device key and returns its
  /// public half as PEM. `arguments` must be `{"handle": String}` — an
  /// opaque, already-hashed identifier the Dart side derives from the
  /// account id, since a raw account id may contain characters a Keychain
  /// application tag should not carry.
  private func generateDeviceKey(_ arguments: Any?, _ result: @escaping FlutterResult) {
    guard let handle = (arguments as? [String: Any])?["handle"] as? String, !handle.isEmpty
    else {
      result(FlutterError(code: "invalid_arguments", message: "Missing handle", details: nil))
      return
    }
    do {
      result(try deviceKeys.ensureKey(handle: handle))
    } catch {
      result(
        FlutterError(
          code: "key_generation_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func destroyDeviceKey(_ arguments: Any?, _ result: @escaping FlutterResult) {
    guard let handle = (arguments as? [String: Any])?["handle"] as? String, !handle.isEmpty
    else {
      result(FlutterError(code: "invalid_arguments", message: "Missing handle", details: nil))
      return
    }
    deviceKeys.destroyKey(handle: handle)
    result(nil)
  }

  /// Records which Nextcloud server host owns `handle`'s device key, so the
  /// Notification Service Extension can resolve a decrypted room token back
  /// to a server. `arguments` must be `{"handle": String, "host": String}`.
  private func recordDeviceKeyHost(_ arguments: Any?, _ result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
      let handle = args["handle"] as? String, !handle.isEmpty,
      let host = args["host"] as? String, !host.isEmpty
    else {
      result(
        FlutterError(code: "invalid_arguments", message: "Missing handle or host", details: nil)
      )
      return
    }
    do {
      try deviceKeys.setHost(handle: handle, host: host)
      result(nil)
    } catch {
      result(
        FlutterError(
          code: "host_update_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    push.registered(deviceToken: deviceToken)
    super.application(
      application,
      didRegisterForRemoteNotificationsWithDeviceToken: deviceToken
    )
  }

  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler:
      @escaping (UIBackgroundFetchResult) -> Void
  ) {
    var payload: [String: Any] = [:]
    for (key, value) in userInfo {
      if let name = key as? String {
        payload[name] = value
      }
    }
    push.received(notification: payload)
    completionHandler(.noData)
  }
}
