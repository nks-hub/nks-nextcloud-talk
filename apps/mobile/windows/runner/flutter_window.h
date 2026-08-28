#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "deep_link_delivery.h"
#include "shell_notification.h"
#include "taskbar_badge.h"
#include "tray_icon.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  // |deep_links| outlives the window; the runner owns it so a link that
  // arrives before the engine exists is not dropped.
  FlutterWindow(const flutter::DartProject& project,
                DeepLinkDelivery* deep_links);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 public:
  // Identifies our own WM_COPYDATA payloads, so a stray message from another
  // process is not mistaken for a link.
  static constexpr ULONG_PTR kDeepLinkCopyDataId = 0x4E4B5354;  // 'NKST'

 private:
  void RegisterDeepLinkChannel();

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Owns the taskbar overlay icon channel; torn down with the window.
  std::unique_ptr<TaskbarBadge> taskbar_badge_;

  // Keeps the app reachable from the notification area while its window is
  // hidden, and repeats the unread count the taskbar button loses there.
  std::unique_ptr<TrayIcon> tray_icon_;

  // Shows Talk messages while the app runs, and routes a click into
  // |deep_links_|.
  std::unique_ptr<ShellNotification> shell_notification_;

  DeepLinkDelivery* deep_links_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      deep_link_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
