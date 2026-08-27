#ifndef RUNNER_SHELL_NOTIFICATION_H_
#define RUNNER_SHELL_NOTIFICATION_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <string>

class DeepLinkDelivery;

// Shows a Talk message as a Windows notification while the app is running.
//
// ponytail: `Shell_NotifyIcon` rather than a WinRT toast. Windows 10 and 11
// render this balloon as a toast anyway, and it needs no package identity, no
// AppUserModelID and no Start Menu shortcut — which an unpackaged Flutter
// runner would otherwise have to register at install time. The visible cost is
// a tray icon, because the shell will not show a balloon without one.
//
// Clicking the notification does not open anything by itself: it hands the
// room URL to the same [DeepLinkDelivery] that handles `nctalk://` links, so
// the tap route is the one that already exists rather than a second one.
class ShellNotification {
 public:
  ShellNotification(flutter::BinaryMessenger* messenger, HWND window,
                    DeepLinkDelivery* deep_links);
  ~ShellNotification();

  ShellNotification(const ShellNotification&) = delete;
  ShellNotification& operator=(const ShellNotification&) = delete;

  // The window message the tray icon reports clicks through.
  static constexpr UINT kCallbackMessage = WM_APP + 0x41;

  // Returns true when the message was a tray callback this owns.
  bool HandleCallback(WPARAM wparam, LPARAM lparam);

 private:
  bool EnsureIcon();
  bool Show(const std::wstring& title, const std::wstring& body,
            const std::wstring& url);

  HWND window_;
  DeepLinkDelivery* deep_links_;
  bool icon_added_ = false;
  std::wstring pending_url_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_SHELL_NOTIFICATION_H_
