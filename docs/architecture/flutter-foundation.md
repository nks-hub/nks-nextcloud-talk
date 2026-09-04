# Flutter application foundation

Update date: 26 August 2026.

## State

`apps/mobile` contains a runnable Flutter application, not just scaffolding. It
implements the slice from adding a server to a locally stored account, an
account-scoped conversation list and the first cache-first chat/thread screen
with foreground polling, a durable text outbox, an emoji and Giphy composer,
image and voice media and the native Android Web Push delivery boundary. The
current APK has a verified build and update install. The real Login Flow, the
live conversation list, opening a room and an inline animated Giphy send belong
to a historical APK. That Giphy run used the wire-reference variant that has
since been replaced; the new real `image/gif` attachment flow has been
implemented and verified by automation since `7ca580e`, but has no live server
evidence yet.

This does not make the whole Nextcloud Talk client finished. The current
root/thread cross-device refresh, the live attachment and voice matrix, real
background/killed FCM delivery, a live read transition, a documented delivered,
presence, two accounts on two servers and calls all remain open feature gates.

## Platforms and identity

One Flutter project contains targets for Android, iOS, Windows, macOS and Linux.
The Android namespace/applicationId, the iOS and macOS bundle IDs and the Linux
application ID are all `com.nkshub.nextcloudtalk`. The Android build has an
effective minSdk of 24; the iOS deployment target is 13.0 and the macOS target
11.0.

The current Android debug build was built, update-installed and launched on
`emulator-5554`. On Windows a release build and a live onboarding smoke test
passed earlier. On macOS 15.7.4 arm64 a debug bundle was built from the exact
commit `f0d33c2` (base `b2676ab`) and ran as an ordinary user with a visible
800×628 window. The deployment test 1/1, analyze, codesign and the bundle ID
passed; the executable SHA-256 is
`0a4861b9974e7a1600cbbae2aa8e719e7fcaefd8b0a554debf41d11a17d3d5be`. The RemoteCmd
process did not have the Screen Recording permission, so the captured desktop is
not UI screenshot evidence. The platform projects for iOS and Linux exist, but
their build on the corresponding host has no runtime evidence yet.

## The implemented flow

1. The user enters the Nextcloud URL.
2. The client canonicalizes it and loads the public `status.php`.
3. Login Flow v2 opens in the system browser and the poll stays bound to the
   original origin and base path.
4. The signed-in capabilities must confirm Talk and `conversation-v4`.
5. The app password is stored in the platform secure storage; Drift holds only
   account-scoped metadata.
6. The conversation sync uses a mode-aware per-account single-flight and the
   atomic full/delta merge from `talk_protocol`; the foreground loop is
   incremental and a manual refresh forces a full reconciliation.
7. The UI observes Drift and never uses the active account as a global authority
   for a different account scope.
8. An open chat or thread starts a scope-bound foreground binding; a received
   response is committed into Drift first and only then repaints `ChatRoomPane`
   through Riverpod.
9. The selected Giphy URL is only an input to the account-scoped References
   resolver. The client accepts valid `image/gif` bytes, stores them in a durable
   app-owned source and sends them through the standard Talk
   Draft/WebDAV/finalize attachment flow. The URL never enters the text composer,
   `sendText` or the text outbox.
10. The Android UnifiedPush callback validates the wake-up payload, stores it in
    an encrypted account-scoped queue and a tap hands it to Flutter through a
    one-time token. After a wake-up, the source of truth stays OCS, not the push
    payload.

Drift schema v4 stores `avatarVersion` and `isCustomAvatar` on a room and keeps
the avatar bytes under `(accountId, URI)`. Versioned URLs are treated as
immutable, unversioned ones are revalidated through an ETag after they expire,
and on an offline error the available stale cache stays. The metadata from
`X-NC-IsCustomAvatar` decide whether a custom image or a local fallback
icon/initials are rendered. The v2 → v4 migration backfills the room metadata;
v3 → v4 discards a cache whose custom origin could not be safely determined.

