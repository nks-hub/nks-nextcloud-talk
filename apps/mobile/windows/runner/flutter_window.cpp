#include "flutter_window.h"

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "window_state.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             DeepLinkDelivery* deep_links)
    : project_(project), deep_links_(deep_links) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // Restore before the view controller is created so the first surface already
  // has the final size.
  RestoreWindowBounds(GetHandle());

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  taskbar_badge_ = std::make_unique<TaskbarBadge>(
      flutter_controller_->engine()->messenger(), GetHandle());
  RegisterDeepLinkChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Before the engine goes away: both hold a channel on its messenger.
  taskbar_badge_ = nullptr;
  if (deep_links_ != nullptr) {
    deep_links_->Attach(nullptr);
  }
  deep_link_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_EXITSIZEMOVE:
    case WM_DESTROY:
      SaveWindowBounds(hwnd);
      break;
    case WM_COPYDATA:
      // A second launch handed its link to this instance instead of starting
      // a window of its own.
      if (deep_links_ != nullptr) {
        auto* data = reinterpret_cast<COPYDATASTRUCT*>(lparam);
        if (data != nullptr && data->dwData == kDeepLinkCopyDataId &&
            data->cbData >= sizeof(wchar_t)) {
          const std::wstring url(
              static_cast<const wchar_t*>(data->lpData),
              data->cbData / sizeof(wchar_t) - 1);
          deep_links_->Open(url);
          SetForegroundWindow(hwnd);
        }
      }
      return TRUE;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::RegisterDeepLinkChannel() {
  if (deep_links_ == nullptr) {
    return;
  }
  deep_link_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.nkshub.nextcloudtalk/deep_link",
          &flutter::StandardMethodCodec::GetInstance());
  deep_link_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "getLaunchLink") {
          result->NotImplemented();
          return;
        }
        const auto launch_link = deep_links_->TakeLaunchLink();
        result->Success(launch_link.has_value() ? *launch_link
                                                : flutter::EncodableValue());
      });
  deep_links_->Attach([this](const flutter::EncodableValue& payload) {
    if (deep_link_channel_ != nullptr) {
      deep_link_channel_->InvokeMethod(
          "linkOpened",
          std::make_unique<flutter::EncodableValue>(payload));
    }
  });
}
