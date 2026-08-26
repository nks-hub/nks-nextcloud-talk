import Flutter
import UIKit

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
  private var deepLinkChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
  }
}
