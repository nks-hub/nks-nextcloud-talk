import Cocoa
import FlutterMacOS

/// Smallest window the adaptive layout is designed for, in points.
/// Keep in sync with the Windows and Linux runners.
private let minimumWindowWidth: CGFloat = 600
private let minimumWindowHeight: CGFloat = 400

class MainFlutterWindow: NSWindow {
  private var deepLinkChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: minimumWindowWidth, height: minimumWindowHeight)
    self.title = "NKS Talk"

    RegisterGeneratedPlugins(registry: flutterViewController)

    let deepLinkChannel = FlutterMethodChannel(
      name: "com.nkshub.nextcloudtalk/deep_link",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    if let appDelegate = NSApp.delegate as? AppDelegate {
      deepLinkChannel.setMethodCallHandler { [weak appDelegate] call, result in
        guard call.method == "getLaunchLink" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let payload = appDelegate?.deepLinks.takeLaunchLink()
        #if DEBUG
          if payload != nil {
            NSLog("Launch deep link returned to Flutter")
          }
        #endif
        result(payload)
      }
      appDelegate.deepLinks.attach { [weak deepLinkChannel] payload in
        deepLinkChannel?.invokeMethod("linkOpened", arguments: payload) { response in
          #if DEBUG
            if response == nil {
              NSLog("Warm deep link acknowledged by Flutter")
            }
          #endif
        }
      }
      appDelegate.configurePushChannel(
        binaryMessenger: flutterViewController.engine.binaryMessenger
      )
    }
    self.deepLinkChannel = deepLinkChannel

    super.awakeFromNib()
  }
}
