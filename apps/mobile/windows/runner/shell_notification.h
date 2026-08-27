#ifndef RUNNER_SHELL_NOTIFICATION_H_
#define RUNNER_SHELL_NOTIFICATION_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>

// Shows actionable Windows toast notifications while the process is alive.
//
// An unpackaged desktop process can publish and receive in-process toast
// activations, but Windows cannot start it for a push or a toast activation
// without packaged identity or an out-of-process COM activator. This class
// deliberately implements only the supported running-process boundary.
class ShellNotification {
 public:
  ShellNotification(flutter::BinaryMessenger* messenger, HWND window);
  ~ShellNotification();

  ShellNotification(const ShellNotification&) = delete;
  ShellNotification& operator=(const ShellNotification&) = delete;

  // WinRT activation callbacks marshal back to the Flutter platform thread
  // through this private window message.
  static constexpr UINT kActivationMessage = WM_APP + 0x41;

  bool HandleActivation();

 private:
  class Impl;

  HWND window_;
  std::shared_ptr<Impl> impl_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_SHELL_NOTIFICATION_H_
