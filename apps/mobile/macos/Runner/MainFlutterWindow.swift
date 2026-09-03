import Cocoa
import FlutterMacOS
import ServiceManagement

/// Smallest window the adaptive layout is designed for, in points.
/// Keep in sync with the Windows and Linux runners.
private let minimumWindowWidth: CGFloat = 600
private let minimumWindowHeight: CGFloat = 400

/// Key AppKit stores the window frame under between launches.
private let windowFrameAutosaveName = "NKSTalkMainWindow"

class MainFlutterWindow: NSWindow {
  private var deepLinkChannel: FlutterMethodChannel?
  private var desktopAutostartChannel: FlutterMethodChannel?

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
    //
    // Measured on macOS 14 (setFrame call stacks): the autosave frame was
    // applied and then overwritten by `-[NSWindow restoreStateWithCoder:]`,
    // AppKit's window-state resume, which keeps its own copy of the frame
    // and knows nothing about `minSize`. The saved frame in defaults is the
    // one source of truth here, so state restoration is off for this window
    // and the restore is explicit — `setFrameUsingName` does not clamp to
    // the minimum either, hence the clamp by hand.
    self.isRestorable = false
    self.setFrameAutosaveName(windowFrameAutosaveName)
    if self.setFrameUsingName(windowFrameAutosaveName) {
      var restored = self.frame
      restored.size.width = max(restored.width, minimumWindowWidth)
      restored.size.height = max(restored.height, minimumWindowHeight)
      self.setFrame(restored, display: true)
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    let desktopAutostartChannel = FlutterMethodChannel(
      name: "com.nkshub.nextcloudtalk/desktop_autostart",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    desktopAutostartChannel.setMethodCallHandler { call, result in
      if call.method == "isSupported" {
        if #available(macOS 13.0, *) {
          result(true)
        } else {
          result(false)
        }
        return
      }
      guard #available(macOS 13.0, *) else {
        result(
          FlutterError(
            code: "autostart-unsupported",
            message: "Automatic startup needs macOS 13 or newer.",
            details: nil
          )
        )
        return
      }
      let service = SMAppService.mainApp
      if call.method == "isEnabled" {
        result(service.status == .enabled)
        return
      }
      guard call.method == "setEnabled" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let enabled = arguments["enabled"] as? Bool
      else {
        result(
          FlutterError(
            code: "autostart-invalid-arguments",
            message: "The startup preference is invalid.",
            details: nil
          )
        )
        return
      }
      do {
        if enabled && service.status != .enabled {
          try service.register()
        } else if !enabled && service.status != .notRegistered {
          try service.unregister()
        }
        result(service.status == .enabled)
      } catch {
        result(
          FlutterError(
            code: "autostart-write-failed",
            message: "The desktop startup setting could not be changed.",
            details: nil
          )
        )
      }
    }
    self.desktopAutostartChannel = desktopAutostartChannel

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
