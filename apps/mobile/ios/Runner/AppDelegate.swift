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
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Routes a tapped push notification to the conversation it decrypted to,
  /// by replaying it through the same `AppleDeepLinkDelivery` queue a
  /// universal link would use — cold start included, since that queue
  /// already handles "opened before the Flutter engine exists".
  ///
  /// The room token only exists because the Notification Service Extension
  /// decrypted it and stashed it in `PushNotificationRouteStore`
  /// (`content.userInfo` cannot carry it — see that type's doc comment). A
  /// push with no matching route (decrypt failed, or this build predates
  /// route tracking) is silently not routed rather than treated as an error.
  ///
  /// `FlutterAppDelegate` already conforms to `UNUserNotificationCenterDelegate`
  /// and forwards this to any plugin that registered for it, so this override
  /// does its own routing first and then defers to `super` for that
  /// forwarding and the single `completionHandler()` call, instead of also
  /// calling it here.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let route = PushNotificationRouteStore.take(
      identifier: response.notification.request.identifier
    ),
      let url = URL(string: "https://\(route.host)/call/\(route.roomToken)")
    {
      _ = deepLinks.open(url)
    }
    super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
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