A manual refresh sends a full conversation request without `modifiedSince`, so it
can remove a stale room missing from the authoritative list. The periodic
foreground loop stays incremental once it has a cursor. If a manual full arrives
behind a running delta, it waits and then starts or joins its own full flight. A
deletion is account-scoped and must not remove a pending outbox or the same token
of another account; a full-empty still requires two different full requests
within the protective window.

An error before the secure and database commit completes leaves no half-created
account. A missing credential, Talk or conversation-v4 surfaces as an explicit
state and does not call an unsupported endpoint.

## Chat and thread UI

Both the phone route and the expanded detail use the same `ChatRoomPane`. The
production widget shows a cache-first timeline, GFM/Rich Object content, images,
reactions, a reply preview, participant avatars, the outbox state and a composer
for text, emoji, Giphy, an image and voice. A new Giphy selection is handed,
after the resolve and validation, into the same durable attachment flow as
`image/gif`; the wire URL must not be created as a new message. The historical
URL renderer remains only for compatible reading of older messages. The root and
every thread have a separate `(accountId, roomToken, threadId|null)` scope. A
valid new thread can be opened even before the first reply.

Two widget-integration tests use the production `ChatService`, the HTTP adapter,
the Drift repository and the Riverpod projection with a deterministic
`MockClient`. For the root as well as a thread they verify the future requests
`timeout=0 → 30 → 0`, accepting cursor 120, the convergent state after a
subsequent `304`, displaying an external message and an empty opposite scope.
This is automated wire-adapter evidence, not a real server socket or a
web↔emulator E2E.

The thread-scoped merge also restores a cached original from a complete embedded
parent only on an exact match of the room/thread identity. If the server-side
`threadReplies` is missing, the repository derives the count from unique scoped
reply IDs, leaves out the original and the replay, and does not lower a higher
cached count. An explicit server count stays authoritative. The repository test
passed 7/7 and kept the reply out of the root timeline.

The composer distinguishes an ordinary reply thread from a server-side named
thread. A reply sends `replyTo`; a named thread under the local capability
`threads` sends only `threadId`. The text-send replay contract r2, the HTTP
adapter and Drift schema v5 preserve this binding. A file-backed reopen test
holds the `threadId` of both a queued and a sending operation, restart recovery
converts an interrupted `sending` into `awaitingConfirmation`, and a correctly
bound named-thread confirmation atomically updates the cached root `threadId`,
`isThread` and `threadReplies`. A direct response is parentless; a history/future
confirmation may carry an exactly bound full root or a compact deleted root. This
slice has no live server or current APK evidence yet.

## Historical Android Giphy wire-reference runtime

The debug APK in
`apps\mobile\build\app\outputs\flutter-apk\app-debug.apk` has SHA-256
`0d38d4ab2a665883d0ee0de7426f201c107cefc6b5f7e701b1c856255f6195cf` and a size of
203,683,536 B. The artifact corresponds to commit `5f6e2f4`. On 25 August 2026 it
was update-installed on `emulator-5554` through `adb install -r`; the SHA-256 of
the installed `base.apk` is identical.

On this hash, Login Flow v2 including a second factor and access approval really
passed, the signed-in conversation list was loaded and a room detail was opened.
The account survived another update install as well as terminating and starting
the process again. Two measured cold starts finished in 5094 ms and 4587 ms.

A Giphy wire-reference send in an open room displayed an animated GIF inline
without a visible or clickable URL. Two crops taken at different times had
different hashes, so it was not a static preview. After the process was
terminated, the wire-reference message stayed stored and was rendered again.
After a cold start, loading the remote media took roughly eight seconds; a short
banner about a temporarily unavailable chat disappeared after a retry. That is a
known runtime signal for further diagnostics, not a lost message.

This run is evidence of the historical renderer, not of the new Giphy attachment
flow. A new send has to end with a real `image/gif` attachment through
Draft/WebDAV/finalize; commits `5d49cbb` and `9de5727` so far prove only the
preparation of the bytes and the admission into the media composer.

This run does not yet prove a live Giphy/image/voice attachment send and viewer,
a cross-device root/thread refresh or a real Nextcloud → FCM flow in a
background/killed process.

## Historical post-review Windows release runtime smoke

