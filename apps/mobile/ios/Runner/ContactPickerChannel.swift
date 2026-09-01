import Contacts
import ContactsUI
import Flutter
import UIKit

final class ContactPickerChannel: NSObject, CNContactPickerDelegate {
  static let name = "com.nkshub.nextcloudtalk/contact_picker"
  static let maximumVCardBytes = 2 * 1024 * 1024

  static func activeViewController() -> UIViewController? {
    let root = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)?
      .rootViewController
    var visible = root
    while let presented = visible?.presentedViewController {
      visible = presented
    }
    return visible
  }

  private let channel: FlutterMethodChannel?
  private let presentingViewController: () -> UIViewController?
  private var pendingResult: FlutterResult?

  init(
    messenger: FlutterBinaryMessenger,
    presentingViewController: @escaping () -> UIViewController?
  ) {
    let methodChannel = FlutterMethodChannel(
      name: Self.name,
      binaryMessenger: messenger
    )
    channel = methodChannel
    self.presentingViewController = presentingViewController
    super.init()
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  init(presentingViewController: @escaping () -> UIViewController?) {
    channel = nil
    self.presentingViewController = presentingViewController
    super.init()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "pickContact" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard pendingResult == nil else {
      result(
        FlutterError(
          code: "picker_in_progress",
          message: "A contact picker is already open.",
          details: nil
        )
      )
      return
    }
    guard let presenter = presentingViewController() else {
      result(
        FlutterError(
          code: "picker_unavailable",
          message: "No view can present the contact picker.",
          details: nil
        )
      )
      return
    }
    pendingResult = result
    let picker = CNContactPickerViewController()
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
    finish(nil)
  }

  func contactPicker(
    _ picker: CNContactPickerViewController,
    didSelect contact: CNContact
  ) {
    do {
      guard let portableContact = contact.mutableCopy() as? CNMutableContact else {
        finish(
          FlutterError(
            code: "invalid_contact",
            message: "The selected contact could not be copied.",
            details: nil
          )
        )
        return
      }
      portableContact.imageData = nil
      let data = try CNContactVCardSerialization.data(with: [portableContact])
      guard data.count <= Self.maximumVCardBytes else {
        finish(
          FlutterError(
            code: "invalid_contact",
            message: "The selected contact is too large.",
            details: nil
          )
        )
        return
      }
      let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
      finish([
        "displayName": name,
        "vcard": FlutterStandardTypedData(bytes: data),
      ])
    } catch let error as NSError {
      let code = error.domain == CNErrorDomain &&
        error.code == CNError.Code.authorizationDenied.rawValue
        ? "permission_denied"
        : "invalid_contact"
      finish(FlutterError(code: code, message: error.localizedDescription, details: nil))
    }
  }

  private func finish(_ value: Any?) {
    let result = pendingResult
    pendingResult = nil
    result?(value)
  }
}
