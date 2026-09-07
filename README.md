# NKS Nextcloud Talk

An original Flutter client compatible with Nextcloud Talk. A single build can
connect multiple accounts on multiple Nextcloud servers and uses one codebase
for Android, iOS, Windows, macOS and Linux.

This is not a pixel copy of the official clients. The upstream Android and iOS
apps serve as an SHA-bound reference for behaviour and compatibility; the UI,
the data model and the implementation are our own and licensed under
[`GPL-3.0-or-later`](LICENSE). The Czech emoji names in
`apps/mobile/lib/features/chat/composer/emoji_czech_names.g.dart` are derived
from the Unicode CLDR annotations under the Unicode license
(https://www.unicode.org/license.txt).

## Current state

The repository already contains a runnable application in
[`apps/mobile`](apps/mobile):

- Nextcloud status, Login Flow v2 and authenticated capabilities;
- secure storage of the app password and an account-scoped Drift database;
- multiple accounts, conversation-v4 full/delta sync and a cache-first list;
- Czech and English localization, light and dark theme;
- the phone stack and an adaptive three-pane layout for tablet and desktop;
- an Android debug build and native runners for Android, iOS, Windows, macOS and
  Linux. Commit `cf13cce` closes the runners.

The Windows build additionally needs a JDK and a configured `JAVA_HOME`. This is
not because of Android: `sentry_flutter` depends on the `jni` package, which
registers itself as an FFI plugin on Windows too, and its `find_package(JNI)`
without a JDK fails CMake with a `FindJNI.cmake` message that never mentions
Java.

The Linux build needs the same JDK plus four packages beyond Flutter's official
list — measured on 3 September 2026 on a clean Linux Mint installation where the
build failed on each of them in turn: `libgstreamer1.0-dev` and
`libgstreamer-plugins-base1.0-dev` (because of `audioplayers_linux`),
`libcurl4-openssl-dev` (sentry-native) and `default-jdk-headless` (the same `jni`
package). An extra trap: after a failed configure, `CMAKE_INSTALL_PREFIX=/usr/local`
stays in the CMake cache and the next attempt fails on `Permission denied` during
install — `flutter clean` fixes that, not an edit of `linux/CMakeLists.txt`.

The pure Dart package [`talk_protocol`](packages/talk_protocol) additionally
implements and tests bootstrap, conversations, chat, rich chat, attachment,
signaling preparation and the original Notifications push-v2 wire models. These
protocol slices do not mean that their Flutter UI or platform lifecycle are
already finished.

The chat and thread screen, persistent plain/reply/named-thread text send, the
Rich Object renderer, images, reactions and avatars are already in the app. The
attachment path has a safe OCS/WebDAV transport, a durable Drift service, an
image picker/viewer and a voice record/preview/submit flow; their current live
server E2E is still missing. An incoming live thread update and a bidirectional
send are proven by an older APK; a named-thread send has no device round trip
yet. Giphy trending/search, selection, server-side send and inline animated
rendering are also proven on an older Android live APK. The app renders a real
animated GIF directly in the message. The URL that gets sent is only an internal
Talk wire reference: it must not appear as the message text, it is not clickable
and the GIF is not sent as an attachment. The only visible external GIPHY link is
the attribution in the picker. Root history/read-unread, live outbox
process-death, attachments, voice, real push delivery and calls remain separate
unfinished slices.

Which of those slices is finished, and what evidence closed it, is tracked in
the maintainer notes, which are not part of this repository.

## Running the tests

Measured on 7 September 2026 at `204683b`: `flutter analyze` reports no
findings, `apps/mobile` passes 2071 tests with 3 skipped, and `talk_protocol`
passes 1105.

```
flutter analyze
cd apps/mobile        && flutter test
cd packages/talk_protocol && dart test
```

**`talk_protocol` needs `dart test`, not `flutter test`.** It is a pure Dart
package, and seven of its tests compile a probe with
`Platform.resolvedExecutable … compile exe`. Under `flutter test` that
executable is the Flutter tester rather than the Dart VM, so the compilation
never returns and all seven die on the 30-second timeout — a red suite that
looks like a defect and is only the wrong runner.

The three skipped tests are live smokes against a real Nextcloud. They run
when `NEXTCLOUD_TALK_ORIGIN`, `NEXTCLOUD_TALK_USERNAME` and
`NEXTCLOUD_TALK_APP_PASSWORD` are set, and the room-scoped search additionally
wants `NEXTCLOUD_TALK_TEST_ROOM_TOKEN` pointing at a conversation that has
messages — against an empty room its assertion holds without proving anything.
`NEXTCLOUD_TALK_SEARCH_TERM` overrides the search term, which defaults to `a`.

## Push without a per-server rebuild

The supported server line starts at Talk 22 (Nextcloud 32), see D-047.

Since 27 August 2026 the default Android path is our **own push proxy** — see
D-038. Both Android and Apple register push-v2 against `nks-talk-notify`, which
holds the sending branch to FCM v1 and to APNs. The project therefore DOES have
a publisher Firebase project and its own gateway; `google-services.json` is
gitignored. The per-server rebuild still goes away, because the proxy address is
chosen by the client at registration time, not by the server administrator.

Web Push over the UnifiedPush connector and the embedded FCM distributor remains
a **switchable fallback** for Nextcloud 34+, controllable in Settings → Push
notifications at runtime without a new build. This fallback branch, and only
this one, works without a publisher Firebase project and an own gateway; in it
the VAPID key and the Web Push subscription are negotiated at runtime with the
specific server.

The native Android push implementation in commit `3c74165` was closed by a
security review, a strict parser, an account-bound one-time tap token and fresh
Kotlin tests. It is an implemented and automated platform slice, not finished
live push delivery. The real Nextcloud → FCM → background/killed flow on a
physical device is still open.

On top of that, **Nextcloud Client Push** (`notify_push`) runs on every platform —
a websocket that Nextcloud itself advertises in capabilities. It delivers a
message immediately for as long as the app is running, and needs nothing else.

iOS is a different platform boundary and it is worth saying exactly why.
Nextcloud cannot talk to APNs; `apps/notifications/lib/Push.php` only groups
notifications by the `proxyserver` column and posts them to that address.
Delivery to APNs is done by that address. The official Talk app points at
`push-notifications.nextcloud.com`, a Nextcloud GmbH service signing with
**their** Apple certificate for **their** bundle id — nothing gets through it to
a third-party client. That address therefore **is not part of a self-hosted
Nextcloud** and is not configured in its administration; the client picks it at
device registration through the `proxyServer` parameter.

A full description of all three channels, of the contract with Nextcloud and of
what is fixed by the platform is in the
[notifications document](docs/architecture/notifications.md). The older analysis
is in the push analysis in the maintainer notes.

## Documentation

- [Documentation index](docs/README.md)
- [Flutter application foundation](docs/architecture/flutter-foundation.md)
- [System design](docs/architecture/system-design.md)
- [Notifications on all platforms](docs/architecture/notifications.md)
- [Decisions and open choices](docs/architecture/decisions.md)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — in particular the public repository
policy: nothing that names the operator's hosts, machines, accounts or
identifiers is committed here.
