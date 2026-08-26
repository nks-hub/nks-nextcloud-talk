#include "window_state.h"

#include <flutter_windows.h>

namespace {

constexpr const wchar_t kWindowStateRegKey[] = L"Software\\com.nkshub\\NKS Talk";
constexpr const wchar_t kWindowBoundsRegValue[] = L"WindowBounds";

// Converts a logical pixel length to physical pixels for the given window.
int ScaleForWindow(int logical, HWND window) {
  UINT dpi = FlutterDesktopGetDpiForHWND(window);
  double scale_factor = (dpi == 0 ? USER_DEFAULT_SCREEN_DPI : dpi) /
                        static_cast<double>(USER_DEFAULT_SCREEN_DPI);
  return static_cast<int>(logical * scale_factor);
}

}  // namespace

void RestoreWindowBounds(HWND window) {
  RECT bounds{};
  DWORD size = sizeof(bounds);
  LSTATUS status =
      ::RegGetValueW(HKEY_CURRENT_USER, kWindowStateRegKey,
                     kWindowBoundsRegValue, RRF_RT_REG_BINARY, nullptr,
                     &bounds, &size);
  if (status != ERROR_SUCCESS || size != sizeof(bounds)) {
    return;
  }

  LONG width = bounds.right - bounds.left;
  LONG height = bounds.bottom - bounds.top;
  if (width < ScaleForWindow(kMinimumWindowWidth, window) ||
      height < ScaleForWindow(kMinimumWindowHeight, window)) {
    return;
  }

  // Displays may have been disconnected or rearranged since the bounds were
  // stored. Never place the window where the user cannot reach it.
  if (::MonitorFromRect(&bounds, MONITOR_DEFAULTTONULL) == nullptr) {
    return;
  }

  ::SetWindowPos(window, nullptr, bounds.left, bounds.top, width, height,
                 SWP_NOZORDER | SWP_NOACTIVATE);
}

void SaveWindowBounds(HWND window) {
  // ponytail: only ordinary bounds are tracked, so a window closed while
  // maximized reopens at its last restored size. Persist the placement
  // showCmd too if reopening maximized turns out to matter.
  if (::IsZoomed(window) || ::IsIconic(window)) {
    return;
  }

  RECT bounds{};
  if (!::GetWindowRect(window, &bounds)) {
    return;
  }

  ::RegSetKeyValueW(HKEY_CURRENT_USER, kWindowStateRegKey,
                    kWindowBoundsRegValue, REG_BINARY, &bounds,
                    sizeof(bounds));
}
