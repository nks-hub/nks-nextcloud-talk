#include "shell_notification.h"

#include <propkey.h>
#include <propvarutil.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.UI.Notifications.h>
#include <winrt/base.h>

#include <algorithm>
#include <deque>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

using winrt::Windows::Data::Xml::Dom::XmlDocument;
using winrt::Windows::UI::Notifications::ToastActivatedEventArgs;
using winrt::Windows::UI::Notifications::ToastNotification;
using winrt::Windows::UI::Notifications::ToastNotificationManager;

constexpr wchar_t kAppUserModelId[] = L"com.nkshub.nextcloudtalk";
constexpr size_t kMaximumRoutes = 64;
constexpr size_t kMaximumIdentifierLength = 512;
constexpr size_t kMaximumTitleLength = 256;
constexpr size_t kMaximumBodyLength = 2048;

std::wstring Utf16From(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  const int length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring result(length, L'\0');
  if (::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                            static_cast<int>(value.size()), result.data(),
                            length) != length) {
    return std::wstring();
  }
  return result;
}

std::string Utf8From(const std::wstring& value) {
  if (value.empty()) {
    return std::string();
  }
  const int length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (length <= 0) {
    return std::string();
  }
  std::string result(length, '\0');
  if (::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                            static_cast<int>(value.size()), result.data(),
                            length, nullptr, nullptr) != length) {
    return std::string();
  }
  return result;
}

const std::string* StringAt(const flutter::EncodableMap& arguments,
                            const char* key) {
  const auto entry = arguments.find(flutter::EncodableValue(key));
  if (entry == arguments.end()) {
    return nullptr;
  }
  return std::get_if<std::string>(&entry->second);
}

bool IsValidText(const std::wstring& value, size_t maximum_length) {
  return !value.empty() && value.size() <= maximum_length;
}

std::wstring EscapeXml(const std::wstring& value) {
  std::wstring result;
  result.reserve(value.size());
  for (const wchar_t character : value) {
    switch (character) {
      case L'&':
        result.append(L"&amp;");
        break;
      case L'<':
        result.append(L"&lt;");
        break;
      case L'>':
        result.append(L"&gt;");
        break;
      case L'\"':
        result.append(L"&quot;");
        break;
      case L'\'':
        result.append(L"&apos;");
        break;
      default:
        if (character == L'\t' || character == L'\n' ||
            character == L'\r' || character >= 0x20) {
          result.push_back(character);
        }
        break;
    }
  }
  return result;
}

std::wstring NewRouteId() {
  GUID guid{};
  if (FAILED(::CoCreateGuid(&guid))) {
    return std::wstring();
  }
  wchar_t buffer[39]{};
  if (::StringFromGUID2(guid, buffer, ARRAYSIZE(buffer)) <= 0) {
    return std::wstring();
  }
  return std::wstring(buffer + 1, 36);
}

std::optional<std::wstring> ExecutablePath() {
  std::vector<wchar_t> buffer(MAX_PATH);
  while (buffer.size() <= 32768) {
    const DWORD length = ::GetModuleFileNameW(
        nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0) {
      return std::nullopt;
    }
    if (length < buffer.size() - 1) {
      return std::wstring(buffer.data(), length);
    }
    buffer.resize(buffer.size() * 2);
  }
  return std::nullopt;
}

bool EnsureNotificationShortcut() {
  PWSTR programs = nullptr;
  if (FAILED(::SHGetKnownFolderPath(FOLDERID_Programs, KF_FLAG_CREATE, nullptr,
                                    &programs))) {
    return false;
  }
  const std::wstring shortcut_path =
      std::wstring(programs) + L"\\NKS Talk.lnk";
  ::CoTaskMemFree(programs);

  const auto executable = ExecutablePath();
  if (!executable.has_value()) {
    return false;
  }

  winrt::com_ptr<IShellLinkW> link;
  if (FAILED(::CoCreateInstance(CLSID_ShellLink, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(link.put())))) {
    return false;
  }
  if (FAILED(link->SetPath(executable->c_str())) ||
      FAILED(link->SetIconLocation(executable->c_str(), 0))) {
    return false;
  }

  winrt::com_ptr<IPropertyStore> properties;
  if (FAILED(link->QueryInterface(IID_PPV_ARGS(properties.put())))) {
    return false;
  }
  PROPVARIANT app_id{};
  if (FAILED(::InitPropVariantFromString(kAppUserModelId, &app_id))) {
    return false;
  }
  const HRESULT set_result =
      properties->SetValue(PKEY_AppUserModel_ID, app_id);
  ::PropVariantClear(&app_id);
  if (FAILED(set_result) || FAILED(properties->Commit())) {
    return false;
  }

  winrt::com_ptr<IPersistFile> persist;
  return SUCCEEDED(link->QueryInterface(IID_PPV_ARGS(persist.put()))) &&
         SUCCEEDED(persist->Save(shortcut_path.c_str(), TRUE));
}

