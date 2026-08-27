// Standalone check for the deep link URL rules. Built and run on a Windows
// machine by tool/verify_deep_link_url.ps1; deliberately free of Flutter and
// of any test framework, so it needs nothing but cl.exe.
#include <cstdio>
#include <string>

#include "deep_link_url.h"

namespace {

int failures = 0;

void Expect(const wchar_t* url, const char* expected) {
  const auto actual = DeepLinkTarget(url);
  const std::string got = actual.value_or("<none>");
  const std::string want = expected == nullptr ? "<none>" : expected;
  if (got != want) {
    failures++;
    printf("FAIL  input=%ls\n      want=%s\n      got =%s\n", url,
           want.c_str(), got.c_str());
  } else {
    printf("ok    %ls -> %s\n", url, got.c_str());
  }
}

}  // namespace

int main() {
  const char* kRoom = "https://cloud.example.invalid/index.php/call/abc123";

  // The wrapper the macOS runner already accepts.
  Expect(L"nctalk://open?uri=https%3A%2F%2Fcloud.example.invalid%2Findex.php%2Fcall%2Fabc123",
         kRoom);
  // A plain link, which is what a browser hands over.
  Expect(L"https://cloud.example.invalid/index.php/call/abc123", kRoom);
  // Scheme and host are compared case-insensitively.
  Expect(L"NCTALK://OPEN?uri=https%3A%2F%2Fcloud.example.invalid%2Findex.php%2Fcall%2Fabc123",
         kRoom);

  // Refused: not https.
  Expect(L"http://cloud.example.invalid/index.php/call/abc123", nullptr);
  Expect(L"file:///c:/windows/system32/calc.exe", nullptr);
  // Refused: credentials in the authority are how a lookalike host hides.
  Expect(L"https://cloud.example.invalid@evil.invalid/call/abc123", nullptr);
  Expect(L"nctalk://open?uri=https%3A%2F%2Fgood.invalid%40evil.invalid%2Fcall%2Fx",
         nullptr);
  // Refused: no host.
  Expect(L"https:///call/abc123", nullptr);
  // Refused: the wrapper without a target, or aimed somewhere else.
  Expect(L"nctalk://open", nullptr);
  Expect(L"nctalk://elsewhere?uri=https%3A%2F%2Fcloud.example.invalid%2Fcall%2Fx",
         nullptr);
  // Refused: not a URL at all, which is what most stray argv entries are.
  Expect(L"--enable-software-rendering", nullptr);
  Expect(L"", nullptr);

  printf(failures == 0 ? "\nALL PASSED\n" : "\n%d FAILED\n", failures);
  return failures == 0 ? 0 : 1;
}
