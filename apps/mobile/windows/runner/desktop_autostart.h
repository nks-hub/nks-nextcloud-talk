#ifndef RUNNER_DESKTOP_AUTOSTART_H_
#define RUNNER_DESKTOP_AUTOSTART_H_

#include <flutter/method_channel.h>

#include <memory>

class DesktopAutostart {
 public:
  explicit DesktopAutostart(flutter::BinaryMessenger* messenger);
  ~DesktopAutostart();

  DesktopAutostart(const DesktopAutostart&) = delete;
  DesktopAutostart& operator=(const DesktopAutostart&) = delete;

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_DESKTOP_AUTOSTART_H_
