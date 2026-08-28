#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include "deep_link_delivery.h"
#include "deep_link_url.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

// One running app per user. A second launch is almost always a link click,
// and a second window would leave the click looking at an empty app while the
// real one sits behind it with the account already signed in.
constexpr wchar_t kInstanceMutexName[] =
    L"Local\\com.nkshub.nextcloudtalk.instance";

// Returns the first argument that is a link this app acts on.
std::wstring DeepLinkFromCommandLine() {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::wstring();
  }
  std::wstring found;
  for (int i = 1; i < argc && found.empty(); i++) {
    if (DeepLinkTarget(argv[i]).has_value()) {
      found = argv[i];
    }
  }
  ::LocalFree(argv);
  return found;
}

// The mutex exists from the first instance's first instruction, but its window
// only after the Flutter engine is up. A double click lands in that gap, so the
// second launch waits it out rather than opening the window the mutex is there
// to prevent.
constexpr int kWindowWaitAttempts = 60;
constexpr DWORD kWindowWaitStepMs = 50;

// Time to allow the running instance to act on the message before giving up on
// it; a busy engine is still worth waiting for, a hung one is not.
constexpr UINT kForwardTimeoutMs = 5000;

// Hands |url|, which may be empty, to the instance that already owns the mutex
// and asks it to come forward. Returns false when no window answered, so the
// caller can decide to start one after all.
bool ForwardToRunningInstance(const std::wstring& url) {
  HWND window = nullptr;
  for (int attempt = 0; attempt < kWindowWaitAttempts && window == nullptr;
       attempt++) {
    if (attempt > 0) {
      ::Sleep(kWindowWaitStepMs);
    }
    window = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"NKS Talk");
  }
  if (window == nullptr) {
    return false;
  }

  // This process holds the foreground right, having just been started by the
  // user; the running one needs it to raise itself.
  DWORD owner = 0;
  ::GetWindowThreadProcessId(window, &owner);
  if (owner != 0) {
    ::AllowSetForegroundWindow(owner);
  }

  COPYDATASTRUCT payload{};
  payload.dwData = FlutterWindow::kDeepLinkCopyDataId;
  payload.cbData =
      static_cast<DWORD>((url.size() + 1) * sizeof(wchar_t));
  payload.lpData = const_cast<wchar_t*>(url.c_str());
  DWORD_PTR answer = 0;
  return ::SendMessageTimeoutW(window, WM_COPYDATA, 0,
                               reinterpret_cast<LPARAM>(&payload),
                               SMTO_ABORTIFHUNG, kForwardTimeoutMs,
                               &answer) != 0 &&
         answer != 0;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  const std::wstring deep_link = DeepLinkFromCommandLine();

  HANDLE instance_mutex = ::CreateMutexW(nullptr, TRUE, kInstanceMutexName);
  if (instance_mutex != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS &&
      ForwardToRunningInstance(deep_link)) {
    ::CloseHandle(instance_mutex);
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  DeepLinkDelivery deep_links;
  if (!deep_link.empty()) {
    deep_links.Open(deep_link);
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, &deep_links);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"NKS Talk", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (instance_mutex != nullptr) {
    ::ReleaseMutex(instance_mutex);
    ::CloseHandle(instance_mutex);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
