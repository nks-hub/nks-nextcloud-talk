#include "deep_link_url.h"

#include <shlwapi.h>
#include <windows.h>

#include <algorithm>
#include <vector>

namespace {

// Own conversion rather than the runner's `Utf8FromUtf16`, which lives in a
// translation unit that pulls in the Flutter headers; this file stays
// buildable on its own so the rules can be exercised without the app.
std::string Utf8From(const std::wstring& value) {
  if (value.empty()) {
    return std::string();
  }
  const int size = ::WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string result(size, 0);
  ::WideCharToMultiByte(CP_UTF8, 0, value.data(),
                        static_cast<int>(value.size()), result.data(), size,
                        nullptr, nullptr);
  return result;
}

std::wstring ToLower(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(), ::towlower);
  return value;
}

// Returns everything between "://" and the first '/', '?' or '#'.
std::wstring AuthorityOf(const std::wstring& url, size_t scheme_end) {
  const size_t start = scheme_end + 3;
  const size_t end = url.find_first_of(L"/?#", start);
  return url.substr(start, end == std::wstring::npos ? end : end - start);
}

std::optional<std::wstring> QueryValue(const std::wstring& url,
                                       const std::wstring& key) {
  const size_t query_start = url.find(L'?');
  if (query_start == std::wstring::npos) {
    return std::nullopt;
  }
  const std::wstring query =
      url.substr(query_start + 1, url.find(L'#', query_start) - query_start - 1);
  size_t at = 0;
  while (at < query.size()) {
    const size_t next = query.find(L'&', at);
    const std::wstring pair =
        query.substr(at, next == std::wstring::npos ? next : next - at);
    const size_t equals = pair.find(L'=');
    if (equals != std::wstring::npos && pair.substr(0, equals) == key) {
      std::wstring value = pair.substr(equals + 1);
      // The wrapped link is percent-encoded, and it carries its own '?' and
      // '&', so it has to be decoded before it means anything.
      std::vector<wchar_t> buffer(value.size() + 1);
      DWORD size = static_cast<DWORD>(buffer.size());
      if (SUCCEEDED(::UrlUnescapeW(value.data(), buffer.data(), &size,
                                   URL_UNESCAPE_AS_UTF8))) {
        return std::wstring(buffer.data(), size);
      }
      return value;
    }
    if (next == std::wstring::npos) {
      break;
    }
    at = next + 1;
  }
  return std::nullopt;
}

}  // namespace

std::optional<std::string> DeepLinkTarget(
    const std::wstring& url) {
  const size_t scheme_end = url.find(L"://");
  if (scheme_end == std::wstring::npos) {
    return std::nullopt;
  }
  std::wstring target = url;
  if (ToLower(url.substr(0, scheme_end)) == L"nctalk") {
    // Same wrapper the macOS runner accepts: nctalk://open?uri=<encoded>.
    if (ToLower(AuthorityOf(url, scheme_end)) != L"open") {
      return std::nullopt;
    }
    const auto wrapped = QueryValue(url, L"uri");
    if (!wrapped.has_value()) {
      return std::nullopt;
    }
    target = *wrapped;
  }

  const size_t target_scheme_end = target.find(L"://");
  if (target_scheme_end == std::wstring::npos ||
      ToLower(target.substr(0, target_scheme_end)) != L"https") {
    return std::nullopt;
  }
  const std::wstring authority = AuthorityOf(target, target_scheme_end);
  // No host is not a link; credentials in the authority are how a lookalike
  // host gets hidden, so those are refused rather than stripped.
  if (authority.empty() || authority.find(L'@') != std::wstring::npos) {
    return std::nullopt;
  }
  return Utf8From(target);
}