On 24 August 2026 Flutter 3.44.4 built a Windows x64 release bundle in 76.7 s on
top of a source snapshot with 150 inputs, SHA-256
`847e81f27311e5ce1ae37169e989a3dab497825aa21f3c53f1c722b1bd98030d`, which stayed
identical before and after the build. The launched `nextcloudtalk.exe` had SHA-256
`5339f4f0d8caf04da2152a2ca5ddf32cd2ff9f26e259a24660e764c84a43af9e` and the Dart
AOT `data/app.so` SHA-256
`01a4cb3cf65bc4f4147e741a9deb1fd584c169ff275105d6eae4da64dfeffa62`. The process
in the `NKS Talk` window displayed the dark expanded onboarding "Všechny
konverzace v jedné aplikaci" and after 356.7 s it was still alive and responsive.
The manifest of the 17 files of the release bundle was verified again 17/17
without errors; the redacted runtime metadata and the screenshot are in the
ignored folder `.artifacts/windows-smoke-post-review-20260824-142126`. All 10
JSON evidence files parse, the screenshot is a valid 1920×1032 PNG and the build
log contains no warning, error, failed or exception. A scan of ten text pieces of
evidence against seven secret/path patterns had 0 findings.

This smoke test had no stored account and no credentials. It therefore does not
verify the Login Flow, secure storage, chat, two servers, restart/upgrade, the
installer or signing. Windows UI Automation only saw the root of the Flutter
window and no children, so nothing about Windows screen-reader or keyboard
accessibility can be claimed from this run.

## Historical real thread smoke

The previous debug APK SHA-256
`<fingerprint>` was
update-installed on `chatujmePixel` on 24 August 2026. The cold start preserved
the authenticated account. An existing thread was opened from the root timeline
through `Open thread` and an anonymized scenario proved:

- one new web thread reply appeared in the foreground Flutter in 2.3 s;
- the thread root was rendered exactly once;
- a redundant parent preview was not rendered at all;
- the new reply did not appear in the root timeline;
- the reply counter on the root updated to 4.

This historical smoke test does not prove the same behaviour on the new
post-review APK, the reverse direction from the Flutter composer into the web
Talk, or the whole bidirectional E2E.

## Historical UI, contrast and avatars

The installed `base.apk` read back from the device has, per `sha256sum`, exactly
the same SHA-256 as the local build of the time:
`<fingerprint>`.

For this hash the harness produced a light, a dark and a light-200-percent
capture. All three screenshots visually show the thread, the date, the root, 4
replies and the composer without a layout defect. The explicit pixel report
passed 24/24:

- a text minimum of 7.2725:1 against a limit of 4.5:1;
- a UI minimum of 3.252078:1 against a limit of 3:1.

The redacted process-scoped logcat has no warning, error, fatal or known UI
diagnostic. After the run, the harness really restored the original state of the
device: `night=yes`, `font_scale` unset/null again, and the application process
running.

The runtime conversation list displayed 9 visible tiles and 9 avatars: 3 network
images, 4 fallback icons and 2 sets of initials. A real incoming group message
had a participant avatar; an outgoing-only test thread correctly displays no
avatars. A separate avatar pixel report passed 4/4 with a minimum UI icon of
7.2725:1 and initials text of 7.2739:1.

## Historical bidirectional thread baseline

On 24 August 2026 the older debug APK SHA-256
`1c4372cad3bbf3f7b1d56664c5da9f353be24bb2b456a919b2393cd6879ba861` proved two web
replies in different polling cycles, their absence from the root timeline and a
reply from the Flutter thread composer delivered into the web Talk. That run
remains a historical transport baseline; it does not re-verify the changes in the
previous runtime APK or in the current build.

Neither the test room token nor the message texts are stored in the
documentation. The temporary room was removed on 2026-08-24 through the
persistent web E2E session; a follow-up snapshot verified its absence from the
list and that the signed-in session was preserved.

## Adaptive layout

A phone below 720 logical px uses the compact stack. From 720 px onwards, three
panes are shown in the order account rail, conversation list and detail. The list
is 330 px, and from 1100 px onwards 390 px; the detail consumes the remaining
space. From 900 px onwards, the onboarding moves from a vertical flow to the
intro and the server card side by side.

