#ifndef RUNNER_TASKBAR_BADGE_H_
#define RUNNER_TASKBAR_BADGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>

// Draws the unread count onto the taskbar button of |window|.
//
// Windows has no launcher badge API. The taskbar button takes a small overlay
// icon instead (`ITaskbarList3::SetOverlayIcon`), so the count is rendered into
// a bitmap here rather than handed to the shell as a number.
class TaskbarBadge {
 public:
  TaskbarBadge(flutter::BinaryMessenger* messenger, HWND window);
  ~TaskbarBadge();

  TaskbarBadge(const TaskbarBadge&) = delete;
  TaskbarBadge& operator=(const TaskbarBadge&) = delete;

 private:
  // Returns false when the shell refuses the overlay, which is the normal
  // outcome on a system whose taskbar is not running.
  bool SetCount(int count);

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_TASKBAR_BADGE_H_
