# Apple distribution

The signed iOS build is produced on build-mac through RemoteCmd. This document is a
record of the working procedure and, above all, of the four blockers that came up
along the way — each of them looked like something other than what it was.

## Account and identity

- Team `<team-id>` (the value lives in `Local.xcconfig`, not here). On `developer.apple.com` you have to sign in as the
  **account holder**; an ordinary ASC Admin cannot see the team portal.
- App ID `com.nkshub.nextcloudtalk` ("NKS Talk") with the Push Notifications
  capability.
- App Store Connect record id `6805831712`, platforms iOS and macOS.
- `DEVELOPMENT_TEAM = $(APPLE_TEAM_ID)` is in `ios/Runner.xcodeproj` and in
  `macos/Runner/Configs/AppInfo.xcconfig`.
- An updated Apple Developer Program License Agreement has to be accepted by the
  account holder manually. Until that happens, nothing new can be submitted.

## Universal Links

The Runner has `com.apple.developer.associated-domains` for
`applinks:cloud.example.invalid`. The authoritative AASA document is versioned in
`deploy/reference-server/apple-app-site-association`; it allows only `/call/*`
and `/index.php/call/*` for `<team-id>.com.nkshub.nextcloudtalk`.

The reference server serves it through an exact-path Apache alias from the Git
checkout of commit `2f1d36f`, not from a file placed manually into the Nextcloud
webroot. The public check on 1 September 2026 returned 200, `application/json`,
419 B, no redirect and SHA-256
`0e3b890f8f0d38878f520fa63f8822a50ba31837e1a76a5cbab707d0c8f78e68`. The Apple
developer fetch returns the same document. At that moment the production Apple
CDN still held the previous 404, but it later refreshed to the 419 B JSON with
status 200. An update-installed iOS 18.6 build 33 then accepted a direct
`/index.php/call/...` HTTPS link from another open room, opened "Tym NKS" and the
AX root stayed `NKS Talk`; Safari did not launch.

## Procedure

```sh
flutter config --no-enable-swift-package-manager
flutter clean
flutter pub get
flutter build ios --release --no-codesign --build-number <build> \
  --dart-define-from-file=telemetry.env

xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath <archive> archive \
  -allowProvisioningUpdates \
  -authenticationKeyPath <p8> -authenticationKeyID <id> \
  -authenticationKeyIssuerID <issuer> \
  DEVELOPMENT_TEAM=<team-id>

xcodebuild -exportArchive -archivePath <archive> \
  -exportOptionsPlist <plist with method=app-store-connect> \
  -exportPath <out> -allowProvisioningUpdates <key as above>

xcrun altool --upload-app -t ios -f "<out>/NKS Talk.ipa" \
  --apiKey <id> --apiIssuer <issuer>
```

All of it has to run as a signed-in user, not as root:
`launchctl asuser <uid> sudo -u <user> <script>`.

## Blockers you can hit again

1. **Plugin targets built through the Swift Package Manager ignore
   `DEVELOPMENT_TEAM` from the command line.** It shows up as
   `Signing for "<plugin>" requires a development team` for every plugin
   separately. Switching to CocoaPods fixes it, they do take the team from the
   command line.
2. **`conflicting code signing identity`.** Do not pin `CODE_SIGN_IDENTITY`
   against automatic signing; pass only the team.
3. **`The specified item could not be found in the keychain`.** The build ran as
   root, but the private key of the certificate is in the user's login keychain.
4. **`Permission denied` while reading `~/.pub-cache`.** Root wrote files there
   earlier; return ownership to the user.
5. **Xcode shows an iOS SDK, but `Any iOS Device` is ineligible.** On Xcode 26.3
   with macOS 15.7.4, after removing runtime 26.2 the `iphoneos26.2.sdk`
   remained, and yet archive reported `iOS 26.2 is not installed`.
   `xcodebuild -downloadPlatform iOS` downloaded the newest 26.3.1, which did not
   replace this exact dependency, and the standard catalog no longer offered the
   historical version. The verified recovery uses `xcodes runtimes` and an
   unambiguous runtime build:
   `xcodes runtimes install 23C54 --architecture arm64`. After registration
   `xcodebuild -showdestinations` offered `Any iOS Device` again. The temporary
   `xcodes` and the wrong runtime 26.3.1 were removed after the build; 26.2 stays
   as a necessary part of the toolchain.

## A trap worth a separate mention

`UPLOAD SUCCEEDED` from `altool` is **not** evidence that the build reached
TestFlight. It only means the binary made it to Apple. Validation runs afterwards
and its result is visible in App Store Connect under *TestFlight → Build Uploads*
as `Processing`, `Failed` or `Valid`, or in the API as `processingState`.

Two uploads ended this way as `Failed` with

> `90683: Missing purpose string in Info.plist` —
> `NSPhotoLibraryUsageDescription` is missing

