# NKS Talk Flutter client

An original multi-server and multi-account Flutter client compatible with
Nextcloud Talk. One source tree builds the application for Android, iOS, Windows,
macOS and Linux under the identity `com.nkshub.nextcloudtalk`.

## Currently implemented

- Nextcloud URL normalization, status, Login Flow v2 and authenticated
  capabilities;
- app password storage through the platform secure storage;
- an account-scoped Drift database and switching between multiple accounts;
- capability-first synchronization of the conversation list through conversation
  v4;
- cache-first root chat and threads through the production path
  `ChatRoomPane → ChatService → HTTP → Drift → Riverpod → UI`;
- account/room/thread-scoped history and future synchronization with isolation of
  the root and the threads and foreground polling `0 → 30 → 0`;
- a text composer and send with `referenceId`, a confirmed result and an explicit
  state for an ambiguous send that risks a duplicate;
- opening an existing as well as a still empty thread, GFM/Rich Object content,
  links, images, reactions and a reply preview;
- participant avatars from the same server origin with a safe local fallback;
- a single editable composer semantics node and a platform name verified directly
  in the Android runtime through `AccessibilityNodeInfo.getHintText`; the XML
  `NAF=true` is a false positive, because `hintText` does not serialize;
- Czech and English localization, light and dark theme;
- a compact phone shell and an adaptive tablet/desktop shell;
- Android and Windows debug builds; the current APK has an incoming Android
  thread smoke test, an older APK a separate historical bidirectional thread E2E,
  and the current runtime verification of the thread in both themes and at 200%
  text size.

The whole Talk client is not finished yet. Root history/read-unread, an outbox
restart, attachments, voice, Giphy, push, calls, iOS/macOS/Linux, an audible
TalkBack verification and a broader screen-reader audit still need separate
runtime evidence. The presence of a button or a platform folder does not count as
a finished feature.

## Adaptive layout

<!-- markdownlint-disable MD013 -->

| Width | Layout |
| --- | --- |
| less than 720 logical px | top bar, account switcher and conversation list; the detail opens as a further route |
| 720 to 1099 logical px | 88px account rail, 330px list and a separate detail |
| 1100 logical px and more | 88px account rail, 390px list and a wider detail |

<!-- markdownlint-enable MD013 -->

From 900 logical px onwards the onboarding folds into two columns. Resizing the
window recomputes the layout without changing the data or navigation model.

## Local verification

~~~console
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
flutter build windows --debug
~~~

Building macOS and iOS requires macOS/Xcode. The Linux build is verified on a
Linux host. Android does not use `google-services.json`; the target Web Push flow
is registered at runtime according to the capabilities of the specific Nextcloud
server.

The detailed record is in the
[Flutter foundation document](../../docs/architecture/flutter-foundation.md) and
in the maintainer notes' completion audit (not part of this repository).

## License

The source code is available under `GPL-3.0-or-later`; the canonical text is in
the root [LICENSE](../../LICENSE) file.
