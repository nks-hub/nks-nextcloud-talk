#include "shell_notification.h"

#include <shellapi.h>

#include "deep_link_delivery.h"
#include "resource.h"

namespace {

constexpr UINT kIconId = 1;

std::wstring Utf16From(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  const int length = MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      result.data(), length);
  return result;
}

// The shell truncates both fields; copying more than fits just wastes the tail.
void CopyBounded(wchar_t* destination, size_t capacity,
                 const std::wstring& value) {
  const size_t count = value.size() < capacity - 1 ? value.size() : capacity - 1;
  wmemcpy(destination, value.c_str(), count);
  destination[count] = L'\0';
}

const std::string* StringAt(const flutter::EncodableMap& arguments,
                            const char* key) {
  const auto entry = arguments.find(flutter::EncodableValue(key));
  if (entry == arguments.end()) {
    return nullptr;
  }
  return std::get_if<std::string>(&entry->second);
}

}  // namespace

ShellNotification::ShellNotification(flutter::BinaryMessenger* messenger,
                                     HWND window, DeepLinkDelivery* deep_links)
    : window_(window), deep_links_(deep_links) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.nkshub.nextcloudtalk/windows_notification",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() != "show") {
          result->NotImplemented();
          return;
        }
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid_arguments", "A notification needs a body.");
          return;
        }
        const auto* title = StringAt(*arguments, "title");
        const auto* body = StringAt(*arguments, "body");
        const auto* url = StringAt(*arguments, "url");
        if (title == nullptr || body == nullptr || url == nullptr) {
          result->Error("invalid_arguments", "A notification needs a body.");
          return;
        }
        result->Success(flutter::EncodableValue(
            Show(Utf16From(*title), Utf16From(*body), Utf16From(*url))));
      });
}

ShellNotification::~ShellNotification() {
  if (icon_added_) {
    NOTIFYICONDATAW data = {};
    data.cbSize = sizeof(data);
    data.hWnd = window_;
    data.uID = kIconId;
    Shell_NotifyIconW(NIM_DELETE, &data);
  }
  if (channel_ != nullptr) {
    channel_->SetMethodCallHandler(nullptr);
  }
}

bool ShellNotification::EnsureIcon() {
  if (icon_added_) {
    return true;
  }
  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  data.uCallbackMessage = kCallbackMessage;
  data.hIcon = LoadIconW(GetModuleHandle(nullptr),
                         MAKEINTRESOURCEW(IDI_APP_ICON));
  CopyBounded(data.szTip, ARRAYSIZE(data.szTip), L"NKS Talk");
  icon_added_ = Shell_NotifyIconW(NIM_ADD, &data) == TRUE;
  return icon_added_;
}

bool ShellNotification::Show(const std::wstring& title,
                             const std::wstring& body,
                             const std::wstring& url) {
  if (body.empty() || !EnsureIcon()) {
    return false;
  }
  pending_url_ = url;
  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  data.uFlags = NIF_INFO;
  data.dwInfoFlags = NIIF_USER;
  CopyBounded(data.szInfoTitle, ARRAYSIZE(data.szInfoTitle), title);
  CopyBounded(data.szInfo, ARRAYSIZE(data.szInfo), body);
  return Shell_NotifyIconW(NIM_MODIFY, &data) == TRUE;
}

bool ShellNotification::HandleCallback(WPARAM wparam, LPARAM lparam) {
  if (wparam != kIconId) {
    return false;
  }
  const auto event = static_cast<UINT>(LOWORD(lparam));
  if (event != NIN_BALLOONUSERCLICK) {
    // Every other tray event — hover, a plain icon click, the balloon timing
    // out — is deliberately ignored. This icon exists to carry notifications,
    // not to be a tray menu.
    return true;
  }
  if (deep_links_ != nullptr && !pending_url_.empty()) {
    deep_links_->Open(pending_url_);
  }
  pending_url_.clear();
  if (IsIconic(window_)) {
    ShowWindow(window_, SW_RESTORE);
  }
  SetForegroundWindow(window_);
  return true;
}
