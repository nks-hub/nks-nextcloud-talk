import Cocoa
import FlutterMacOS

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
class AppDelegate: FlutterAppDelegate {
  let deepLinks = AppleDeepLinkDelivery()

  override func applicationDidFinishLaunching(_ notification: Notification) {
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
}