even though the upload reported success. That is why
`apps/mobile/test/ios_app_icon_metadata_test.dart` checks all purpose strings
against the plugins that need them, and `CFBundleIconName` as well: the next
missing key should be a failing test, not a rejected upload.

Saying "it is in TestFlight" is only allowed based on the state of the record,
not on the output of the upload.

## Verification of build 25

Build 25 was produced on 2026-08-31 from the exact commit `175b721`. Both the
archive and the export passed, the IPA has SHA-256
`9D8D42A57FF74F076FC82D2F64656683CBC6DFBCB9A1047CF7A5E091F1CDE485`. The App Store
Connect API then confirmed `processingState=VALID`,
`usesNonExemptEncryption=false` and a minimum of iOS 15.0. The build has Czech
release notes, the beta review is approved and both the internal and the external
group report `IN_BETA_TESTING`.

## Verification of build 26

Build 26 was produced on 2026-08-31 from the exact commit `3dd373e`. The Android
Publishing API accepted `versionCode=26`, committed the closed `alpha` track and
a new edit returns `(26) 0.1.0` in the state `completed`. The AAB has SHA-256
`034D499C55CA61BAAABCB1A46484094DBC3736843675781B90C5242AE7FEED49`.

The iOS archive and export passed after runtime 26.2 was restored. The IPA has
SHA-256 `40716A6719562217DE9F3798306C695E4F173BCDD28EB7EA53AEE6E87479801D`. The
App Store Connect API confirmed `processingState=VALID`, a minimum of iOS 15.0,
`usesNonExemptEncryption=false`, Czech release notes and
`internalBuildState=externalBuildState=IN_BETA_TESTING`. The same bundle launched
on the preserved iPhone 16 Pro Max / iOS 18.6 simulator as build 26; the account
stayed signed in and after a server refresh all temporary room fixtures
disappeared.

After the verification, the 1.7 GB build tree, the temporary `xcodes` tool, the
wrong runtime 26.3.1 and the unused tvOS, watchOS and visionOS runtimes were
removed from build-mac. Only the necessary iOS 18.6 and iOS 26.2 remained, with
41 GiB of free space.

## Verification of build 31

Build 31 was produced on 2026-09-01 from the exact commit `5c52469` with the
telemetry defines for both Sentry and Rybbit. The archive, the export and the
`altool` upload passed; the IPA is 29,724,195 B with SHA-256
`<fingerprint>`. The App Store
Connect API confirmed `processingState=VALID`, a minimum of iOS 15.0,
`usesNonExemptEncryption=false`, Czech release notes and both the internal and
the external group `IN_BETA_TESTING`; the beta review is `APPROVED`.

The same commit passed on the preserved iOS 18.6 simulator with a real PHPicker
asset as well as an older exhausted `retryable` job without a timer. The newer
upload ended `completed`, the older job stayed for manual resolution and a
server-side context request confirmed the created message. The test messages and
the local fixtures were removed after the evidence was collected.

## Verification of build 32

Build 32 was produced on 2026-09-01 from the exact commit `a2cd037` with the
telemetry defines for both Sentry and Rybbit. The archive, the export and the
`altool` upload passed; the IPA is 29,760,109 B with SHA-256
`<fingerprint>`. The App Store
Connect API confirmed `processingState=VALID`, a minimum of iOS 15.0,
`usesNonExemptEncryption=false`, the exact Czech release note, both groups
`IN_BETA_TESTING` and the beta review `APPROVED`.

The same commit was update-installed on the preserved iPhone 16 Pro Max /
iOS 18.6 simulator. The account stayed signed in; the runtime showed the
paperclip, Giphy, emoji, the microphone and Send from the left edge, the
capability-bound Poll, a real conversation list under an interactive edge swipe
and three identical threads after two pull-refresh gestures. After the
verification the archive, the export, the build, DerivedData, the logs and the
screenshots were removed; the simulator data were preserved.

## Export compliance

A build with `usesNonExemptEncryption = null` hangs in TestFlight as **Missing
Compliance** and cannot be handed to a tester. The iOS build uses system HTTPS,
the Keychain and the platform push APIs, not its own non-exempt cryptography. The
answer is therefore `false` and it lives permanently in `Info.plist` as
`ITSAppUsesNonExemptEncryption`, so the question does not come up for further
builds. An existing build can be corrected through the API as well:

```http
PATCH /v1/builds/<id>  {"data":{"type":"builds","id":"<id>",
  "attributes":{"usesNonExemptEncryption":false}}}
```

If the app ever gets its own encryption (E2EE calls, say), this claim stops being
true and has to be reassessed.

## Remaining

- macOS distribution: either the Mac App Store, or a Developer ID Application
  with notarization through `notarytool` and stapling.
- `macos/Runner/Release.entitlements` only has
  `files.user-selected.read-only`; saving attachments will need read-write.
- PushKit, CallKit and ReplayKit for full call parity remain a separate open
  slice.
