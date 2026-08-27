#ifndef RUNNER_DEEP_LINK_DELIVERY_H_
#define RUNNER_DEEP_LINK_DELIVERY_H_

#include <flutter/encodable_value.h>

#include <functional>
#include <optional>
#include <string>
#include <vector>

// Queues Talk room deep links until Flutter is ready for them.
//
// Mirrors `AppleDeepLinkDelivery` in the macOS runner, including the order it
// hands links over: the first link becomes the launch link and is only
// released when Flutter asks for it, and anything that arrives before that
// waits its turn rather than overtaking it.
class DeepLinkDelivery {
 public:
  // Returns false when |url| is not a link this app will act on, in which
  // case nothing is queued.
  bool Open(const std::wstring& url);

  void Attach(std::function<void(const flutter::EncodableValue&)> emit);

  // Only meaningful once: afterwards the queue emits directly.
  std::optional<flutter::EncodableValue> TakeLaunchLink();

 private:
  void DeliverPendingIfReady();

  // Deep enough to survive a burst of clicks, shallow enough that a stuck
  // engine cannot grow it without bound.
  static constexpr size_t kMaximumPendingLinks = 16;

  std::optional<flutter::EncodableValue> launch_link_;
  bool launch_link_was_taken_ = false;
  std::vector<flutter::EncodableValue> pending_links_;
  std::function<void(const flutter::EncodableValue&)> emit_;
};

#endif  // RUNNER_DEEP_LINK_DELIVERY_H_