std::wstring ToastXml(const std::wstring& route_id,
                      const std::wstring& title,
                      const std::wstring& body) {
  const std::wstring route = EscapeXml(route_id);
  return L"<toast launch=\"open:" + route +
         L"\"><visual><binding template=\"ToastGeneric\"><text>" +
         EscapeXml(title) + L"</text><text>" + EscapeXml(body) +
         L"</text></binding></visual><actions>"
         L"<input id=\"replyText\" type=\"text\" "
         L"placeHolderContent=\"Reply\"/>"
         L"<action content=\"Open\" arguments=\"open:" + route +
         L"\" activationType=\"foreground\"/>"
         L"<action content=\"Reply\" arguments=\"reply:" + route +
         L"\" activationType=\"foreground\" hint-inputId=\"replyText\"/>"
         L"<action content=\"Mark as read\" arguments=\"markRead:" + route +
         L"\" activationType=\"foreground\"/>"
         L"</actions>"
         // Stated rather than left to the default, and stated as the instant
         // message sound rather than the generic one. Upstream Talk makes the
         // same distinction on Android: its message channel and its call
         // channel carry different sounds, because a chat message and a
         // ringing call are not the same interruption. `Notification.IM` is
         // what Windows itself uses for chat.
         L"<audio src=\"ms-winsoundevent:Notification.IM\" loop=\"false\"/>"
         L"</toast>";
}

struct Route {
  std::string account_id;
  std::string room_token;
};

struct Activation {
  std::wstring kind;
  Route route;
  std::string reply_text;
};

}  // namespace

class ShellNotification::Impl
    : public std::enable_shared_from_this<ShellNotification::Impl> {
 public:
  explicit Impl(HWND window) : window_(window) {}

  ~Impl() {
    std::scoped_lock lock(mutex_);
    active_ = false;
    for (auto& toast : toasts_) {
      try {
        if (notifier_) {
          notifier_.Hide(toast.notification);
        }
      } catch (...) {
        // Shutdown must not fail because the notification center is gone.
      }
      toast.notification.Activated(toast.activation_token);
    }
    toasts_.clear();
    routes_.clear();
    activations_.clear();
  }

  bool Show(const std::wstring& account_id, const std::wstring& room_token,
            const std::wstring& title, const std::wstring& body) {
    if (!IsValidText(account_id, kMaximumIdentifierLength) ||
        !IsValidText(room_token, kMaximumIdentifierLength) ||
        !IsValidText(title, kMaximumTitleLength) ||
        !IsValidText(body, kMaximumBodyLength)) {
      return false;
    }

    std::wstring route_id;
    try {
      if (!notifier_) {
        if (FAILED(::SetCurrentProcessExplicitAppUserModelID(
                kAppUserModelId)) ||
            !EnsureNotificationShortcut()) {
          return false;
        }
        notifier_ = ToastNotificationManager::CreateToastNotifier(
            kAppUserModelId);
      }

      route_id = NewRouteId();
      if (route_id.empty()) {
        return false;
      }
      XmlDocument document;
      document.LoadXml(ToastXml(route_id, title, body));
      ToastNotification notification(document);
      std::weak_ptr<Impl> weak = shared_from_this();
      const auto token = notification.Activated(
          [weak](const ToastNotification&,
                 const winrt::Windows::Foundation::IInspectable& value) {
            const auto self = weak.lock();
            if (!self) {
              return;
            }
            try {
              const auto args = value.as<ToastActivatedEventArgs>();
              std::wstring reply;
              const auto input = args.UserInput();
              if (input.HasKey(L"replyText")) {
                reply = winrt::unbox_value_or<winrt::hstring>(
                    input.Lookup(L"replyText"), L"").c_str();
              }
              self->QueueActivation(args.Arguments().c_str(), reply);
            } catch (...) {
              // Invalid platform activation is ignored at the trust boundary.
            }
          });

      {
        std::scoped_lock lock(mutex_);
        if (!active_) {
          notification.Activated(token);
          return false;
        }
        routes_[route_id] = Route{Utf8From(account_id), Utf8From(room_token)};
        route_order_.push_back(route_id);
        toasts_.push_back({route_id, notification, token});
        while (route_order_.size() > kMaximumRoutes) {
          const std::wstring oldest = route_order_.front();
          RemoveRouteLocked(oldest);
        }
      }
      notifier_.Show(notification);
      return true;
    } catch (...) {
      if (!route_id.empty()) {
        std::scoped_lock lock(mutex_);
        RemoveRouteLocked(route_id);
      }
      return false;
    }
  }

  std::optional<Activation> TakeActivation() {
    std::scoped_lock lock(mutex_);
    if (activations_.empty()) {
      return std::nullopt;
    }
    Activation result = std::move(activations_.front());
    activations_.pop_front();
    return result;
  }

 private:
  struct ActiveToast {
    std::wstring route_id;
    ToastNotification notification;
    winrt::event_token activation_token;
  };

  void RemoveRouteLocked(const std::wstring& route_id) {
    routes_.erase(route_id);
    const auto order =
        std::find(route_order_.begin(), route_order_.end(), route_id);
    if (order != route_order_.end()) {
      route_order_.erase(order);
    }
    const auto toast = std::find_if(
        toasts_.begin(), toasts_.end(), [&](const ActiveToast& candidate) {
          return candidate.route_id == route_id;
        });
    if (toast == toasts_.end()) {
      return;
    }
    try {
      if (notifier_) {
        notifier_.Hide(toast->notification);
      }
    } catch (...) {
      // In-memory cleanup remains authoritative when the shell is gone.
    }
    toast->notification.Activated(toast->activation_token);
    toasts_.erase(toast);
  }

  void QueueActivation(const std::wstring& arguments,
                       const std::wstring& reply_text) {
    const size_t separator = arguments.find(L':');
    if (separator == std::wstring::npos) {
      return;
    }
    const std::wstring kind = arguments.substr(0, separator);
    if (kind != L"open" && kind != L"reply" && kind != L"markRead") {
      return;
    }
    if (kind == L"reply" && reply_text.empty()) {
      return;
    }
    const std::wstring route_id = arguments.substr(separator + 1);
    {
      std::scoped_lock lock(mutex_);
      if (!active_) {
        return;
      }
      const auto route = routes_.find(route_id);
      if (route == routes_.end()) {
        return;
      }
      activations_.push_back(
          Activation{kind, route->second, Utf8From(reply_text)});
      if (activations_.size() > kMaximumRoutes) {
        activations_.pop_front();
      }
    }
    ::PostMessageW(window_, ShellNotification::kActivationMessage, 0, 0);
  }

  HWND window_;
  std::mutex mutex_;
  bool active_ = true;
  winrt::Windows::UI::Notifications::ToastNotifier notifier_{nullptr};
  std::unordered_map<std::wstring, Route> routes_;
  std::deque<std::wstring> route_order_;
  std::deque<Activation> activations_;
  std::vector<ActiveToast> toasts_;
};