The same widget tree serves a tablet, a foldable and a desktop. The desktop is
not a second application and does not share data through another server service.
Keyboard shortcuts, the system tray, auto-start and delivery while the desktop
application is fully terminated are not implemented yet and must not be presented
as done.

## Runtime and test evidence

- Flutter analyze at commit `5f6e2f4`: 0 findings.
- The aggregate Flutter gate at commit `3c74165`: 354 passing tests, 1 read-only
  live test skipped only without environment credentials and 0 failures.
- The historical exact Giphy wire fix `5f6e2f4`: 11/11 targeted and 75/75 broader
  chat/Giphy tests. It is not evidence of the new attachment flow.
- The new Giphy attachment wiring `7ca580e`: the whole
  `chat_composer_integration_test.dart` 4/4, loader/media composer 15/15 and a
  scoped analyze of the changed files with no findings. The test verifies zero
  Giphy text-sends, the exact uploaded bytes and a Talk finalize of the hashed
  `.gif` name.
- Server-backed read and silent background polling `e4840e5` + `02b79eb`: the
  status/live-sync suite 11/11 and a scoped analyze of five changed files with no
  findings. `read` requires a server-confirmed message and the common-read
  cursor; `delivered` is not created.
- The Android Web Push coordinator `c37bf66`: coordinator 21/21, push/API 39/39,
  the whole Flutter analyze and the debug APK build passed. The retry is
  account-scoped, exponentially bounded and only for documented transient errors;
  that does not prove real provider delivery.
- The whole of `talk_protocol`: 569/569; the fresh targeted conversation suite of
  25 August 2026: 74/74.
- The fresh scoped Flutter foundation/conversation suite: 60 PASS, 1 read-only
  live SKIP only without environment credentials. It covers onboarding, the
  account repository, the HTTP adapter, Drift migrations, full/delta sync, the
  foreground loop, avatars and the adaptive shell.
- The Android Web Push native gate at commit `3c74165`: Kotlin unit 16/16 and the
  connected test on `emulator-5554` 15/15. The callback is injected in the test;
  this is not evidence of real provider delivery.
- The avatar repository/widget and the migrations additionally verify the
  immutable versioned cache, ETag revalidation, the offline stale fallback,
  isolation of the same URL between accounts, generated/custom rendering and the
  v2/v3 → v4 upgrades.
- The current Android debug APK build and `adb install -r`: successful. The local
  and the installed artifact both have SHA-256
  `0d38d4ab2a665883d0ee0de7426f201c107cefc6b5f7e701b1c856255f6195cf`.
- On the historical APK a real Login Flow, the conversation list, opening a room,
  an inline Giphy wire-reference send and a process-death return all passed. Two
  cold starts took 5094 ms and 4587 ms.
- The historical Windows x64 release build and onboarding runtime: successful;
  the EXE SHA-256
  `5339f4f0d8caf04da2152a2ca5ddf32cd2ff9f26e259a24660e764c84a43af9e`, the Dart AOT
  SHA-256 `01a4cb3cf65bc4f4147e741a9deb1fd584c169ff275105d6eae4da64dfeffa62`,
  17/17 bundle hashes and 356.7 s of a responsive process.
- The previous APK hash
  `<fingerprint>`
  historically proved a cold start, opening a thread, receiving a new web reply
  in 2.3 s and root/thread isolation. The bidirectional web round trip is
  documented only by the even older APK listed above.
- The previous hash
  `<fingerprint>` has a
  historical light/dark/200% thread pixel report of 24/24 PASS, an avatar report
  of 4/4 PASS and a redacted process logcat without warnings, errors and UI
  diagnostics. The current hash does not inherit this historical evidence.
- The historical Windows debug `kernel_blob.bin`: SHA-256
  `78fc9e2a9b104eb3ac4da54887e9741c15be1d524b89edd5ff11c9f0473432a0`.

A debug cold start is not a release performance benchmark. Real Nextcloud → FCM
delivery in a background/killed process, real radio changes and long-term
consumption have to pass on a physical Android device.

