#ifndef RUNNER_WINDOW_STATE_H_
#define RUNNER_WINDOW_STATE_H_

#include <windows.h>

// Smallest window the adaptive layout is designed for, in logical pixels.
// Keep in sync with the macOS and Linux runners; the Flutter side switches to
// the compact single-pane layout well above this size.
constexpr int kMinimumWindowWidth = 600;
constexpr int kMinimumWindowHeight = 400;

// Restores the window bounds saved by a previous run.
//
// Does nothing when no bounds were stored, when they are smaller than the
// minimum window size, or when they no longer intersect any connected display.
void RestoreWindowBounds(HWND window);

// Stores the current restored (non-maximized) window bounds for the next run.
void SaveWindowBounds(HWND window);

#endif  // RUNNER_WINDOW_STATE_H_