ShellNotification::ShellNotification(flutter::BinaryMessenger* messenger,
                                     HWND window)
    : window_(window), impl_(std::make_shared<Impl>(window)) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.nkshub.nextcloudtalk/windows_notification",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "show") {
      result->NotImplemented();
      return;
    }
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      result->Error("invalid_arguments", "A notification needs a route.");
      return;
    }
    const auto* account_id = StringAt(*arguments, "accountId");
    const auto* room_token = StringAt(*arguments, "roomToken");
    const auto* title = StringAt(*arguments, "title");
    const auto* body = StringAt(*arguments, "body");
    if (account_id == nullptr || room_token == nullptr || title == nullptr ||
        body == nullptr) {
      result->Error("invalid_arguments", "A notification needs a route.");
      return;
    }
    result->Success(flutter::EncodableValue(impl_->Show(
        Utf16From(*account_id), Utf16From(*room_token), Utf16From(*title),
        Utf16From(*body))));
  });
}

ShellNotification::~ShellNotification() {
  if (channel_ != nullptr) {
    channel_->SetMethodCallHandler(nullptr);
  }
  impl_.reset();
}

bool ShellNotification::HandleActivation() {
  bool handled = false;
  while (impl_ != nullptr) {
    const auto activation = impl_->TakeActivation();
    if (!activation.has_value()) {
      break;
    }
    handled = true;
    flutter::EncodableMap payload{
        {flutter::EncodableValue("accountId"),
         flutter::EncodableValue(activation->route.account_id)},
        {flutter::EncodableValue("roomToken"),
         flutter::EncodableValue(activation->route.room_token)},
    };
    if (activation->kind == L"open") {
      channel_->InvokeMethod(
          "notificationOpened",
          std::make_unique<flutter::EncodableValue>(std::move(payload)));
    } else {
      payload[flutter::EncodableValue("kind")] = flutter::EncodableValue(
          activation->kind == L"reply" ? "reply" : "markRead");
      if (activation->kind == L"reply") {
        payload[flutter::EncodableValue("replyText")] =
            flutter::EncodableValue(activation->reply_text);
      }
      channel_->InvokeMethod(
          "notificationAction",
          std::make_unique<flutter::EncodableValue>(std::move(payload)));
    }
  }
  if (handled) {
    if (::IsIconic(window_)) {
      ::ShowWindow(window_, SW_RESTORE);
    }
    ::SetForegroundWindow(window_);
  }
  return handled;
}
