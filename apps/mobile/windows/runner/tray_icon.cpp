#include "tray_icon.h"

#include <shellapi.h>

#include <algorithm>
#include <string>

#include "resource.h"
#include "taskbar_badge.h"

namespace {

// This process only ever shows one icon.
constexpr UINT kIconId = 1;

constexpr UINT kMenuOpen = 1;
constexpr UINT kMenuHide = 2;
constexpr UINT kMenuQuit = 3;

// The runner carries no localisation of its own, and the app ships Czech and
// English, so the menu follows the Windows UI language between those two.
bool UseCzech() {
  static const bool czech =
      PRIMARYLANGID(::GetUserDefaultUILanguage()) == LANG_CZECH;
  return czech;
}

// |size| is in pixels. Caller owns the returned icon.
HICON LoadAppIcon(int size) {
  return static_cast<HICON>(::LoadImageW(::GetModuleHandleW(nullptr),
                                         MAKEINTRESOURCEW(IDI_APP_ICON),
                                         IMAGE_ICON, size, size,
                                         LR_DEFAULTCOLOR));
}

}  // namespace

TrayIcon::TrayIcon(HWND window, std::function<void()> on_activate)
    : window_(window), on_activate_(std::move(on_activate)) {
  taskbar_created_message_ = ::RegisterWindowMessageW(L"TaskbarCreated");
  added_ = Notify(NIM_ADD);
}

TrayIcon::~TrayIcon() {
  if (added_) {
    Notify(NIM_DELETE);
  }
  if (icon_ != nullptr) {
    ::DestroyIcon(icon_);
    icon_ = nullptr;
  }
}

bool TrayIcon::HandleCallback(WPARAM wparam, LPARAM lparam) {
  if (wparam != kIconId) {
    return false;
  }
  switch (static_cast<UINT>(lparam)) {
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
      if (on_activate_) {
        on_activate_();
      }
      break;
    case WM_RBUTTONUP:
    case WM_CONTEXTMENU:
      ShowMenu();
      break;
  }
  return true;
}

void TrayIcon::Restore() {
  added_ = Notify(NIM_ADD);
}

void TrayIcon::SetUnread(int count) {
  count = std::max(count, 0);
  if (count == unread_) {
    return;
  }
  unread_ = count;
  if (added_) {
    Notify(NIM_MODIFY);
  }
}

bool TrayIcon::Notify(DWORD message) {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;

  if (message == NIM_DELETE) {
    return ::Shell_NotifyIconW(message, &data) != FALSE;
  }

  HICON icon = nullptr;
  if (unread_ > 0) {
    // Drawn at the badge size and left to the shell to scale down: a digit in
    // the corner of a 16 px icon is unreadable at any DPI, and the exact
    // number is in the tooltip regardless.
    HICON base = LoadAppIcon(kBadgeIconSize);
    icon = CreateBadgedIcon(base, unread_);
    if (base != nullptr) {
      ::DestroyIcon(base);
    }
  }
  if (icon == nullptr) {
    icon = LoadAppIcon(::GetSystemMetrics(SM_CXSMICON));
  }

  data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  data.uCallbackMessage = kCallbackMessage;
  data.hIcon = icon;

  // Czech unread counts would need three plural forms, so the tooltip states
  // the number instead of agreeing with it.
  std::wstring tip = L"NKS Talk";
  if (unread_ > 0) {
    tip += UseCzech() ? L" — nepřečtené: "
                      : L" — unread: ";
    tip += std::to_wstring(unread_);
  }
  const size_t length = std::min(tip.size(), ARRAYSIZE(data.szTip) - 1);
  ::memcpy(data.szTip, tip.c_str(), length * sizeof(wchar_t));
  data.szTip[length] = L'\0';

  const bool ok = ::Shell_NotifyIconW(message, &data) != FALSE;
  // The shell keeps using the handle rather than copying it, so the previous
  // icon can only go once the new one is in place.
  if (icon_ != nullptr) {
    ::DestroyIcon(icon_);
  }
  icon_ = icon;
  return ok;
}

void TrayIcon::ShowMenu() {
  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  const bool czech = UseCzech();
  ::AppendMenuW(menu, MF_STRING, kMenuOpen,
                czech ? L"Otevřít NKS Talk" : L"Open NKS Talk");
  ::AppendMenuW(menu, MF_STRING, kMenuHide,
                czech ? L"Skrýt do oznamovací oblasti"
                      : L"Hide to notification area");
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kMenuQuit, czech ? L"Ukončit" : L"Quit");
  ::SetMenuDefaultItem(menu, kMenuOpen, FALSE);

  POINT cursor{};
  ::GetCursorPos(&cursor);
  // A tray menu only dismisses on an outside click while its owner is the
  // foreground window, and it needs the trailing WM_NULL to let go again.
  ::SetForegroundWindow(window_);
  const int command =
      ::TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY,
                       cursor.x, cursor.y, 0, window_, nullptr);
  ::DestroyMenu(menu);
  ::PostMessageW(window_, WM_NULL, 0, 0);

  switch (command) {
    case kMenuOpen:
      if (on_activate_) {
        on_activate_();
      }
      break;
    case kMenuHide:
      ::ShowWindow(window_, SW_HIDE);
      break;
    case kMenuQuit:
      ::PostMessageW(window_, WM_CLOSE, 0, 0);
      break;
  }
}
