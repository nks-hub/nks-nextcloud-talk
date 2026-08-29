import Cocoa
import FlutterMacOS

/// Smallest window the adaptive layout is designed for, in points.
/// Keep in sync with the Windows and Linux runners.
private let minimumWindowWidth: CGFloat = 600
private let minimumWindowHeight: CGFloat = 400

/// Key AppKit stores the window frame under between launches.
private let windowFrameAutosaveName = "NKSTalkMainWindow"

class MainFlutterWindow: NSWindow {
  private var deepLinkChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: minimumWindowWidth, height: minimumWindowHeight)
    self.title = "NKS Talk"
    // Remember where the window was left. AppKit stores the frame under this
    // name in the user's defaults and restores it on the next launch, which
    // is what the Windows runner does through its own saved bounds; without
    // it macOS opened at the nib's size every time.
    //
    // Set after `minSize` on purpose: a restored frame smaller than the
    // minimum is clamped to it rather than reopening a window the adaptive
    // layout cannot fill.
    self.setFrameAutosaveName(windowFrameAutosaveName)

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
