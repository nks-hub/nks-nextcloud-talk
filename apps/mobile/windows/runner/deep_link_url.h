#ifndef RUNNER_DEEP_LINK_URL_H_
#define RUNNER_DEEP_LINK_URL_H_

#include <optional>
#include <string>

// Turns a clicked URL into the https link the app should open, or nothing
// when it is not a link this app acts on.
//
// Accepts the same two shapes the macOS runner does: a plain `https://` link,
// or `nctalk://open?uri=<percent-encoded https link>`. Kept free of any
// Flutter type so it can be compiled and exercised on its own — this is the
// piece where a mistake silently swallows every link.
std::optional<std::string> DeepLinkTarget(const std::wstring& url);

#endif  // RUNNER_DEEP_LINK_URL_H_
