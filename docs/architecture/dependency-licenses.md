# Dependency and asset audit

Date of the last check: 3 September 2026.

This document is a continuous distribution gate for a project licensed under
`GPL-3.0-or-later`. The record is based on a specific lockfile and the license
file of the downloaded package; the package description or a badge on a website
is not enough on its own.

## Direct runtime dependencies of `talk_protocol`

<!-- markdownlint-disable MD013 -->

| Component | Version and integrity | License and notice | Use | State |
| --- | --- | --- | --- | --- |
| [`punycoder`](https://pub.dev/packages/punycoder) | 0.3.0; SHA-256 `982734df864d9588eb13e28ac1c5a46b57e22117b3696032ac58739966cec190` in `packages/talk_protocol/pubspec.lock` | MIT; Copyright 2025 dropbear-software; the notice must stay in the distribution materials | RFC 3492/IDNA conversion of a Unicode hostname into the canonical ASCII form | Compatible with GPL-3.0-or-later; the source package and the local LICENSE verified |
| [`markdown`](https://pub.dev/packages/markdown) | 7.3.1; archive SHA-256 `ee85086ad7698b42522c6ad42fe195f1b9898e4d974a1af4576c1a3a176cada9` in `packages/talk_protocol/pubspec.lock`; local LICENSE SHA-256 `0aa335b5e036b9efbb35ad7a35835cd32e4eb656c08bfe040550a9f6fa84fcc7` | BSD-3-Clause; Copyright 2012, the Dart project authors; the notice and the disclaimer must stay in the source as well as the binary distribution | The GFM AST for converting a message into our own safe Rich Object semantic tree | Compatible with GPL-3.0-or-later; the source package and the local LICENSE verified |
| [`xml`](https://pub.dev/packages/xml) | 7.0.1; archive SHA-256 `67f0aff7be013d107995e9b75bf4e7f2c3ef2dfdb2c8e68024bba0a7fd5756a4` in `packages/talk_protocol/pubspec.lock`; local LICENSE SHA-256 `0be767174b97278f17da4923a74169e8645631f03ea3d8482ec3523c9b1a0dd3` | MIT; Copyright 2006–2026 Lukas Renggli; the notice must stay in all substantial copies | A namespace-aware WebDAV multistatus parser behind our own UTF-8, DTD/entity and resource budget boundary | Compatible with GPL-3.0-or-later; the source package and the local LICENSE verified |

<!-- markdownlint-enable MD013 -->

## Direct Flutter runtime dependencies

The following table covers the direct dependencies declared in
`apps/mobile/pubspec.yaml`; `geolocator` and `pasteboard` are still missing from
it and need to be added. The versions and archive SHA-256 come from
`apps/mobile/pubspec.lock`; the licenses and their SHA-256 were verified in the
corresponding downloaded package in the local Pub cache.

<!-- markdownlint-disable MD013 -->

| Component | Version and integrity | License and notice | Use |
| --- | --- | --- | --- |
| [`app_badge_plus`](https://pub.dev/packages/app_badge_plus) | 1.3.4; archive SHA-256 `a22719127af1b80c6d5803fb80c02b600ceb14f726210c12b6198fe11b8bc025`; LICENSE SHA-256 `23f2a5ed6e28c323d4cfa58fb051da600c32d5fa715c11bdaefa629d8f656093` | MIT; Copyright 2024 LioLin | Setting the count on the unread badge of the application icon (Android/iOS/macOS); chosen for the MIT license, active maintenance and the `isSupported()` API, thanks to which a launcher without support stays a no-op |
| [`audioplayers`](https://pub.dev/packages/audioplayers) | 6.8.1; archive SHA-256 `2ba4bb2944baacbdd5372ff8254a8e7feb8c10d7739545e392f5605a8f618745`; LICENSE SHA-256 `d6c0bdbc83e6bb5f02eed5caf25e6edf174cb56d0ecd6fe19a2cd05b62bbda41` | MIT; Copyright 2017 Blue Fire | Playback of locally prepared voice messages |
| [`crypto`](https://pub.dev/packages/crypto) | 3.0.7; archive SHA-256 `c8ea0233063ba03258fbcf2ca4d6dadfefe14f02fab57702265467a19f27fadf`; LICENSE SHA-256 `ad6a71997da90924b2cfb1fb47ec46537f70faf469efe016168794ae45ed6888` | BSD-3-Clause; Copyright 2015, the Dart project authors | SHA-256 integrity of the durable attachment copy |
| [`cupertino_icons`](https://pub.dev/packages/cupertino_icons) | 1.0.9; archive SHA-256 `41e005c33bd814be4d3096aff55b1908d419fde52ca656c8c47719ec745873cd`; LICENSE SHA-256 `310d6ab6483280280c9db122bded0a63c09558bc5743720f61dbcbb494db370a` | MIT; Copyright 2016 Vladimir Kharlampidi | The Cupertino icon font for the iOS look |
| [`emojis`](https://pub.dev/packages/emojis) ([upstream](https://github.com/i-Naji/emojis)) | 3.2.0; archive SHA-256 `36d382349255a3d90a33fa5e01b57b5213578d90a493aad98d2955dac79df74f`; LICENSE SHA-256 `9f2d0499872d61cb552aad0fafa912711b0fd83f855ef3ce28f0359240f5ec2b` | BSD-3-Clause; Copyright 2020 Naji; the notice and the disclaimer must stay in the source as well as the binary distribution | The complete Unicode 17.0 catalog for the search and the categories of the emoji picker |
| [`file_selector`](https://pub.dev/packages/file_selector) | 1.1.0; archive SHA-256 `bd15e43e9268db636b53eeaca9f56324d1622af30e5c34d6e267649758c84d9a`; LICENSE SHA-256 `420f7739f169097f0aad1242045169cd643c8f1d94e62866fad265ae4c369b7d` | BSD-3-Clause; Copyright 2013 The Flutter Authors | Platform selection of an image attachment |
| [`desktop_drop`](../../packages/desktop_drop/UPSTREAM.md) | Local desktop-only `0.8.3+nks.1`; upstream 0.8.3 archive SHA-256 `4c639b4cb80780d1cb94c3252309772e5e68522372181497bc9cd2fbd973aec1`; LICENSE SHA-256 `54bb187c3c4d8d9e74475f69b63a70798fb80581c334b2da487d1c4c70f68155` | Apache-2.0; the upstream copyright and the full text preserved in the package | Dragging a file into an open conversation on macOS, Linux and Windows; the Android/web targets are deliberately left out |
| [`local_auth`](https://pub.dev/packages/local_auth) | 3.0.2; archive SHA-256 `ecf24edf2283c509ecd217e3595f6f71034b68888d28ad1dae6bfa0857b816ac`; LICENSE SHA-256 `420f7739f169097f0aad1242045169cd643c8f1d94e62866fad265ae4c369b7d` | BSD-3-Clause; Copyright 2013 The Flutter Authors | Android/iOS system device authentication for the app lock; the application never reads biometric data |
| [`flutter_riverpod`](https://pub.dev/packages/flutter_riverpod) | 2.6.1; archive SHA-256 `9532ee6db4a943a1ed8383072a2e3eeda041db5657cdf6d2acecf3c21ecbe7e1`; LICENSE SHA-256 `757d9c09a9a2a701144328c0fd596234ea287ff62952b39cd22f9ad4caed1171` | MIT; Copyright 2020 Remi Rousselet | Account-scoped application and UI state |
| [`http`](https://pub.dev/packages/http) | 1.6.0; archive SHA-256 `87721a4a50b19c7f1d49001e51409bddc46303966ce89a65af4f4e6004896412`; LICENSE SHA-256 `3c32b53167c7dae9190c38dab5dd9fe1789c53623ebc7d1babcb29914c5b3f16` | BSD-3-Clause; Copyright 2014, the Dart project authors | The Nextcloud HTTP transport |
| [`mime`](https://pub.dev/packages/mime) | 2.0.0; archive SHA-256 `41a20518f0cb1256669420fdba0cd90d21561e560ac240f26ef8322e45bb7ed6`; LICENSE SHA-256 `ff15faa32a2e638107b7789592b14426162a75ba620044ee2340a20ec6ce5e73` | BSD-3-Clause; Copyright 2015, the Dart project authors | Verification of the MIME type of the selected attachment |
| [`path`](https://pub.dev/packages/path) | 1.9.1; archive SHA-256 `75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5`; LICENSE SHA-256 `3c32b53167c7dae9190c38dab5dd9fe1789c53623ebc7d1babcb29914c5b3f16` | BSD-3-Clause; Copyright 2014, the Dart project authors | Safe handling of names and paths of durable attachments |
| [`path_provider`](https://pub.dev/packages/path_provider) | 2.1.6; archive SHA-256 `a7f4874f987173da295a61c181b8ee71dab59b332a486b391babf26a1b884825`; LICENSE SHA-256 `420f7739f169097f0aad1242045169cd643c8f1d94e62866fad265ae4c369b7d` | BSD-3-Clause; Copyright 2013 The Flutter Authors | The application directory for durable media copies |
| [`record`](https://pub.dev/packages/record) | 7.1.1; archive SHA-256 `82539d1372e23cf51375fdfcba084f39912bcbf9a953b75d56596691f8f11c0f`; LICENSE SHA-256 `5a21ee0d2585baccfde18aeb045037701172460213db723e9d189ca1922aaf79` | BSD-3-Clause; Copyright 2022 openapi4j authors, as stated by the package | Platform recording of a voice message |
| [`url_launcher`](https://pub.dev/packages/url_launcher) | 6.3.2; archive SHA-256 `f6a7e5c4835bb4e3026a04793a4199ca2d14c739ec378fdfe23fc8075d0439f8`; LICENSE SHA-256 `89519eca6f7b9529b35bdddd623a58c3af06a88c458dbd6531ddb4675acf75a9` | BSD-3-Clause; Copyright 2013 The Flutter Authors | System opening of the Login Flow and of safe links |
| [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage) | 11.0.0; archive SHA-256 `15e8c8fe269fdf7d469b23008ab3df521c8b826ed345820532364c31bdebace6`; LICENSE SHA-256 `55dafb084270616f95b9bea53654adda8bdcad95c022a83c4cf8769073f829fa` | BSD-3-Clause; Copyright 2017 German Saprykin | Keystore/Keychain-backed storage of the app password |
| [`flutter_svg`](https://pub.dev/packages/flutter_svg) | 2.3.0; archive SHA-256 `35882981abcbfb8c15b286f0cd690ff25bac12d95eff3e25ee207f37d4c42e7f`; LICENSE SHA-256 `dc54ae36c905edfbf3c6678ee34d8da5989d7ccc7b993857a9d89db06a67eb18` | MIT; Copyright 2018 Dan Field | Safe display of supported SVG media |
| [`drift`](https://pub.dev/packages/drift) | 2.34.3; archive SHA-256 `3a3f1f6f905037d7426e4c445854139fd6a3d592135f7c96d7931682b73d16f4`; LICENSE SHA-256 `31f84e4edff98f0238a5bef1c2ce754e401fbab149782f0ff4dc9b68fd086f75` | MIT; Copyright 2021 Simon Binder | A typed account-scoped SQLite repository and transactions |
| [`drift_flutter`](https://pub.dev/packages/drift_flutter) | 0.3.1; archive SHA-256 `91acf4bee7c3c84467cba46455aa70e5292a3b889f4582645d74f2e5a8c106f2`; LICENSE SHA-256 `7cf86321e740e4ff631ab6d00962c2d65fa85e4163bdd89334f1d22354ab0306` | MIT; Copyright 2024 Simon Binder | Flutter platform opening of the Drift database |
| [`uuid`](https://pub.dev/packages/uuid) | 4.6.0; archive SHA-256 `9b129329f58692f6e6578329498a8fe9fbe98f090beb764ffbb8ee2eadd01dcd`; LICENSE SHA-256 `ad3e5523e51004e94ba9ce728805b1b4242dbccdb65e62b523800e35a8a7cfdc` | MIT; Copyright 2021 Yulian Kuncheff | Random local account and operation identities |
| [`connectivity_plus`](https://pub.dev/packages/connectivity_plus) | 7.3.1; archive SHA-256 `762c99f890ca8bf87f7337236f99edd42793843bc6c3631da294a76653a54bd0`; LICENSE SHA-256 `3b38d48befd0af70b892e13d10c9e34679416c24a9277f962629951c64d71f4c` | BSD-3-Clause; Copyright 2017 The Chromium Authors | Detecting a return of connectivity as a wake source for polling and resync |
| [`open_filex`](https://pub.dev/packages/open_filex) | 4.7.0; archive SHA-256 `9976da61b6a72302cf3b1efbce259200cd40232643a467aac7370addf94d6900`; LICENSE SHA-256 `15fead662602c03b70cedc27bb301ca0722648fbc222dd3d7d06d9dd3c3fc2ad` | BSD-3-Clause; Copyright 2018 crazecoder | Opening an already downloaded attachment in a system application through the Android FileProvider |
| [`gal`](https://pub.dev/packages/gal) | 2.3.3; archive SHA-256 `f71e79840fe023a21f2f949771375444b6efcd34b9e625d5f4f5504971380a77`; LICENSE SHA-256 `4a963156383f276c9214aed3beee1a57e12947c63b58dae134fdae6abd01b3da` | MIT; Copyright 2023 Midori Design Studio | Saving an attachment into the system gallery (MediaStore, PHPhotoLibrary) |
| [`share_plus`](https://pub.dev/packages/share_plus) | 13.3.0; archive SHA-256 `34f00f9becd2743c1fb05363d624f9f70d37f7ccdcdda47450bc0b8c9d327b8c`; LICENSE SHA-256 `eb9741a672906ebd01fd9b3bef38f6c82eff250e91149cf404539ee7981079fd` | BSD-3-Clause; Copyright 2017, the Flutter project authors | The system share sheet (ACTION_SEND, UIActivityViewController) |
| [`image_picker`](https://pub.dev/packages/image_picker) | 1.2.3; archive SHA-256 `d8402284df184bc05f4a2210c6c23983b0720f4cd87cbd05c5390a78af602667`; LICENSE SHA-256 `8e22fae63e4e8ac897f0cb3018ed94ed730b3e5da5d42c6856a26ba524f0fd88` | BSD-3-Clause; Copyright 2013 The Flutter Authors | Only the "camera" source (ACTION_IMAGE_CAPTURE, UIImagePickerController) |
| [`camera`](https://pub.dev/packages/camera) | 0.12.1; archive SHA-256 `3f30ca0ff376f91534f23afa2a7aea06ebb6c889fd9e260642437b37e3d9f753`; LICENSE SHA-256 `420f7739f169097f0aad1242045169cd643c8f1d94e62866fad265ae4c369b7d` | BSD-3-Clause; Copyright 2013 The Flutter Authors | The live preview and frame stream for the QR onboarding scanner; used only on Android and iOS, video is never started |
| [`zxing2`](https://pub.dev/packages/zxing2) | 0.2.4; archive SHA-256 `2677c49a3b9ca9457cb1d294fd4bd5041cac6aab8cdb07b216ba4e98945c684f`; LICENSE SHA-256 `d2bfc0fd9aae0a7d4cdab8ea024c75881c0ab38332683539f7f26ea88fec9ca2` | BSD-3-Clause; Copyright 2023 zxing-dart | Purely Dart decoding of a QR code from a luminance frame; no native or platform part |
| [`flutter_webrtc`](https://pub.dev/packages/flutter_webrtc) | 1.6.1; archive SHA-256 `a2eb4a45bf741c4e3fb6731dbbe35daef5f366c3783645e091d03f205b70b733`; LICENSE SHA-256 `11a88e16f8841bf63a968da35e951edc8a27b2cfb6cdc2a49b00198678dd502b` | MIT; Copyright 2018 湖北捷智云技术有限公司 | WebRTC media for Talk calls: the local audio track, one peer connection per participant, and the SDP and ICE that the existing signalling carries |
| [`sentry_flutter`](https://pub.dev/packages/sentry_flutter) | 9.27.0; archive SHA-256 `ec89cc6ba939ca19155ea83900d9740a36544f50b3b6baf265518e3348fb0f50`; LICENSE SHA-256 `a324d0c2ce63dbdce9e77cbd06a13ad77006d6bf3f82ad3affe03b64e27e83d6` | MIT; Copyright 2019 Sentry | Crash reporting only in our builds; without `SENTRY_DSN` the SDK is not initialized at all |
| [`rybbit_flutter_sdk`](https://pub.dev/packages/rybbit_flutter_sdk) | 0.3.0; archive SHA-256 `96581119b39b195690b4cd9a88283293d0bd7efc82aefce817750ec7924761fe`; LICENSE SHA-256 `e57f1c320b8cf8798a7d2ff83a6f9e06a33a03585f6e065fea97f1d86db84052` | GPL-3.0; Copyright Free Software Foundation text, own code by nks-hub; the same license as the project | Anonymous screen usage only in our builds; without `RYBBIT_HOST` and `RYBBIT_SITE_ID` the SDK is not initialized at all |

<!-- markdownlint-enable MD013 -->

All the licenses listed are permissive and compatible with distributing the
application under `GPL-3.0-or-later`; their copyright notices and disclaimers
must stay in the resulting third-party notice.

The onboarding QR scanner is deliberately `camera` + `zxing2`, not
`mobile_scanner`. The package `mobile_scanner` 7.4.0 is itself BSD-3-Clause, but
on Android it pulls in `com.google.mlkit:barcode-scanning`,
`…:barcode-scanning-common`, `com.google.mlkit:common`, `…:vision-common`,
`…:vision-interfaces` and
`com.google.android.gms:play-services-mlkit-barcode-scanning`. Their POM declares
"ML Kit Terms of Service" — a proprietary license for which SPDX has no
identifier and which the license gate does not know yet (verified on 3 September
2026 from the POM at `dl.google.com/dl/android/maven2`). The pair `camera` +
`zxing2` solves the same thing and adds not a single extra proprietary artifact
into the APK.

The table is complete for the current direct hosted Flutter packages. The Android
release artifact is additionally covered by the automatic gate described below.
For iOS the same artifact record still has to be created; this state is therefore
not yet a complete multi-platform release clearance.

The direct SDK dependencies `flutter` and `flutter_localizations` come from
Flutter 3.44.4, revision `ad70ec4617166f1c38e5d2bfd388af71fda14f06`. The root
Flutter `LICENSE` is BSD-3-Clause with SHA-256
`a3a9fd82f800a47377f7d3f60c60a5c91cae0495be8f329031e1448ce0f5dab9`.
`talk_protocol` is an internal workspace package under the same project license,
not a foreign distribution dependency.

## Direct Android runtime dependencies for Web Push

The following artifacts come from the current `debugRuntimeClasspath`. The SHA-256
belongs to the AAR/JAR actually downloaded into the local Gradle cache; the
SHA-256 of the license belongs to the file at the exact upstream tag.

<!-- markdownlint-disable MD013 -->

| Component | Version and integrity | License and notice | Use | State |
| --- | --- | --- | --- | --- |
| [`org.unifiedpush.android:connector`](https://codeberg.org/UnifiedPush/android-connector/src/tag/3.3.5) | 3.3.5; tag/commit `04820c8cfe11fe283da50c1a990529fb167eac9d`; AAR SHA-256 `fa017cdfabbdc9af021e1f8c8eff2c8098e701d7a2c599937dce0b4ecf1e929b`; tag LICENSE SHA-256 `65e7ce63d83ef0a5aa7b8a568f0524b7d0943179257f4ba086c4a126d57f08fa` | Apache-2.0; the Maven POM and the tag LICENSE agree | The UnifiedPush registration and callback API | Compatible with GPL-3.0-or-later; keep the Apache license and the notices |
| [`org.unifiedpush.android:embedded-fcm-distributor`](https://codeberg.org/UnifiedPush/android-embedded_fcm_distributor/src/tag/3.1.0) | 3.1.0; AAR SHA-256 `a2e730e33c54a5d59141ac6657b6969375c91e27f64ae9299fab2275e4707291`; tag LICENSE SHA-256 `620e35bd6e6066ee0376391296ff595459584fe135853d8f60434d38693f06cb` | The tag contains the full LGPL-2.1 text, while the published Maven POM declares Apache-2.0 instead | Embedded acquisition of the FCM Web Push endpoint without a second application | The LGPL text is not itself in conflict with GPL-3.0-or-later, but before a release an explicit notice, a corresponding-source/relink audit and resolving the metadata conflict are mandatory; it cannot be recorded as Apache-2.0 yet |
| [`com.google.crypto.tink:tink`](https://github.com/tink-crypto/tink-java/tree/v1.23.0) | 1.23.0; tag/commit `7d41a6435667e6ec543e49ac544ff599b72601c9`; JAR SHA-256 `5bcdc8798ce106f5145acb4a0e993c5e5861337b1e75ca88ceb6ab9da10fa512`; tag LICENSE SHA-256 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` | Apache-2.0 | Transitive Web Push cryptography of the connector | Compatible with GPL-3.0-or-later; keep the Apache license and the notices |

<!-- markdownlint-enable MD013 -->

`flutter_secure_storage` 11.0.0 brings in an unused `tink-android` 1.23.0. Its
classes overlap with the Tink Core 1.23.0 required by the connector and the build
would fail on duplicate classes. The application Gradle configuration therefore
excludes only `tink-android`; the current dependency graph confirms a single Tink
Core 1.23.0. The source of the Android part of `flutter_secure_storage` does not
import the Tink API.

Further transitive JVM dependencies of the connector (`gson`, `protobuf-java`,
`jsr305`, Error Prone annotations) are covered by the exact Android release
classpath, the CycloneDX SBOM and the notice embedded into the APK. The mere
presence of the LGPL text, however, does not replace the distributor's final
corresponding-source/relink clearance.

## LGPL-2.1 distributor: clearance

Decided 2026-09-03. `embedded-fcm-distributor` 3.1.0 is LGPL-2.1 and is compiled
into the APK, so §6 of the LGPL (the possibility of a relink) cannot be satisfied
by shipping object files. The path the LGPL itself offers is §3: the library may
be distributed under the GPL (version 2 or later) as part of a GPL work. NKS Talk
is GPL-3.0-or-later, the distributor is therefore distributed within it under
GPL-3.0-or-later and the obligation towards the recipient of a build is the
complete corresponding source of the whole work — which covers the relink (the
recipient can swap the library and build the work). The repository is private, so
a build carries a WRITTEN OFFER: the Open source licences screen states
GPL-3.0-or-later, the LGPL §3 conversion of the distributor and the availability
of the complete source on request from whoever handed over the build
(`diagnosticsLicensesLegalese`). The SBOM in the APK records the component as
`LGPL-2.1-only` with a hashed license text; the conflict between the Maven POM
(Apache-2.0) and the tag LICENSE (LGPL-2.1) is resolved by taking the STRICTER of
the two, because a POM cannot broaden the license of the sources. The iOS build
does not contain the distributor.

## Direct Android runtime dependencies for WebRTC calls

`flutter_webrtc` 1.6.1 adds exactly two Maven artifacts to the Android runtime
classpath. Both are declared in `release-licenses/components.tsv` and were
verified against the POM in the local Gradle cache, not guessed.

<!-- markdownlint-disable MD013 -->

| Component | Version and integrity | License and notice | Use | State |
| --- | --- | --- | --- | --- |
| [`io.github.webrtc-sdk:android`](https://github.com/webrtc-sdk/android) | 150.7871.01; AAR SHA-256 `0a1627b1a48c2bc17d9a40d62fc47bd45166f44a311e95917f147c402de379b0` from the artifact in the local Gradle cache; notice SHA-256 `a76b141e6bab5f2ac9872a8ad68b1239a1cc23934a4cbd7a9da117c81234fb66` | `BSD-3-Clause AND MIT`. The POM declares "The 3-Clause BSD License" and the AAR contains only `org.webrtc` and `org.jni_zero`, that is the compiled WebRTC and Chromium sources, which are BSD-3-Clause. The repository's own `LICENSE` is MIT and covers the build scripts that package them, so the notice carries both texts | The libwebrtc engine behind `flutter_webrtc` on Android | Compatible with GPL-3.0-or-later; both texts are in `notices/webrtc-sdk-android-bsd-3-clause-and-mit.txt` |
| [`com.github.davidliu:audioswitch`](https://github.com/twilio/audioswitch) | commit `039a35aefab7747c557242fa216c9ea11743b604` resolved through JitPack; AAR SHA-256 `c8240221daa9a96d4ea01a4dc6f6f6b10b4903d2a71f9b57f838bdfeb6c3fcbc`; notice SHA-256 `65e7ce63d83ef0a5aa7b8a568f0524b7d0943179257f4ba086c4a126d57f08fa` | Apache-2.0; the POM points at the upstream `twilio/audioswitch` LICENSE.txt | Audio device routing pulled in by `flutter_webrtc`; the call layer does not call it directly yet | Compatible with GPL-3.0-or-later; the shared Apache-2.0 notice applies |

<!-- markdownlint-enable MD013 -->

JitPack (`https://jitpack.io`) is added to the repositories by the plugin's own
`android/build.gradle`, not by this project. It is where `audioswitch` resolves
from; nothing else in the graph uses it.

## The Android release artifact gate

Commit `94a0987` added fail-closed generation from the exact
`releaseRuntimeClasspath` and `pubspec.lock`. Every Maven artifact must be in
`release-licenses/components.tsv`, every Pub package must be either in the
generated Flutter `NOTICES.Z` or in a separate manifest, and every manually
supplied notice is bound by SHA-256. The build embeds a CycloneDX 1.6 `SBOM.json`
and `THIRD_PARTY_NOTICES.txt` into the release APK; the `assembleRelease`
finalizer reopens the real APK and verifies completeness, the SPDX identifiers,
duplicates, the integrity of the notice and the match with the plugin metadata.

Commit `105302e` additionally binds the Gradle task to the contents of
`android-classes-jar` as well as to the exact Maven coordinates of the runtime
graph. Adding or changing a dependency therefore invalidates the generated assets
even with an unchanged manifest. The regression run first proved a fail-closed
missing `play-services-location:21.2.0`, then invalidation by an artificial change
of the graph, and finally two correct `UP-TO-DATE` runs of a stable graph.

Build 33 passed with 145 Flutter packages and 112 Android runtime components. The
validator has 17/17 unit tests, `bundleRelease` passed 721 tasks and the embedded
SBOM contains `pkg:maven/com.google.android.gms/play-services-location@21.2.0`.
The gate is Android-only; it does not yet cover the iOS artifact and its native
dependency graph.

After `flutter_webrtc` was added, `flutter build apk --release` reported
"release-license gate passed: 160 Flutter packages, 134 Android runtime
components" and produced a 123.1 MB release APK. The two extra Maven components
are the WebRTC ones above; the size is libwebrtc, which ships native code for
every ABI in the fat APK.

## Transitive runtime dependencies

<!-- markdownlint-disable MD013 -->

| Component | Version and integrity | License and notice | Reason it is in the artifact | State |
| --- | --- | --- | --- | --- |
| [`petitparser`](https://pub.dev/packages/petitparser) | 7.0.2; archive SHA-256 `91bd59303e9f769f108f8df05e371341b15d59e995e6806aefab827b58336675` in `packages/talk_protocol/pubspec.lock`; local LICENSE SHA-256 `d2e8ffdbe89acbc10d5d1f2b03e7dbddf0a9f1742e809176682b62ef3d573b3e` | MIT; Copyright 2006–2024 Lukas Renggli; the notice must stay in all substantial copies | The parser runtime required by the `xml` package; the project does not call it directly | Compatible with GPL-3.0-or-later; the source package and the local LICENSE verified |
| [`sentry`](https://pub.dev/packages/sentry) | 9.27.0; archive SHA-256 `c2ecd8abe82e63cdcb6947f71320612ced56e10ba94db7529d85cc02be47cb3b`; local LICENSE SHA-256 `9873d81def9cebb9598b4a2d0a1ad062b17781c35c25cc04b75a0f62fc8667fd` | BSD-3-Clause; Copyright 2014 The Chromium Authors | The Dart core required by the `sentry_flutter` package; the project calls it only through that | Compatible with GPL-3.0-or-later; the source package and the local LICENSE verified |
| [`webrtc_interface`](https://pub.dev/packages/webrtc_interface) | 1.5.1; archive SHA-256 `c6f100eac5057d9a817a60473126f9828c796d42884d498af4f339c97b21014f`; local LICENSE SHA-256 `9a3ad869cb4e3bc3ae6a0150c52245aaba87ea047fe97e53e698a4a40d097b90` | MIT; Copyright 2021 Flutter WebRTC | The platform-neutral WebRTC API `flutter_webrtc` implements | Compatible with GPL-3.0-or-later; the source package and the local LICENSE verified |
| [`dart_webrtc`](https://pub.dev/packages/dart_webrtc) | 1.8.2; archive SHA-256 `078e3c431500147e5cc52b3c6ea41ed538f30c7720cc2467d2186c9251e62716`; local LICENSE SHA-256 `c09fdb792d75d09680fd33e32f5ef73689e771e81c7456e2c1c68dd530fef271` | MIT; Copyright 2020 Flutter WebRTC | The web binding of `flutter_webrtc`; not reached by any of our targets, but resolved by the package | Compatible with GPL-3.0-or-later; the source package and the local LICENSE verified |
| [`hive`](https://pub.dev/packages/hive) | 2.2.3; archive SHA-256 `8dcf6db979d7933da8217edcec84e9df1bdb4e4edc7fc77dbd5aa74356d6d941`; local LICENSE SHA-256 `343c59f5d64c33a9dad6c7a87d9b4b1c3c6ce628f41b85d9e25ef5f960b8f28e` | Apache-2.0; one-way compatible with GPL-3.0-or-later | The offline queue of the `rybbit_flutter_sdk` package for events sent without connectivity | Compatible with GPL-3.0-or-later; the source package and the local LICENSE verified |
| [`device_info_plus`](https://pub.dev/packages/device_info_plus) | 13.2.0; archive SHA-256 `0891702f96b2e465fe567b7ec448380e6b1c14f60af552a8536d9f583b6b8442`; local LICENSE SHA-256 `3b38d48befd0af70b892e13d10c9e34679416c24a9277f962629951c64d71f4c` | BSD-3-Clause; Copyright 2017 The Chromium Authors | The device model and the OS version in the analytics payload of the `rybbit_flutter_sdk` package | Compatible with GPL-3.0-or-later; the source package and the local LICENSE verified |
| [`package_info_plus`](https://pub.dev/packages/package_info_plus) | 10.2.1; archive SHA-256 `127e1751e37ffb2ff4658beeaca77bad0c27bf5f932bd3a501c2296926d4b481`; local LICENSE SHA-256 `3b38d48befd0af70b892e13d10c9e34679416c24a9277f962629951c64d71f4c` | BSD-3-Clause; Copyright 2017 The Chromium Authors | The application version in the analytics payload; the version is forced by `dependency_overrides` in `apps/mobile/pubspec.yaml`, because `rybbit_flutter_sdk` 0.3.0 caps major 9 and with it `win32` below 6, which `share_plus` 13.3 requires. The SDK from the package only calls `PackageInfo.fromPlatform()`, unchanged across majors 8–10 | Compatible with GPL-3.0-or-later; the source package and the local LICENSE verified |

<!-- markdownlint-enable MD013 -->

## Development dependencies

<!-- markdownlint-disable MD013 -->

| Component | Version and integrity | License and notice | Scope |
| --- | --- | --- | --- |
| [`build_runner`](https://pub.dev/packages/build_runner) | 2.15.1; archive SHA-256 `5367e521935b102bdf1e735d2aab461e36b2edca6517662d088dd04cc39f8d16`; LICENSE SHA-256 `a4b5d7d31626e90b77e8696f1c47643aa31f52e17c1907c1ab60b068110e6e10` | BSD-3-Clause; Copyright 2016, the Dart project authors | Generating Drift code; not a runtime dependency |
| [`drift_dev`](https://pub.dev/packages/drift_dev) | 2.34.5; archive SHA-256 `735aad3c34215805c66bd518c8812fa4f83b5534b2c13c4092c970c04a7e9983`; LICENSE SHA-256 `31f84e4edff98f0238a5bef1c2ce754e401fbab149782f0ff4dc9b68fd086f75` | MIT; Copyright 2021 Simon Binder | The Drift build-time generator; not a runtime dependency |
| [`flutter_lints`](https://pub.dev/packages/flutter_lints) | 6.0.0; archive SHA-256 `3105dc8492f6183fb076ccf1f351ac3d60564bff92e20bfc4af9cc1651f4e7e1`; LICENSE SHA-256 `89519eca6f7b9529b35bdddd623a58c3af06a88c458dbd6531ddb4675acf75a9` | BSD-3-Clause; Copyright 2013 The Flutter Authors | Static rules; not a runtime dependency |

<!-- markdownlint-enable MD013 -->

`flutter_test` comes from the same Flutter SDK and is only a dev dependency in
the application. `lints` 6.1.0 and `test` 1.31.2 from `talk_protocol` use the
BSD-3-Clause license of the Dart project; the exact transitive versions are held
by the respective lockfile.

## The pixel evidence tool

`apps/mobile/tool/requirements.txt` pins `Pillow==12.1.0` exactly, but does not
contain a hash pin yet. The verified PyPI wheel
`pillow-12.1.0-cp312-cp312-win_amd64.whl` has SHA-256
`d70534cea9e7966169ad29a903b99fc507e932069a881d0965a1a84bb57f6c6d`. Its metadata
declare `MIT-CMU`; the bundled `LICENSE` has SHA-256
`926df5f888a7337fd4126a435202edf2847312be81a167df91a6d70cfa3f2ed3` and preserves
the notices of PIL, Secret Labs, Fredrik Lundh and the Pillow contributors.
Pillow serves only the host-side screenshot/WCAG harness and is not part of the
mobile or the desktop runtime artifact.

## Tooling of the executable contracts

`contracts/push-client` reuses the same exactly pinned Python tools as the
existing `contracts/push-gateway`; it adds no mobile runtime dependency. The
locally installed metadata of 23 August 2026 confirm:

- `cryptography` 50.0.0: `Apache-2.0 OR BSD-3-Clause`;
- `jsonschema` 4.26.0: `MIT`;
- `openapi-spec-validator` 0.9.0: `Apache-2.0`.

These packages serve only local and CI generation and verification of the
synthetic fixtures. They are not part of the future Android/iOS artifact. Their
exact versions are in `contracts/push-client/requirements.txt` and
`contracts/push-gateway/requirements.txt`. A clean installation of both identical
sets and `pip-audit` on 23 August 2026 found no known vulnerability. The release
notice will be built from the final distributed artifacts, not from the global
Python environment.

## Assets and adopted code

No image, font, sound or implementation code from the official Talk clients was
added. The platform scaffolding does, however, contain standard Flutter assets
that have to be recorded:

- all 31 PNG/ICO icons and launch images in the Android, iOS, macOS and Windows
  targets are, by SHA-256, byte-for-byte identical with the source in Flutter SDK
  3.44.4 or in its exactly pinned package `flutter_template_images` 5.0.0;
- `flutter_template_images` 5.0.0 has archive SHA-256
  `0120589a786dbae4e86af1f61748baccd8530abd56a60e7a13479647a75222fe`
  and a BSD-3-Clause `LICENSE` with SHA-256
  `89519eca6f7b9529b35bdddd623a58c3af06a88c458dbd6531ddb4675acf75a9`;
- the Android launch XML, the iOS storyboard and the other generated platform
  files come from the same Flutter template revision, not from the Talk clients;
- the source `CupertinoIcons.ttf` from `cupertino_icons` has SHA-256
  `67c44fe9183b002e79dde7f6977e2988661c9a3e4a3c5fce968787efdbed823c`
  and follows the MIT license of the package listed above;
- `uses-material-design: true` uses the SDK source `MaterialIcons-Regular.otf`
  with SHA-256
  `d9865b671a09d683d13a863089d8825e0f61a37696ce5d7d448bc8023aa62453`;
  the bundled CC-BY-4.0 text has SHA-256
  `be698262aecd042c0de6f886cc0af622f8def446462026992cc530275d8a9e74`
  and the release notice must preserve its attribution conditions.

Our own brand mark is drawn by application code and adds no separate binary
asset. A debug/release build may tree-shake unused icons or font glyphs; the real
contents and notices are therefore derived again from the final artifacts. The
root GPL text does not change.

## Gate for further changes

Before a commit, every new direct dependency or asset must document:

1. the exact version and integrity from the lockfile;
2. the whole license text from the artifact actually downloaded;
3. GPL compatibility and the mandatory copyright/notice;
4. whether it is part of the distributed runtime, only a build tool, or a dev
   test;
5. the origin of the asset and the permitted modifications or redistribution.

Before a release, a complete third-party notice is created from the final Android
and iOS artifacts. This continuously maintained file does not replace a check of
the transitive runtime dependencies or of the resulting binary package.
