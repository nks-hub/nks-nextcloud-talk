# OwnTalk

Chat and calls for your own Nextcloud Talk server — one Flutter codebase for Android, iOS, Windows, macOS and Linux. A single install can sign in to several accounts on several Nextcloud servers at once.

OwnTalk is an independent client, not an official Nextcloud app. It was called **NKS Talk** until version 1.0.13; only the name changed, so an update keeps every account and conversation. The UI, the data model and the implementation are our own and licensed under [`GPL-3.0-or-later`](LICENSE). The upstream Android and iOS apps serve as the reference for behaviour and compatibility. The Czech emoji names in `apps/mobile/lib/features/chat/composer/emoji_czech_names.g.dart` are derived from the Unicode CLDR annotations under the Unicode license (https://www.unicode.org/license.txt).

## Get it

- **Android** — Google Play closed testing: <https://play.google.com/apps/testing/com.nkshub.nextcloudtalk>
- **iOS** — TestFlight, on invitation
- **Windows, macOS, Linux** — installers in [Releases](https://github.com/nks-hub/nks-nextcloud-talk/releases). The macOS build is signed with Developer ID and notarized; the Windows installer is not code-signed yet, so SmartScreen asks once. The desktop app checks the same page for updates and installs them itself.

The supported server line starts at Talk 22 (Nextcloud 32).

## What it does

- **Chat** — messages, replies, threads, reactions, mentions with suggestions, editing and deleting, pinned messages, reminders, silent and scheduled messages, Markdown with a formatting menu (bold, italic, strikethrough, inline code, code blocks).
- **Attachments** — photos, files, voice messages, polls, location, contacts and GIFs; a paste too long for one message goes out as a `.md` or `.txt` file.
- **Calls** — audio and video, group calls, screen sharing, over the Talk high-performance backend or the internal signaling, with TURN.
- **Notifications** — on Android and iOS even with the app closed, through our own push gateway with no per-server rebuild (see below); on desktop while the app runs, and it can start at sign-in and wait in the tray.
- **Offline first** — the conversation list and history come from a local database; a message written without a signal waits in an ordered outbox and is sent once the connection returns.
- **Everywhere** — phone layout, an adaptive three-pane layout on tablet and desktop, keyboard control on desktop, app lock with biometrics, Czech and English, light and dark theme, large text and screen readers.

## Building

The app lives in [`apps/mobile`](apps/mobile); the pure Dart protocol package [`talk_protocol`](packages/talk_protocol) implements and tests the Talk wire models the app uses.

The Windows build additionally needs a JDK and a configured `JAVA_HOME`. This is not because of Android: `sentry_flutter` depends on the `jni` package, which registers itself as an FFI plugin on Windows too, and its `find_package(JNI)` without a JDK fails CMake with a `FindJNI.cmake` message that never mentions Java.

The Linux build needs the same JDK plus four packages beyond Flutter's official list — measured on 3 September 2026 on a clean Linux Mint installation where the build failed on each of them in turn: `libgstreamer1.0-dev` and `libgstreamer-plugins-base1.0-dev` (because of `audioplayers_linux`), `libcurl4-openssl-dev` (sentry-native) and `default-jdk-headless` (the same `jni` package). An extra trap: after a failed configure, `CMAKE_INSTALL_PREFIX=/usr/local` stays in the CMake cache and the next attempt fails on `Permission denied` during install — `flutter clean` fixes that, not an edit of `linux/CMakeLists.txt`.

## Running the tests

Measured on 24 September 2026: `flutter analyze` reports no findings and `apps/mobile` passes 2761 tests with 7 skipped.

From the repository root:

```sh
cd apps/mobile
flutter analyze
flutter test
cd ../../packages/talk_protocol
dart test
cd ../..
```

**`talk_protocol` needs `dart test`, not `flutter test`.** It is a pure Dart package, and seven of its tests compile a probe with `Platform.resolvedExecutable … compile exe`. Under `flutter test` that executable is the Flutter tester rather than the Dart VM, so the compilation never returns and all seven die on the 30-second timeout — a red suite that looks like a defect and is only the wrong runner.

Among the skipped tests are live smokes against a real Nextcloud. They run when `NEXTCLOUD_TALK_ORIGIN`, `NEXTCLOUD_TALK_USERNAME` and `NEXTCLOUD_TALK_APP_PASSWORD` are set, and the room-scoped search additionally wants `NEXTCLOUD_TALK_TEST_ROOM_TOKEN` pointing at a conversation that has messages — against an empty room its assertion holds without proving anything. `NEXTCLOUD_TALK_SEARCH_TERM` overrides the search term, which defaults to `a`.

The macOS native suite has 17 tests, verified on 7 September 2026. Its host requires Apple Development signing: macOS refuses an ad-hoc signature with the app's APNs and shared-keychain entitlements before any test can start. Keep those entitlements and use a development identity in the login keychain.

For API-based provisioning, set `APPLE_TEAM_ID`, `ASC_KEY_PATH`, `ASC_KEY_ID` and `ASC_ISSUER_ID` to your team's credentials, then run from `apps/mobile`:

```sh
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY='Apple Development' \
  APPLE_TEAM_ID="$APPLE_TEAM_ID" DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
```

The provisioning flags register this Mac and create development profiles if needed. An Xcode account with existing profiles can replace the API arguments. This command runs tests locally; it does not publish an Apple build.

For the Ubuntu CI checks without packaging new artifacts, run `gh workflow run build.yml --ref main -f tests_only=true`. The default manual run still builds Android, Linux and Windows, including native Windows checks; publishing remains restricted to release tags. Apple tests run on a Mac.

## Push without a per-server rebuild

The supported server line starts at Talk 22 (Nextcloud 32), see D-047.

Since 27 August 2026 the default Android path is our **own push proxy** — see D-038. Both Android and Apple register push-v2 against `nks-talk-notify`, which holds the sending branch to FCM v1 and to APNs. The project therefore DOES have a publisher Firebase project and its own gateway; `google-services.json` is gitignored. The per-server rebuild still goes away, because the proxy address is chosen by the client at registration time, not by the server administrator.

Web Push over the UnifiedPush connector and the embedded FCM distributor remains a **switchable fallback** for Nextcloud 34+, controllable in Settings → Push notifications at runtime without a new build. This fallback branch, and only this one, works without a publisher Firebase project and an own gateway; in it the VAPID key and the Web Push subscription are negotiated at runtime with the specific server.

On top of that, **Nextcloud Client Push** (`notify_push`) runs on every platform — a websocket that Nextcloud itself advertises in capabilities. It delivers a message immediately for as long as the app is running, and needs nothing else.

iOS is a different platform boundary and it is worth saying exactly why. Nextcloud cannot talk to APNs; `apps/notifications/lib/Push.php` only groups notifications by the `proxyserver` column and posts them to that address. Delivery to APNs is done by that address. The official Talk app points at `push-notifications.nextcloud.com`, a Nextcloud GmbH service signing with **their** Apple certificate for **their** bundle id — nothing gets through it to a third-party client. That address therefore **is not part of a self-hosted Nextcloud** and is not configured in its administration; the client picks it at device registration through the `proxyServer` parameter.

A full description of all three channels, of the contract with Nextcloud and of what is fixed by the platform is in the [notifications document](docs/architecture/notifications.md). The older analysis is in the push analysis in the maintainer notes.

## Documentation

- [Documentation index](docs/README.md)
- [Flutter application foundation](docs/architecture/flutter-foundation.md)
- [System design](docs/architecture/system-design.md)
- [Notifications on all platforms](docs/architecture/notifications.md)
- [Decisions and open choices](docs/architecture/decisions.md)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — in particular the public repository policy: nothing that names the operator's hosts, machines, accounts or identifiers is committed here.
