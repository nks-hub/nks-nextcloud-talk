#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>

#include <functional>

// Keeps an icon for |window| in the notification area.
//
// Plain `Shell_NotifyIcon`, so this costs the runner no new dependency. The
// icon carries the unread count as an overlay because the taskbar button that
// normally shows it is gone while the window is hidden.
class TrayIcon {
 public:
  // |on_activate| runs when the user asks for the window back, so the window
  // itself decides how it comes forward.
  TrayIcon(HWND window, std::function<void()> on_activate);
  ~TrayIcon();

  TrayIcon(const TrayIcon&) = delete;
  TrayIcon& operator=(const TrayIcon&) = delete;

  // Mouse activity on the icon arrives as this private window message.
  // ShellNotification owns WM_APP + 0x41.
  static constexpr UINT kCallbackMessage = WM_APP + 0x42;

  // Returns true when the message belonged to this icon.
  bool HandleCallback(WPARAM wparam, LPARAM lparam);

  // Explorer drops every icon when it restarts and asks for them back with
  // this registered message. Zero when the message could not be registered.
  UINT taskbar_created_message() const { return taskbar_created_message_; }

  // Puts the icon back after an Explorer restart.
  void Restore();

  // Draws |count| onto the icon and puts the exact number in the tooltip.
  void SetUnread(int count);

 private:
  // Returns false when the shell refuses the icon, which is the normal outcome
  // on a system whose Explorer is not running.
  bool Notify(DWORD message);
  void ShowMenu();

  HWND window_;
  std::function<void()> on_activate_;
  UINT taskbar_created_message_ = 0;
  int unread_ = 0;
  // The icon currently handed to the shell. Owned, because Shell_NotifyIcon
  // keeps using the handle instead of copying it.
  HICON icon_ = nullptr;
  bool added_ = false;
};

#endif  // RUNNER_TRAY_ICON_H_
