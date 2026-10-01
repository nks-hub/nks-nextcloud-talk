import Cocoa
import FlutterMacOS
import Sparkle

final class DesktopUpdater: NSObject, SPUUpdaterDelegate {
  private let channel: FlutterMethodChannel
  private var updater: SPUUpdater?
  private var completion: FlutterResult?
  private var requestedBuild: String?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "com.nkshub.nextcloudtalk/updater", binaryMessenger: messenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "install" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self else { return }
      guard let arguments = call.arguments as? [String: Any],
            let build = arguments["build"] as? Int, build > 0 else {
        result(FlutterError(code: "invalid-build", message: "Invalid update version.", details: nil))
        return
      }
      self.install(build: build, result: result)
    }
  }

  private func install(build: Int, result: @escaping FlutterResult) {
    guard completion == nil else {
      result(FlutterError(code: "update-busy", message: "An update is already running.", details: nil))
      return
    }
    completion = result
    requestedBuild = String(build)
    if updater == nil {
      let driver = DesktopUpdateUserDriver(hostBundle: .main, delegate: nil)
      updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
      do {
        try updater!.start()
      } catch {
        updater = nil
        finish(error: error)
        return
      }
    }
    updater!.checkForUpdates()
  }

  func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
    appcast.items.first { $0.versionString == requestedBuild } ?? SUAppcastItem.empty()
  }

  func updater(
    _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?
  ) {
    // A successful install terminates this process. A completed cycle here was cancelled or failed.
    finish(error: error)
  }

  private func finish(error: Error?) {
    let result = completion
    completion = nil
    requestedBuild = nil
    if let error {
      NSLog("Desktop update failed: %@", error.localizedDescription)
      result?(FlutterError(code: "update-failed", message: error.localizedDescription, details: nil))
    } else {
      result?("cancelled")
    }
  }
}

private final class DesktopUpdateUserDriver: SPUStandardUserDriver {
  // The Flutter update button already authorizes downloading, installing and relaunching.
  override func showUpdateFound(
    with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
    reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    reply(.install)
  }

  override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    reply(.install)
  }
}
