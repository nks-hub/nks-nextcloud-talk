import BackgroundTasks
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

    if !launchLinkWasTaken {
      if launchLink == nil {
        launchLink = payload
      } else {
        enqueuePending(payload)
      }
      return true
    }
    if let emit {
      emit(payload)
      return true
    }
    enqueuePending(payload)
    return true
  }

  private func enqueuePending(_ payload: [String: Any]) {
    if pendingLinks.count == Self.maximumPendingLinks {
      pendingLinks.removeFirst()
    }
    pendingLinks.append(payload)
  }

  func open(_ userActivity: NSUserActivity) -> Bool {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
          let url = userActivity.webpageURL
    else {
      return false
    }
    return open(url)
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
  /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
  static let backgroundDrainIdentifier = "com.nkshub.nextcloudtalk.drain"

  let deepLinks = AppleDeepLinkDelivery()
  let pushOpens = ApplePushNotificationOpenDelivery()
  let pushActions = ApplePushNotificationActionDelivery()
  let push = ApplePushDelivery()
  let deviceKeys = PushDeviceKeyStore()
  private var deepLinkChannel: FlutterMethodChannel?
  private var pushChannel: FlutterMethodChannel?
  private var contactPickerChannel: ContactPickerChannel?
  private var voiceMessageTranscriber: VoiceMessageTranscriber?
  private var incomingShareChannel: AppleIncomingShareChannel?
  private var callAudioInterruptions: CallAudioInterruptions?
  /// Built at launch, not with the engine: a VoIP push can arrive at a
  /// terminated app, and iOS requires the call to be reported to CallKit from
  /// inside that delivery — long before Flutter exists.
  let callPushKit = CallPushKit()
  private var backgroundDrainChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Must be set before `super`'s own launch handling returns, so a tap
    // that cold-launched the app is not delivered before anything is
    // listening for it — iOS holds it until a delegate exists.
    UNUserNotificationCenter.current().delegate = self
    registerNotificationCategories()
    registerBackgroundDrainTask()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// The scheduled counterpart to the app's foreground wake-ups: iOS gives a
  /// suspended app a short window every so often, and that is when queued text
  /// and interrupted uploads get their turn without the user opening the app.
  ///
  /// `BGTaskScheduler` must have its handler registered before
  /// `didFinishLaunchingWithOptions` returns, or iOS refuses the identifier
  /// for the whole launch. The identifier itself is declared in Info.plist
  /// under `BGTaskSchedulerPermittedIdentifiers`; no entitlement is involved.
  private func registerBackgroundDrainTask() {
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.backgroundDrainIdentifier,
      using: nil
    ) { [weak self] task in
      self?.runBackgroundDrain(task)
    }
  }

  /// Submits the next window. iOS collapses repeated submissions of the same
  /// identifier onto one pending request, so asking again is not a duplicate,
  /// and only the system decides when it actually runs.
  private func scheduleBackgroundDrain() {
    let request = BGAppRefreshTaskRequest(identifier: Self.backgroundDrainIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    try? BGTaskScheduler.shared.submit(request)
  }

  /// iOS only ever hands the task to a process it kept in memory, so the
  /// engine that owns the outbox is the one already here; there is no headless
  /// second engine on this platform and none is wanted. A launch that has no
  /// engine yet has nothing to drain either, and says so rather than
  /// reporting a success it did not have.
  private func runBackgroundDrain(_ task: BGTask) {
    scheduleBackgroundDrain()
    guard let channel = backgroundDrainChannel else {
      task.setTaskCompleted(success: false)
      return
    }
    var completed = false
    let complete: (Bool) -> Void = { success in
      guard !completed else { return }
      completed = true
      task.setTaskCompleted(success: success)
    }
    task.expirationHandler = { complete(false) }
    channel.invokeMethod("runDrain", arguments: nil) { response in
      complete(!(response is FlutterError))
    }
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    scheduleBackgroundDrain()
    super.applicationDidEnterBackground(application)
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
  /// via `pushOpens` (cold start included), or, for the Reply/Mark-as-read
  /// banner actions, hands the action straight to Dart — both carrying the
  /// `accountId` the Notification Service Extension already established by
  /// decrypting the push, not a host to be matched back to an account here.
  ///
  /// The route only exists because the extension decrypted it and stashed it
  /// in `PushNotificationRouteStore` (`content.userInfo` cannot carry it —
  /// see that type's doc comment). A push with no matching route (decrypt
  /// failed, or this build predates route tracking) is silently not routed
  /// rather than treated as an error.
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
        notificationId: route.notificationId,
        completion: completionHandler
      )
    default:
      if let route {
        pushOpens.enqueue(accountId: route.accountId, roomToken: route.roomToken)
      }
      super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
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

    contactPickerChannel = ContactPickerChannel(
      messenger: engineBridge.applicationRegistrar.messenger(),
      presentingViewController: ContactPickerChannel.activeViewController
    )
    voiceMessageTranscriber = VoiceMessageTranscriber(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    incomingShareChannel?.dispose()
    incomingShareChannel = AppleIncomingShareChannel(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    callAudioInterruptions?.dispose()
    callAudioInterruptions = CallAudioInterruptions(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    callPushKit.attach(messenger: engineBridge.applicationRegistrar.messenger())

    let drain = FlutterMethodChannel(
      name: "com.nkshub.nextcloudtalk/background_drain",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    drain.setMethodCallHandler { [weak self] call, result in
      guard call.method == "ensureScheduled" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.scheduleBackgroundDrain()
      result(nil)
    }
    backgroundDrainChannel = drain

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
      case "recordDeviceKeyAccount":
        self?.recordDeviceKeyAccount(call.arguments, result)
      case "getLaunchNotificationOpen":
        let open = self?.pushOpens.takeLaunchOpen()
        result(open)
        self?.pushActions.markFlutterReady()
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
    pushOpens.attach { [weak pushMethods] payload in
      pushMethods?.invokeMethod("notificationOpened", arguments: payload)
    }
    pushActions.attach { [weak pushMethods] payload, completion in
      guard let pushMethods else {
        completion()
        return
      }
      pushMethods.invokeMethod("notificationAction", arguments: payload) { _ in
        completion()
      }
    }
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

  /// Records which account owns `handle`'s device key, so the Notification
  /// Service Extension learns the account directly once a candidate key
  /// decrypts a push, instead of it being reconstructed later from a server
  /// host — which is ambiguous with two accounts on one server. `arguments`
  /// must be `{"handle": String, "accountId": String}`.
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
