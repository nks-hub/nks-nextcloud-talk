#include "deep_link_delivery.h"

#include "deep_link_url.h"

bool DeepLinkDelivery::Open(const std::wstring& url) {
  const auto target = DeepLinkTarget(url);
  if (!target.has_value()) {
    return false;
  }
  const flutter::EncodableValue payload(flutter::EncodableMap{
      {flutter::EncodableValue("uri"), flutter::EncodableValue(*target)},
  });

  if (!launch_link_was_taken_ && !launch_link_.has_value()) {
    launch_link_ = payload;
    return true;
  }
  if (emit_) {
    emit_(payload);
    return true;
  }
  if (pending_links_.size() == kMaximumPendingLinks) {
    pending_links_.erase(pending_links_.begin());
  }
  pending_links_.push_back(payload);
  return true;
}

void DeepLinkDelivery::Attach(
    std::function<void(const flutter::EncodableValue&)> emit) {
  emit_ = std::move(emit);
  DeliverPendingIfReady();
}

std::optional<flutter::EncodableValue> DeepLinkDelivery::TakeLaunchLink() {
  launch_link_was_taken_ = true;
  auto result = launch_link_;
  launch_link_.reset();
  DeliverPendingIfReady();
  return result;
}

void DeepLinkDelivery::DeliverPendingIfReady() {
  if (!launch_link_was_taken_ || !emit_) {
    return;
  }
  const auto links = pending_links_;
  pending_links_.clear();
  for (const auto& link : links) {
    emit_(link);
  }
}