The widget a11y contracts verify that the selected room is the only labelled
semantic button with the selected state, a value of preview/time/unread and a
target of at least 48 dp. The chat header and the composer grow at 200% text, an
avatar next to a visible author does not create a duplicate image node, and an
inline link is the only semantic link with a tap action, a target of at least
48×48 dp and wrapping at 200% text. The composer has exactly one named editable
semantics node with `setText` and a tap action. These tests do not replace an
actually spoken TalkBack or a runtime screenshot.

## Historical thread contrast, 200% text and TalkBack

The following evidence belongs to the older APK SHA-256
`1c4372cad3bbf3f7b1d56664c5da9f353be24bb2b456a919b2393cd6879ba861`. The real
screenshots `nctalk-thread-light-final.png` and `nctalk-thread-dark-final.png`
are in the ignored local `.artifacts` folder; because of the test data they are
not committed. A PIL computation over the real pixels measured:

| Element | Light theme | Dark theme |
| --- | ---: | ---: |
| message text | 7.27:1 | 7.27:1 |
| time | 5.03:1 | 5.55:1 |
| reply author | 9.40:1 | 11.63:1 |
| reply text | 9.36:1 | 11.61:1 |
| system message and date | 8.88:1 | 11.15:1 |
| primary element | 6.16:1 | 11.17:1 |
| send icon | 6.50:1 | 7.77:1 |
| header | 16.24:1 | 14.62:1 |
| separator | 3.25:1 | 3.36:1 |

The light composer border had 6.50:1. The measured thread therefore met the
minimum of 4.5:1 for text and 3:1 for UI elements in both themes on that older
APK.

The screenshot `nctalk-thread-light-font200.png` captures a real font scale of
2.0. The messages wrapped, the header and the composer stayed available and the
logcat contained no RenderFlex or other layout error.

The TalkBack service was really bound and `touchExplorationEnabled=true`. The
Flutter semantics test confirms exactly one named editable composer node with
`setText` and a tap action. The Flutter Android AccessibilityBridge maps the
label/hint of a text field into `AccessibilityNodeInfo.hintText`, while the
uiautomator XML does not serialize `hintText`; its `NAF=true` is therefore a
false positive. A subsequent temporary UiAutomator JAR probe outside the repo
read `AccessibilityNodeInfo` directly and passed 1/1: `editorCount=1`,
`hintMatchesExpected=true`, the hint had a length of 15 (`Write a message`),
`editable=true` and a click action. Both the text and the `contentDescription`
were empty per the bridge. Before and after the probe the accessibility values
were exactly `0/null/0/null`; neither the APK nor the app data changed and the
host/device temp artifacts were removed. The runtime platform name of the
composer is therefore PASS. Audible TalkBack speech was not listened to and
broader screen-reader navigation stays open.

`mobile_audit.py` returned 48 heuristic regex matches. A manual check against the
widgets, the semantics dumps and the runtime result confirmed them as false
positives. The script remains a supporting signal, not a pass/fail gate; the
decision is made by the combination of tests, a manual audit, the runtime and the
pixel measurement.

## Foundation contrast evidence

Both the light and the dark onboarding passed a screenshot of a real Android run.
The Windows release smoke separately captured the dark expanded onboarding, but
contained no pixel WCAG measurement and no accessibility tree children. The
following pixel computation after compositing the real colors belongs to the
Android evidence:

| Element | Light theme | Dark theme |
| --- | ---: | ---: |
| main text | 16.24:1 | 14.62:1 |
| secondary text | 8.88:1 | 11.15:1 |
| card outline | 3.43:1 | 3.50:1 |
| field outline | 4.97:1 | 4.36:1 |
| button text | 6.50:1 | 7.77:1 |

On a real raster, a one-pixel outline composited into two half pixels and did not
reach 3:1. The production theme therefore uses a two-pixel outline for fields,
cards and outlined buttons, and a test guards this minimum width. The previous
runtime APK has its own light/dark and 200% thread runtime and pixel evidence
above. Neither the current APK nor further screens inherit this historical
evidence. The historical runtime `getHintText` evidence of the composer passed;
the screen-reader gate is still waiting for audible speech and broader
TalkBack/VoiceOver navigation, not for a fix of the composer semantics.
