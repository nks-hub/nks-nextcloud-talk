#ifndef RUNNER_DESKTOP_AUTOSTART_H_
#define RUNNER_DESKTOP_AUTOSTART_H_

#include <flutter_linux/flutter_linux.h>

FlMethodChannel* desktop_autostart_channel_new(FlBinaryMessenger* messenger);

#endif  // RUNNER_DESKTOP_AUTOSTART_H_
