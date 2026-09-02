import Cocoa
import FlutterMacOS
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
class AppDelegate: FlutterAppDelegate, UNUserNotificationCenterDelegate {
  static let messageCategoryIdentifier = "TALK_MESSAGE"
  static let replyActionIdentifier = "REPLY_ACTION"
  static let markReadActionIdentifier = "MARK_READ_ACTION"

  let deepLinks = AppleDeepLinkDelivery()
  let pushOpens = ApplePushNotificationOpenDelivery()
  let pushActions = ApplePushNotificationActionDelivery()
  let push = ApplePushDelivery()
  let deviceKeys = PushDeviceKeyStore()
  private var pushChannel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().delegate = self
    registerNotificationCategories()
    NSAppleEventManager.shared().setEventHandler(
      self,
      andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
      forEventClass: AEEventClass(kInternetEventClass),
      andEventID: AEEventID(kAEGetURL)
    )
  }

  override func applicationWillTerminate(_ notification: Notification) {
    NSAppleEventManager.shared().removeEventHandler(
      forEventClass: AEEventClass(kInternetEventClass),
      andEventID: AEEventID(kAEGetURL)
    )
  }

  @objc private func handleGetURLEvent(
    _ event: NSAppleEventDescriptor,
    withReplyEvent replyEvent: NSAppleEventDescriptor
  ) {
    guard let rawURL = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
          let url = URL(string: rawURL)
    else {
      return
    }
    _ = deepLinks.open(url)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  func configurePushChannel(binaryMessenger: FlutterBinaryMessenger) {
    guard pushChannel == nil else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "com.nkshub.nextcloudtalk/apple_push",
      binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "requestPermission":
        self?.requestNotificationPermission(result)
      case "getDeviceToken":
        result(self?.push.takeLaunchToken())
      case "generateDeviceKey":
        self?.generateDeviceKey(call.arguments, result)
      case "destroyDeviceKey":
        self?.destroyDeviceKey(call.arguments, result)
      case "recordDeviceKeyAccount":
        self?.recordDeviceKeyAccount(call.arguments, result)
      case "showLocalNotification":
        self?.showLocalNotification(call.arguments, result)
      case "getLaunchNotificationOpen":
        let open = self?.pushOpens.takeLaunchOpen()
        result(open)
        self?.pushActions.markFlutterReady()
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    push.attach(
      onToken: { [weak channel] token in
        channel?.invokeMethod("deviceTokenChanged", arguments: token)
      },
      onNotification: { [weak channel] payload in
        channel?.invokeMethod("notificationReceived", arguments: payload)
      }
    )
    pushOpens.attach { [weak channel] payload in
      channel?.invokeMethod("notificationOpened", arguments: payload)
    }
    pushActions.attach { [weak channel] payload, completion in
      guard let channel else {
        completion()
        return
      }
      channel.invokeMethod("notificationAction", arguments: payload) { _ in
        completion()
      }
    }
    pushChannel = channel
  }

  /// Raises a Talk message as a local notification.
  ///
  /// macOS never receives a Talk push: Nextcloud maps only the Android and iOS
  /// user agents to `apptype='talk'`, and its proxy filter hands a desktop
  /// client nothing whenever the account has any phone registered. Client Push
  /// keeps this app in sync over its websocket, so the message is already here
  /// - this is what finally tells the user about it. Windows has had the same
  /// thing since build 45; the route store is shared with push so the Reply and
  /// Mark as Read actions need no separate plumbing.
  private func showLocalNotification(_ arguments: Any?, _ result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
      let accountId = args["accountId"] as? String, !accountId.isEmpty,
      let roomToken = args["roomToken"] as? String, !roomToken.isEmpty,
      let title = args["title"] as? String,
      let body = args["body"] as? String
    else {
      result(false)
      return
    }
    let identifier = "local-\(UUID().uuidString)"
    guard
      PushNotificationRouteStore.production.remember(
        identifier: identifier,
        route: PushNotificationRouteStore.Route(accountId: accountId, roomToken: roomToken)
      )
    else {
      result(false)
      return
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.categoryIdentifier = Self.messageCategoryIdentifier
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    ) { error in
      DispatchQueue.main.async { result(error == nil) }
    }
  }

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
          NSApplication.shared.registerForRemoteNotifications()
        }
        result(granted)
      }
    }
  }

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

  private func recordDeviceKeyAccount(_ arguments: Any?, _ result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
      let handle = args["handle"] as? String, !handle.isEmpty,
      let accountId = args["accountId"] as? String, !accountId.isEmpty
    else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "Missing handle or accountId",
          details: nil
        )
      )
      return
    }
    do {
      try deviceKeys.setAccount(handle: handle, accountId: accountId)
      result(nil)
    } catch {
      result(
        FlutterError(
          code: "account_update_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  override func application(
    _ application: NSApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    push.registered(deviceToken: deviceToken)
  }

  override func application(
    _ application: NSApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    #if DEBUG
      NSLog("APNs registration failed: %@", error.localizedDescription)
    #endif
  }

  override func application(
    _ application: NSApplication,
    didReceiveRemoteNotification userInfo: [String: Any]
  ) {
    push.received(notification: userInfo)
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .badge, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let route = PushNotificationRouteStore.production.take(
      identifier: response.notification.request.identifier
    )
    switch response.actionIdentifier {
    case Self.replyActionIdentifier, Self.markReadActionIdentifier:
      guard let route else {
        completionHandler()
        return
      }
      let kind = response.actionIdentifier == Self.replyActionIdentifier ? "reply" : "markRead"
      let replyText = (response as? UNTextInputNotificationResponse)?.userText
      pushActions.enqueue(
        kind: kind,
        accountId: route.accountId,
        roomToken: route.roomToken,
        replyText: replyText,
        completion: completionHandler
      )
    default:
      if let route {
        pushOpens.enqueue(accountId: route.accountId, roomToken: route.roomToken)
      }
      completionHandler()
    }
  }
}
