#include "taskbar_badge.h"

// The runner builds with NOMINMAX, but the GDI+ headers still spell the
// clamping helpers `min` and `max`, so hand them the std versions first.
#include <algorithm>
namespace Gdiplus {
using std::max;
using std::min;
}  // namespace Gdiplus

#include <gdiplus.h>
#include <shobjidl_core.h>

#include <memory>
#include <string>

namespace {

// The shell scales the overlay down to 16x16 or 20x20 depending on DPI, so the
// bitmap is drawn larger and antialiased rather than at the final size.
constexpr int kIconSize = kBadgeIconSize;

// Same red as the in-app badge (`ColorScheme.error` in the Material palette
// the app ships), so the taskbar and the account avatar agree.
constexpr BYTE kFillRed = 179;
constexpr BYTE kFillGreen = 38;
constexpr BYTE kFillBlue = 30;

ULONG_PTR EnsureGdiplus() {
  static ULONG_PTR token = []() -> ULONG_PTR {
    Gdiplus::GdiplusStartupInput input;
    ULONG_PTR started = 0;
    if (Gdiplus::GdiplusStartup(&started, &input, nullptr) != Gdiplus::Ok) {
      return 0;
    }
    return started;
  }();
  return token;
}

// Caller owns the returned icon. Returns nullptr when GDI+ is unavailable.
HICON CreateBadgeIcon(int count) {
  if (EnsureGdiplus() == 0) {
    return nullptr;
  }

  Gdiplus::Bitmap bitmap(kIconSize, kIconSize, PixelFormat32bppARGB);
  Gdiplus::Graphics graphics(&bitmap);
  graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAlias);

  Gdiplus::SolidBrush fill(Gdiplus::Color(255, kFillRed, kFillGreen, kFillBlue));
  graphics.FillEllipse(&fill, 0, 0, kIconSize - 1, kIconSize - 1);

  // Two digits already crowd a 16 px overlay, so anything past nine collapses
  // into "9+" and the exact number lives in the tooltip instead.
  const std::wstring text =
      count > 9 ? L"9+" : std::to_wstring(count);
  Gdiplus::FontFamily family(L"Segoe UI");
  Gdiplus::Font font(&family, count > 9 ? 15.0f : 19.0f,
                     Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
  Gdiplus::SolidBrush text_brush(Gdiplus::Color(255, 255, 255, 255));
  Gdiplus::StringFormat format;
  format.SetAlignment(Gdiplus::StringAlignmentCenter);
  format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  const Gdiplus::RectF layout(0.0f, 0.0f, static_cast<float>(kIconSize),
                              static_cast<float>(kIconSize));
  graphics.DrawString(text.c_str(), -1, &font, layout, &format, &text_brush);

  HICON icon = nullptr;
  if (bitmap.GetHICON(&icon) != Gdiplus::Ok) {
    return nullptr;
  }
  return icon;
}

}  // namespace

HICON CreateBadgedIcon(HICON base, int count) {
  if (base == nullptr || count <= 0 || EnsureGdiplus() == 0) {
    return nullptr;
  }
  HICON badge = CreateBadgeIcon(count);
  if (badge == nullptr) {
    return nullptr;
  }
  std::unique_ptr<Gdiplus::Bitmap> base_bitmap(Gdiplus::Bitmap::FromHICON(base));
  std::unique_ptr<Gdiplus::Bitmap> badge_bitmap(
      Gdiplus::Bitmap::FromHICON(badge));
  ::DestroyIcon(badge);
  if (base_bitmap == nullptr || badge_bitmap == nullptr) {
    return nullptr;
  }

  Gdiplus::Bitmap canvas(kIconSize, kIconSize, PixelFormat32bppARGB);
  Gdiplus::Graphics graphics(&canvas);
  graphics.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
  graphics.DrawImage(base_bitmap.get(), 0, 0, kIconSize, kIconSize);
  // Nine sixteenths leaves the app icon recognisable while keeping the digit
  // as large as the corner allows.
  constexpr int kBadgeSize = kIconSize * 9 / 16;
  graphics.DrawImage(badge_bitmap.get(), kIconSize - kBadgeSize,
                     kIconSize - kBadgeSize, kBadgeSize, kBadgeSize);

  HICON result = nullptr;
  if (canvas.GetHICON(&result) != Gdiplus::Ok) {
    return nullptr;
  }
  return result;
}

TaskbarBadge::TaskbarBadge(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.nkshub.nextcloudtalk/taskbar_badge",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "setBadge") {
          result->NotImplemented();
          return;
        }
        const auto* count = std::get_if<int32_t>(call.arguments());
        if (count == nullptr) {
          result->Error("bad-argument", "setBadge expects an int count");
          return;
        }
        if (observer_) {
          observer_(*count);
        }
        if (!SetCount(*count)) {
          result->Error("unavailable", "the shell refused the overlay icon");
          return;
        }
        result->Success();
      });
}

void TaskbarBadge::SetObserver(std::function<void(int)> observer) {
  observer_ = std::move(observer);
}

TaskbarBadge::~TaskbarBadge() {
  // Leaving a stale overlay behind would outlive the window on some shells.
  SetCount(0);
}

bool TaskbarBadge::SetCount(int count) {
  ITaskbarList3* taskbar = nullptr;
  // The runner already called CoInitializeEx on this thread.
  if (FAILED(::CoCreateInstance(CLSID_TaskbarList, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&taskbar)))) {
    return false;
  }
  bool ok = SUCCEEDED(taskbar->HrInit());
  if (ok) {
    if (count <= 0) {
      ok = SUCCEEDED(taskbar->SetOverlayIcon(window_, nullptr, nullptr));
    } else {
      HICON icon = CreateBadgeIcon(count);
      if (icon == nullptr) {
        ok = false;
      } else {
        const std::wstring description =
            std::to_wstring(count) + L" unread messages";
        // SetOverlayIcon copies the icon, so it can be freed right after.
        ok = SUCCEEDED(
            taskbar->SetOverlayIcon(window_, icon, description.c_str()));
        ::DestroyIcon(icon);
      }
    }
  }
  taskbar->Release();
  return ok;
}
