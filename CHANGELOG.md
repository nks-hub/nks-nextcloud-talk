# Changelog

The releases that reached the testers. The numbers in brackets are the build
number, that is the `versionCode` on Android and the `CFBundleVersion` on the
Apple platforms; both sides hold the same number so that reports from testers
can be paired across platforms.

The source of truth about the version is `apps/mobile/pubspec.yaml`;
`apps/mobile/lib/core/app_version.dart` mirrors it and a test guards that the
two do not diverge.

Builds 17 to 19 have no tag and will not get one: on Play they were replaced by
build 20 before approval and they never reached TestFlight at all. A tag holds
only what really reached the testers.

Builds 1 and 3 came into being before the closed testing on Play and went only
to TestFlight. Their content cannot be broken down item by item: at that time
the build number was not raised by a commit, so no boundary in the history leads
to them. Only what is documented from App Store Connect is stated for them.

## Unreleased — the next build after 60

Collected as the work lands so the next release notes are not reconstructed
from the commit log. Nothing here has reached testers yet.

- New: a mute button in the call banner. It closes and reopens the microphone
  without renegotiating the call, and a microphone the user closed stays closed
  when a telephone call ends.
- Changed: the maintainer notes, the CI comments and one contract fixture no
  longer name the owner's machines, addresses, accounts or test servers; roles
  and `example.invalid` hosts stand in for them ahead of the repository going
  public. No code path changed.
- Fixed: a call no longer dies, and later calls no longer refuse to negotiate,
  after one signalling batch whose delivery was unknown. The signalling now
  opens a new room epoch instead of raising a flag nothing cleared, the peer
  connections are rebuilt, and polling — which used to stop silently on the
  stale pull — restarts. Applies to the built-in Talk signalling; the
  high-performance backend path is unchanged.
- New: tap the call banner to see who is in the call — each participant with
  their name, whether their audio is connected to you and whether their hand is
  up; your own row shows your mute and hand.
- New: send a reaction into a call from the banner (the same six the web
  client offers); a reaction from another participant shows on the banner for
  a moment.
- New: raise your hand in a call from the banner, and see how many other
  participants have theirs up. Works with the web client both ways.
- New: a speaker button in the call banner on Android and iOS, switching the
  call between the earpiece and the loudspeaker. An audio call now starts on
  the earpiece; before, the WebRTC engine's own preference put it on the
  loudspeaker at every start.
- New: a telephone call now mutes the Talk call's microphone for as long as
  it lasts. Before, an incoming phone call left the microphone capturing and
  the other participants kept hearing the room. Android proven on the rig; iOS
  implemented over `AVAudioSession` interruptions and compiled, awaiting a
  physical iPhone for the live proof.
- Fixed: two people could not connect a call at all. Opening a conversation
  activated and dropped its room session twice inside a second, the first
  signalling pull was answered 409, and the signalling lane stopped for good
  — so the call joined, opened the microphone and then waited forever. The
  room session is now shared between its readers instead of replaced, and a
  short grace bridges the gap between them.
- Fixed: once a call had failed to negotiate, every later call on the same
  account refused to negotiate too. A "renegotiation required" flag survived a
  fresh room session and was never cleared; a new room epoch now clears it.
- Fixed: a call whose audio failed left the user as a participant of a call
  they could not hear or leave, for as long as an hour, and only a moderator
  could get them out. The seat is now given back the moment the audio fails;
  the reason stays on screen.

## 0.1.0 (60) — 5 September 2026

The first release built and shipped entirely by CI: GitHub Actions builds
Android, Linux and the Windows installer, Codemagic builds the Apple targets,
the artifacts and their checksums are attached to this release, and the tag
publishes the signed bundle to the Play alpha track and the IPA to TestFlight.

- New: calls carry audio. The app negotiates a peer-to-peer call over the
  signalling session it already holds, and the join button in the call banner
  joins the call and opens the microphone. A server that runs an MCU is
  reported as unsupported instead of being offered a connection nobody would
  answer, and it is recognised before the microphone is ever asked for, so a
  call this build cannot join raises no permission prompt. Video, the call
  grid, the controls and reactions are not in this build.
- Fixed: the call banner could never offer "Join call". Opening the
  conversation and the banner asking for the call transport raced each other,
  and the banner's own answer was thrown away as cancelled; the banner then
  reported that the transport could not be resolved.
- Fixed: a microphone the user had refused was reported as unavailable rather
  than as refused, so the message named the wrong cause.
- Fixed: on macOS a tap on a push notification could stop opening the
  conversation. Tearing down the Windows notification service detached the
  handler from the shared channel that belongs to the push coordinator on
  Apple platforms.
- Fixed: on macOS a local notification was sent under a method name derived
  from the host instead of from the channel, so it could reach a receiver that
  does not handle it.
- Fixed: a live push registration started inside the test environment on
  macOS, where it had no business running.

Not visible in the app, but part of this build: every document in the
repository is now in English, and the four crash reports that build 47 raised
have been confirmed fixed and closed rather than left open as known noise.

## 0.1.0 (59) — 4 September 2026

Released from the source `1f3ff22`, tag `v0.1.0+59`. A short batch: two fixes,
both from the field — one was reported by a user, the other came to light on the
first real run on Linux.

Android: the release APK 93,577,502 B, SHA-256
`381143f880260f74a82cd81093bd4953fe0258c6734ba51a22b5d855b4dde267`,
versionCode 59.

Windows: the installer `NKS-Talk-0.1.0-59-windows-x64-setup.exe` 35,492,620 B,
SHA-256 `9f9f7fae0209d03eb6422eb3a1be9321f18affd3685612d14c76ddf760b9c401`,
unsigned.

iOS: the iPhone 16 Pro Max / iOS 18.6 simulator, the debug build 59 installed
and launched, `Runner.app` about 227.7 MiB, the zip 72,533,511 B, SHA-256
`dcf3d7e8370d90eed508ddc8ee601f8b7df8b01cd71d11385a29e4383275fe41`,
`CFBundleVersion` 59; the Czech onboarding rendered on the screen.

macOS: `nextcloudtalk.app` about 176.4 MiB, the zip 55,588,774 B, SHA-256
`fb62d81fd43ca5eb7490129b4108b8f8f74797ab78eb56b55041edf07c8b7d2a`,
an ad-hoc signature (`codesign --verify --strict` OK), it ran for 3 min 40 s.
A screenshot could not be taken, because the Mac has a locked screen; the run is
documented through the Dart VM service (a live isolate, a widget tree with the
onboarding mounted, a `FlutterView` of 1040×672).

Linux: it was not built separately for this build. The keyring fix below is,
however, verified directly on Linux — the state before and after the fix was
documented on the test VM.

- Fixed: on a server that is temporarily refusing the application, the
  application kept asking over and over. When the server says "wait", it now
  really waits, and it does so for the whole server instead of every part of the
  application finding out separately. The message now adds that the
  synchronization will resume by itself.
- Fixed: on Linux the application did not open at all with the system keyring
  locked — no window came into being and the process just stood there. The
  credentials are now opened at startup only when there really is something to
  read.

## 0.1.0 (58) — 4 September 2026

Released from the source `52aecdd`, tag `v0.1.0+58`.

Android: the release APK 93,577,506 B, SHA-256
`f9a51f3b40568806f1490a2e6d478c9fd4a84d99996a0b510619260b9fdb04bf`,
versionCode 58; live on the Android 14 emulator: sending from a killed process
after the network returned, the chat over a websocket with zero HTTP requests in
a 96-second window, signing in with a scanned QR code, launcher shortcuts and a
cold start straight into a conversation. The Play track was not uploaded
(cadence).

Windows: the installer `NKS-Talk-0.1.0-58-windows-x64-setup.exe` 35,491,818 B,
SHA-256 `f558c4141be8a243c5eec8c9fa113b2ba368c44fe00edabc4ee22352ccd94805`,
unsigned. The installation on `win-test-1` DID NOT HAPPEN — the machine was
disconnected at the time of the release (it is a live workstation).

iOS: an iPhone / iOS 18.6 simulator, the debug build 58 installed and launched,
`Runner.app` 228 MB, `CFBundleVersion` 58; the Czech onboarding rendered on the
screen including the new button „Načíst přihlašovací kód". TestFlight was not
uploaded (cadence, the latest is 51).

macOS: `nextcloudtalk.app` 177 MB, the zip 55,593,797 B, SHA-256
`e35327ce4535f440a1e1eab0c5041720e842db55b6f8289f6a38617ee1a5af30`,
an ad-hoc signature (`codesign --verify --strict` OK for the Designated
Requirement too), it ran for 1:19 on build-mac. A notarized Developer ID package was
not made for this build.

Linux: `nextcloudtalk` 35,608 B, SHA-256
`2b7ebf3f525f152c1da28127dc3bfdb0326508b572848751ea03469fbc4838c9`, the bundle
24 files / 40,260,854 B; built in 307 s and launched on the test VM, a 1280×720
window with the Czech onboarding rendered. `camera` has no Linux implementation
and nothing was linked in — the scanner is not offered on the desktop.

- Messages go out even when the application is closed. The phone wakes up as
  soon as the network is back and sends what stayed in the queue; an unfinished
  upload is picked up.
- In an open conversation the chat flows over a websocket if the server offers
  it. A message appears without waiting for a query; when the connection drops,
  the application quietly returns to the existing route and nothing is missing
  and nothing arrives twice.
- One can sign in by scanning a QR code from Nextcloud (Settings → Security).
  The code is read only from the camera; the application registers no link
  scheme of its own for it, so the password never travels through a system link.
- The recent conversations are under a long press of the application icon on
  Android. A tap opens that room directly. With the app lock on they are not
  offered at all.
- On the desktop the keyboard can now do what only the mouse could: Tab selects
  a message, Enter on it opens the same menu as the right button and Escape
  closes the detail pane. A mouse hover is now visible on reactions too.
- The application has a build of its own for Linux; it stores the credentials in
  the system keyring.
- Fixed: a deleted message took two rows in the conversation instead of one.

## 0.1.0 (57) — 3 September 2026

Released from the source `23c01b7`, tag `v0.1.0+57`.

Android: the release APK 91,196,816 B, SHA-256
`eb0a89ced31c782884265cf8feca6b838a73c532da6be45e8a19b19182fa31fe`,
versionCode 57; live on the Android 14 emulator: an attachment waits to be sent
and after Send goes out with a caption, removing a prepared attachment writes
nothing to the server, a card from Deck opens in the browser, one's own status,
a conversation tag, the lobby and a voice message (see below). The Play track was
not uploaded (cadence).

Windows: the installer `NKS-Talk-0.1.0-57-windows-x64-setup.exe` 35,479,397 B,
SHA-256 `9dd86a86a2844fc528b83a8d607a4d12449795ead499c7c8cc0bdc352ce18377`,
unsigned; `nextcloudtalk.exe` reports `0.1.0+57`. The installation on
`win-test-1` DID NOT HAPPEN — the machine was disconnected at the time of the
release (it is a live workstation); the installer is waiting for the next
connection.

iOS: the iPhone 16 Pro Max / iOS 18.6 simulator, the debug build 57 installed
and launched. TestFlight was not uploaded (cadence, the latest is 51).

macOS: `nks-talk-macos-57.zip` 33,016,873 B, SHA-256
`0eea6b8d0066cac37b0d734a943d10b6619dfeb498374179a2dd9b6f598407bb`,
Developer ID Application (team id withheld), notarized (Accepted), stapled,
`spctl`: Notarized Developer ID, `stapler validate` OK — verified on a file
downloaded back from Nextcloud; it runs on build-mac. Sent into the Pimpula chat
(share 8936, message 78914).

- A picked attachment is uploaded only after the message is sent. Until then it
  lies only in the application, the card in the input line says "Ready to send
  with your message" and the Remove button discards it without touching anything
  on the server. The text in the field is used as the caption of the attachment
  — and it is taken only at the moment of sending, so it can be typed after the
  file is picked.
- A screenshot from the clipboard can be pasted straight into a message
  (Ctrl+V / Cmd+V; on Android from the keyboard too). The image is converted to
  PNG and behaves like a picked file, that is it waits to be sent.
- Cards from Deck and other shared objects with a link can be opened by tapping.
- A conversation waiting in the lobby no longer reports a connection error; only
  the information that a moderator has not opened the room yet is shown.
- Unfinished attachments from an earlier crash of the application are cleaned up
  at startup.
- Less telemetry: an ordinary fast synchronization of the conversations is no
  longer sent, only a slow or an unsuccessful one is reported.

## 0.1.0 (56) — 3 September 2026

Released from the source `a9919e0`, tag `v0.1.0+56`.

Android: the release APK 91,097,916 B, SHA-256
`08dea544c27017cc330b1d437e45485474da3d2977c9635a3e8a4d8704db3c56`,
versionCode 56; live on the Android 14 emulator: removing an account offline and
completing the password revocation after the network returned, cancelling a
running upload from the diagnostics, the read state in a group, a thread renamed
and with an adjusted notification level, an image from the peer, a force-stop
and a cold start without duplicates. The Play track was not uploaded (cadence).

Windows: the installer `NKS-Talk-0.1.0-56-windows-x64-setup.exe` 35,467,496 B,
SHA-256 `6be82917c35dd3f1144ed346f169f82826dc7ebcfb6cbdfb7b80e11f966c451a`,
unsigned; a silent installation on `win-test-1`, `nextcloudtalk.exe` reports
`0.1.0+56` (PID 23288).

iOS: the iPhone 16 Pro Max / iOS 18.6 simulator, the debug build 56 installed
and launched. TestFlight was not uploaded (cadence, the latest is 51).

macOS: `nks-talk-macos-56.zip` 32,929,803 B, SHA-256
`7513ff7816d507a202988d188f0009e14e3e9ecac6a971e765f0005116df584f`,
Developer ID Application (team id withheld), notarized (Accepted), stapled,
`spctl`: Notarized Developer ID, `stapler validate` OK — verified on a file
downloaded back from Nextcloud; it runs on build-mac. Sent into the Pimpula chat
(share 8932, message 78878).

- Removing an account without a connection: the app password the server did not
  manage to revoke is stored safely by the application and it completes the
  revocation by itself as soon as the server is available (at most 5 passwords,
  20 attempts, 14 days). The message after the removal says so.
- An attachment on a slow network: when the server settings cannot be loaded in
  time, the upload does not give up right away — it tries twice more (after 3
  and 8 s). The telemetry now distinguishes an unreachable server from the other
  causes; that explained the report "immediately try again" from the Galaxy Z
  Fold 6.
- macOS: the window remembers its size and position between launches (the
  system's window state restoration used to prevent it) and never opens smaller
  than 600×400.
- The Open source licences page states that the application is GPL-3.0-or-later
  and how to obtain the complete source code of the build.
- Verified live: a denial of the notification permission in the settings, the
  read state of one's own message in a group, renaming a thread and the
  notification level, cancelling an upload that is currently running from the
  Diagnostics.

## 0.1.0 (55) — 3 September 2026

Released from the source `95d01a7`, tag `v0.1.0+55`.

Android: the release APK 91,097,916 B, SHA-256
`8a5b8d179228769531596c132f158a7c30587f08ae82a4d8bd7340ac63dc255c`,
versionCode 55; live on the Android 14 emulator: forwarding a received
attachment into another room, rejecting and withdrawing a federated invitation,
and a message deleted by the peer changing to "Message deleted" right away in an
open conversation. The Play track was not uploaded (cadence).

Windows: the installer `NKS-Talk-0.1.0-55-windows-x64-setup.exe` 35,456,840 B,
SHA-256 `7e781a3a7d3bb18387aa32dbe470819682286a163e67a6854997f3e0abe4b4b4`,
unsigned; a silent installation on `win-test-1`, `nextcloudtalk.exe` reports
`0.1.0+55` (PID 26480); the deep link `nctalk://open?uri=…/call/<token>`
switched the running instance to the correct room (a screenshot).

iOS: the iPhone 16 Pro Max / iOS 18.6 simulator, the debug build 55 installed
and launched. TestFlight was not uploaded (cadence, the latest is 51).

macOS: `nks-talk-macos-55.zip` 32,916,541 B, SHA-256
`9ffa883b7ca8375fb9f4af8e2eb31cc12b402022703aee5302abdb5c79a265a9`,
Developer ID Application (team id withheld), notarized (Accepted), stapled,
`spctl`: Notarized Developer ID, `stapler validate` OK — verified on a file
downloaded back from Nextcloud; it runs on build-mac. Sent into the Pimpula chat
(share 8928, message 78856).

- Forwarding attachments: a message with a file is forwarded into the target
  conversation as a new share of the same file, not as a bare name. Text,
  mentions and one file can be forwarded; a poll, a location and a contact do
  not offer the button, because Talk has no share for them.
- Messages that somebody else deleted or edited are updated in an open
  conversation right away from the server's notice — until now the old text or
  file stayed next to the row "deleted a message". It applies from this build
  onwards; whatever was deleted earlier stays in the cache until the
  conversation is loaded again.
- Desktop: an attachment dragged into a window that is not in the foreground
  (after a drop from Finder/Explorer) is no longer rejected after 15 s with "try
  again" — waiting for a return to the foreground applies only on mobiles
  (Sentry NKS-TALK-11).
- Windows: a `nctalk://` link handed to a running application now really opens
  the room; until now the window merely popped to the foreground.
- Federated invitations: a rejection and a withdrawal of an invitation by the
  other side were verified live, and the strip disappears without intervention.
- A custom conversation background colour was measured in both themes and at
  200% text: a text contrast of 8.24:1 (light) and 10.10:1 (dark).

## 0.1.0 (54) — 3 September 2026

Released from the source `8730973`, tag `v0.1.0+54`.

Android: the release APK 91,097,916 B, SHA-256
`3376a891408ac4689bba302c6ae9e6cb5ab7498167b7fd870e57c0785639c18f`,
versionCode 54; on the Android 14 emulator two accounts on two servers run, a
federated invitation was accepted and messages flow in both directions, and a
push from the second server arrived. The Play track was not uploaded (cadence).

Windows: the installer `NKS-Talk-0.1.0-54-windows-x64-setup.exe` 35,457,353 B,
SHA-256 `97d9e14b3fb1f1daa985db2bcf7a0b8cf91b1858000b31c78b9dc965be74e159`,
unsigned; a silent installation on `win-test-1`, `nextcloudtalk.exe` reports
`0.1.0+54` (PID 7868).

iOS: the iPhone 16 Pro Max / iOS 18.6 simulator, a debug build installed and
launched. TestFlight was not uploaded (cadence, the latest is 51).

macOS: `nks-talk-macos-54.zip` 32,917,467 B, SHA-256
`20df8cde271e16cc808e13f4c3a225b6c923ff860b0347511e235dd511aafd74`,
Developer ID Application (team id withheld), notarized (Accepted), stapled,
`spctl`: Notarized Developer ID — verified on a file downloaded back from
Nextcloud; it runs on build-mac (PID 76194). Sent into the Pimpula chat (share 8919,
message 78838).

- Invitations into conversations on other servers (federation): a strip above
  the list with the number of pending invitations and an overview with
  Accept / Reject buttons; an accepted conversation opens right away. A
  federated conversation loads and messages go both ways.
- Signing in to a server with "pretty" URLs without `index.php` (the default for
  the Nextcloud Docker image) no longer ends with an error.
- The conversation list from a server with Talk 22 (without tags, pinned and
  scheduled messages) is no longer rejected.
- Two accounts on two different servers in one application — verified live
  including the separated sign-ins and push notifications from both servers.
- A new test server `talk2.example.invalid` (Nextcloud 32 / Talk 22) for federation
  and two-server scenarios.

## 0.1.0 (53) — 3 September 2026

Released from the source `fdbc3eb`, tag `v0.1.0+53`.

Android: the release APK 90,917,560 B, SHA-256
`1ac61d2016a85606f0ae9312397557d73f656deee84c633b9f1bec72ebee0987`,
versionCode 53; on the Android 14 emulator the emoji panel closed after 😀 was
sent and the message arrived at the server. The Play track was not uploaded
(cadence).

Windows: the installer `NKS-Talk-0.1.0-53-windows-x64-setup.exe` 35,436,443 B,
SHA-256 `9ea6211b9110f3a5f8ccfa066ce67252f6484e82bbb8ce8a31cf6b6c3ca735e5`,
unsigned; a silent installation on `win-test-1`, `nextcloudtalk.exe` reports
`0.1.0+53` (PID 20348).

iOS: the iPhone 16 Pro Max / iOS 18.6 simulator, a debug build installed and
launched; an emoji from the panel was sent and the panel closed. TestFlight was
not uploaded (cadence, the latest is 51).

macOS: `nks-talk-macos-53.zip` 32,882,920 B, SHA-256
`6a71b3e7a00f047832024b3aedb6d8854a718688fb98b15d1657c2dafd05dc0b`,
Developer ID Application (team id withheld), notarized (Accepted), stapled,
`spctl`: Notarized Developer ID — verified on a file downloaded back from
Nextcloud; it runs on build-mac (PID 47641). Sent into the Pimpula chat (share 8911,
message 78812).

- The emoji panel closes by itself after a message is sent.
- The conversation list asks the server for the whole overview every five
  minutes, so a room deleted or left on the server disappears even without a
  manual refresh (until now it stayed until the application was started again).
- Live evidence: TalkBack speaks an incoming message ("New activity. NCloudTalk
  Test 2: …"), the screens at 200% text in both the light and the dark theme
  without an overflow, macOS Developer ID + notarization as a permanent
  procedure.

## 0.1.0 (52) — 3 September 2026

Released from the source `81ea963`, tag `v0.1.0+52`.

Android: the release APK 90,917,560 B, SHA-256
`a673d1466b88ddedf3ee15d2869ffc7634018384fb17741aa9d0ddfd95f27cce`,
versionCode 52; on the Android 14 emulator it delivered, after the start, three
messages queued offline in build 51, and a reply from a notification went out as
a reply (message 78744, parent 78742). The Play track: see the note at release
51.

Windows: the installer `NKS-Talk-0.1.0-52-windows-x64-setup.exe` 35,445,402 B,
SHA-256 `a49e2f84be83f132e0cb0e0259fba3f7c3a376a976c99c2ff8d65064ead68441`,
unsigned; a silent installation on `win-test-1`, `nextcloudtalk.exe` reports
`0.1.0+52` (PID 8448). The previous installer with this name (SHA
`31044eb8…`) carried an exe from before the bump and was replaced.

iOS: the iPhone 16 Pro Max / iOS 18.6 simulator, a debug build installed and
launched; after "Reply" there is the reply banner and the cursor in the input
line. TestFlight: build 51 was uploaded (Delivery
`ba8a770d-d5a9-42a8-a211-dd79c6ced135`, VALID) after the portal was fixed; 52
was not uploaded to TestFlight (cadence).

macOS: `nks-talk-macos-52.zip` 32,883,246 B, SHA-256
`8e88f15e2c07f404b3314fc57bdf3c0c49f5b6d8f24adcbab5e8df8a92522c38`,
Developer ID Application (team id withheld), notarized (Accepted), stapled,
`spctl`: Notarized Developer ID — verified on a file downloaded back from
Nextcloud; it runs on build-mac (PID 31592). Sent into the Pimpula chat (share 8909,
message 78763). A trap: entitlements signed straight from the source file carry
an unexpanded `$(APS_ENVIRONMENT)`/`$(AppIdentifierPrefix)` and amfid does not
let the application through ("No matching profile found"); CRLF in the
`.entitlements` from a Windows archive brings the parser down.

- A conversation with images no longer drags the reader back down when scrolling
  up: the image bubble has a size taken from the dimensions Talk sends, before
  the preview loads, so nothing reflows under the reader.
- A reply from a notification is a real reply to that message (a quotation in
  the bubble), not a new message — on Android, iOS, macOS and Windows.
- After "Reply" the input line gets focus right away.
- Dragging the divider of the conversation list is smooth — it is measured from
  the start of the gesture, not from the last repainted width.
- Messages written without a connection are sent right after the network returns
  or after the application starts, even without an open conversation; an
  attachment whose automatic retries expired is retried by itself after the
  network returns.
- The message actions work offline too, from the stored capabilities.
- Live evidence: the read state of an attachment, of a voice message and of a
  location by the server marker; shared items as the recipient including the
  second page (32 files); a link card on iOS; a durable outbox after a process
  death; a reply to an image.

## 0.1.0 (51) — 3 September 2026

Released from the source `24390c5`, tag `v0.1.0+51`.

Android: the release APK 90,884,792 B, SHA-256
`a86548a9b8848ffab82087fb779cdac016643898cf7ab20ab346b246e273566c`,
versionCode 51; on the Android 14 emulator a search for „hlodavec" in the
English UI returns Mouse, Rat, Hamster and Beaver. The Play track was not
uploaded.

Windows: the installer `NKS-Talk-0.1.0-51-windows-x64-setup.exe` 35,439,793 B,
SHA-256 `07dae9d6a952b10b775fa302390a63a3ebb1592a157ce2b2c69e32b9392a47b2`,
unsigned; a silent installation on `win-test-2`, `nextcloudtalk.exe` reports
`0.1.0+51` (PID 320).

iOS: the iPhone 16 Pro Max / iOS 18.6 simulator, a debug build installed and
launched. TestFlight NOT RELEASED (provisioning).

macOS: a debug build + an ad-hoc signature, 30 s without a crash.

- The emoji picker knows the whole catalogue in Czech: 4,361 names and keywords
  from Unicode CLDR, so „hlodavec" finds the beaver and „tající" the melting
  face. The 31 hand-written names stay and take precedence.
- It was decided from which line of the server the client works: Talk 22
  (Nextcloud 32) — that is where the last mandatory capability (`threads`) came
  into being; the only younger one, the conversation tags, merely enables a
  feature (D-047).
- A call spike is prepared: `flutter_webrtc` 1.6.1 builds and establishes a
  connection on Windows, Android, macOS and in the iOS simulator; the details
  and the traps are in `docs/TODO-notifications-calls.md`. It is not being added
  into the application yet.
- A TODO cleanup: seven items were closed that were either duplicates,
  superseded by a working route (the macOS ad-hoc run, a Windows build outside
  the VM), or principles instead of tasks; the changelog on NKS IS is
  synchronized with the repository.

## 0.1.0 (50) — 3 September 2026

Released from the source `9a530d7`, tag `v0.1.0+50`.

Android: the release APK 89,115,320 B, SHA-256
`78a316e3f53c59c7836e5070aaef986cfff3372f3d345f9fc2f998ffd2279b78`,
versionCode 50; it runs on the Android 14 emulator, with the sync not
downloading the capabilities repeatedly. The Play track was not uploaded.

Windows: the installer `NKS-Talk-0.1.0-50-windows-x64-setup.exe` 35,215,152 B,
SHA-256 `735af5242196d460d2cf1f616d7427519228e271889fa5eac940e83ba05a8531`,
unsigned; a silent installation on `win-test-2`, `nextcloudtalk.exe` reports
`0.1.0+50` (PID 9608), the account signed in and synchronizing.

iOS: the iPhone 16 Pro Max / iOS 18.6 simulator, a debug build installed and
launched with the conversation list. TestFlight NOT RELEASED (provisioning).

macOS: a debug build + an ad-hoc signature, 30 s without a crash, without an
account.

- The synchronization of the conversation list no longer downloads 13 kB of
  capabilities again every 15 s. The interruptible read the sync runs on never
  replaced an expired record in the in-memory cache, so after five minutes of
  running, every cycle went to the server twice.
- A short interruption of the window — picking a photo, a permission dialog, the
  notification shade — no longer drops and restores the presence in the room.
  The server used to get a sign-out and a sign-in of the session and a new
  signaling for every tap; the presence is now started only after two seconds of
  inactivity, which makes no difference for suppressing notifications.
- Verified live: a parked account on Windows released itself with build 49; an
  image upload from the picker takes about 2 s; a denied microphone offers the
  settings; a rotation with a conversation open switches the two-pane layout
  without a crash; "Send to Note to self" works on iOS too.

## 0.1.0 (49) — 3 September 2026

Released from the source `1e1f4ca`, tag `v0.1.0+49`. The batch came out of the
Sentry findings of build 47 and out of live debugging of the "sign in again"
state.

Android: the release APK 89,115,320 B, SHA-256
`88a8f8a550050a20c69a8f1658db8aef54211c7febc15fe9befca86ebd7619b5`,
versionCode 49. Live on the Android 14 emulator: a parked account released
itself after the installation (a room sync 200 without intervention), a
cold-start share of text into a chosen room, "Send to Note to self" from the
message actions. The Play track was not uploaded.

Windows: the installer `NKS-Talk-0.1.0-49-windows-x64-setup.exe` 35,212,253 B,
SHA-256 `3ca79e7bcbe450716e57ca5adfb464c78391e271d5aab4e35555cea2c3411ff5`,
unsigned; a silent installation on `win-test-2` under RDP, `nextcloudtalk.exe`
reports `0.1.0+49`, the window "NKS Talk" is alive (PID 9960).

iOS: the iPhone 16 Pro Max / iOS 18.6 simulator, a debug build from the same
source installed and launched, the conversation list of the signed-in account.
TestFlight NOT RELEASED (provisioning, see 48).

macOS: a debug build through `xcodebuild` + an ad-hoc signature, a run of 30 s
without a crash; without a signed-in account.


- An account no longer falls into "sign in again" because of a single erroneous
  401. On the evening of 2 September the reference server returned 401s for
  valid tokens to three clients at once for several seconds; the application
  took every such outage as a revoked sign-in and stayed in it until the user
  signed in by hand. Now a 401 is verified with a second read after two seconds,
  and an account that is already in that state releases itself as soon as its
  token works again.
- Shortly after the start, the vault with the password could answer "there is
  nothing here" before the system keystore was ready; the application recorded
  it as a missing sign-in and stopped synchronizing. The read is repeated and
  the state is not permanent.
- Signing in again is no longer brought down by an old response: a 401 for a
  password the user has replaced in the meantime is ignored.
- Four crashes reported from Sentry (build 47): the push registration during a
  network outage, waking the synchronization of a parked account, a denied
  notification permission on iOS and a start without a Documents folder. None of
  them is a crash any more.
- The message action "Send to Note to self" sends the text straight into one's
  own notes conversation.
- The attachment download bar knows the percentage even where the server does
  not send the length: it takes the size of the file from the share.

## 0.1.0 (48) — 2 September 2026

Released from the source `8b32836` (+ docs).

Android: the release APK 89,098,936 B, SHA-256
`3ee52907b5cd5fd8edae0254eb0f10fd5a8044e1beee54347033d0067a9dc483`,
versionCode 48. Verified live on the Android 14 emulator: the fixture-user
sign-in, Note to self (the message arrived at the server), a reply as a quoted
bubble, the progress of downloading a 6 MB attachment with percentages. The Play
track has not been uploaded yet.

Windows: the installer `NKS-Talk-0.1.0-48-windows-x64-setup.exe` 35,210,814 B,
SHA-256 `e1988a72d6694499da89bed6f056df2df9b2dd6ab7186cf4e80bb0d7493f0c25`,
unsigned; installed by a silent run on `win-test-2` under the RDP user into
`%LOCALAPPDATA%\Programs\NKS Talk`, `nextcloudtalk.exe` reports `0.1.0+48` and
the window "NKS Talk" is alive. A build on that VM is not possible (MSVC ×
`jni`), so it was built locally. The account on the VM has been in the "sign in
again" state since earlier, so the UI evidence of the new items on Windows comes
only from the widget tests for the windows platform.

iOS: the iPhone 16 Pro Max / iOS 18.6 simulator, a debug build from the same
source. The sign-in, the Share Extension from Safari all the way to the message
on the server, a reply in the conversation and the transcription button were
verified (the transcription itself does not finish in the simulator, see below).
TestFlight NOT RELEASED: the App Store profile has no App Groups and no profile
exists for the Share Extension.

macOS: a debug build through `xcodebuild` without signing + an ad-hoc `codesign`
(`valid on disk`), the application ran for 40 s without a crash; signing in on
build-mac requires a person at the machine, so GUI evidence is missing.

- An open conversation on the desktop finally announces a new message. The
  application told the server the user was present in the room until they left
  that conversation — and Nextcloud deliberately suppresses a notification for
  someone present, so that it does not beep about a message they are reading. On
  a phone that fits, but on the desktop a window keeps a conversation open
  behind three other windows, so the server stayed silent the whole time. An
  unfocused window is no longer considered presence.
- The live channel comes back up after an outage. When the credential was not
  readable at that moment — and on the desktop it is not right after the window
  starts — the application read it as "this server does not offer a live
  channel" and turned it off for the whole run. It now keeps trying.
- A notification on Windows sounds like a message, not like something generic.
  The official Talk application makes the same distinction between the sound of
  a message and the sound of a call.
- On a wide window the application no longer pays in space for an account
  switcher that has nothing to switch between, and the conversation list can be
  folded; the choice survives a restart.
- A reply stays in the conversation. Since Talk 22 the server creates a thread
  from every reply and the application therefore hid it away from the
  conversation, so a reply could be found only through "N replies" under the
  original message. A reply is now displayed classically: the quoted bubble it
  responds to and its own text below. Whoever wants threads can switch it in
  Settings → Replies; named threads stay available in both modes.
- Downloading an attachment is no longer silent. Opening, saving and sharing an
  attachment shows a bar with percentages from the first moment; when the server
  does not reveal the length, the bar runs indeterminate, but at least it is
  visible that something is happening.
- On the desktop, text from a bubble can be selected with the mouse and copied.
  A long press on the bubble still opens the message actions.
- A voice message can be transcribed into text on the iPhone directly on the
  device, without the recording being sent anywhere outside; the transcript can
  be copied with one tap. When the language of the application has no offline
  model on iOS (Czech does not), the device language is used. In the simulator
  the recognition ends with the system error 1101, and a real transcript will be
  confirmed only by a physical iPhone.
- iOS has a Share Extension: text or one file shared from the system menu can be
  sent into a chosen account and conversation, the same as on Android.
- macOS: "Save as" for an attachment used to end without a file, because the
  sandbox allowed only reading the chosen location. Writing is now allowed.

## 0.1.0 (47) — 2 September 2026

Released from the source `4bfaf70`, tag `v0.1.0+47`.

Play (closed testing, the alpha track): the release `(47) 0.1.0` is `completed`
with version code 47. The AAB has 84,337,287 B and the SHA-256
`c9d0758420e061f1b27862197356749851d8e41bcf222e32a931f5e5870c5dd7`. The notes in
six languages were verified by a query back to the track.

TestFlight: the IPA of 30,237,904 B was uploaded from build-mac, `xcrun altool`
reports "No errors uploading archive". The export used to fail because the
provisioning profile has no Associated Domains; the entitlement was removed,
because it hardcoded the domain of one server, which makes no sense in a
multi-server client, and no code used universal links.

macOS: the ZIP 32,022,517 B, SHA-256
`c55ab36ffdf544a40e701c3ea80cc8fa4364e6566611049ea96da170ba4ee6f3`, signed with
Developer ID (team id withheld), `app-sandbox` and `aps-environment`,
`codesign --verify` reports "satisfies its Designated Requirement".

Windows: deployed on `win-test-2`, the installer reported `Installed 0.1.0+47`.
Android was verified on the `chatujmePixel` emulator (`versionCode=47`), iOS on
the iPhone 16 Pro Max simulator.

- macOS finally announces a new message, with a sound and with the Reply and
  Mark as read actions. Nextcloud sends Talk notifications only to devices that
  identify themselves as Android or iOS, so a desktop client gets nothing from
  its proxy as soon as the account has a phone registered. Windows has been
  showing the notification itself over the live channel since batch 45; macOS
  had nothing, so the application synchronized honestly but never told the user.
- Searching within a conversation returns results again. The server answers a
  query into one room with matches from elsewhere too — the `from` parameter is
  a hint for ordering, not a filter — and the application discarded the whole
  response because of a single foreign item and reported that it did not
  understand it. Foreign results are now skipped and the rest arrives.
- The conversation list can be grabbed by the divider and dragged to a different
  width; the choice survives a restart. What is draggable is the divider itself,
  not an extra strip, so that a splitter does not take from the conversation the
  space it is supposed to give back.
- When little space is left for the conversation, the list folds by itself and
  comes back once the window is enlarged. The stored preference is not touched —
  that is a choice for windows that do have the space.
- The heading in the list header stopped breaking in the middle of a word. In a
  strip 300 px wide it fought with the avatar and three buttons, so „Konverzace"
  was left as „Konverzac / e"; the heading is gone, but screen readers still get
  it.

## 0.1.0 (46) — 2 September 2026

Released from the source `f9d2380`, tag `v0.1.0+46`, built from a clean
worktree. For the first time onto all three platforms at once.

Play (closed testing, the alpha track): the release `(46) 0.1.0` is `completed`
with version code 46. The AAB has 84,306,565 B and the SHA-256
`7fe346441b6c2e88408523060ff2d35ec3e498e13ea53e462de4d1d8ea73d37a`, SHA-1
`d553b29fe37624008c892bff28ff4cc087340d36`. The notes in six languages were
verified by a query back to the track.

Windows: the ZIP has the SHA-256
`ef7508d85aefb2c6beaccf74698aee3f758239fa879e0755a478ef1d5200e600`, deployed by
the installation script on `win-test-1` into `C:\Program Files\NKS Talk`.
Verified while running: a single instance, `0.1.0+46`, the window "NKS Talk".

macOS: built on Codemagic (the build `<codemagic-app-id>`), the ZIP has
the SHA-256 `df4cd128b1e2a1487430a7638c5cd21abe11a541013bb935b56c8c6d9841827b`,
`CFBundleVersion` 46, a minimum of macOS 12.0. CAREFUL: the package is signed
AD-HOC and HAS NO provisioning profile, so push notifications cannot work on it
— the App Store Connect integration did not supply the CLI `ISSUER_ID`. To be
resolved.

TestFlight: not released, `build-mac` is still down and the iOS workflow has not run
yet.


- On a wide window the application no longer pays in space for an account
  switcher that has nothing to switch between. With a single account the
  vertical bar on the left took 88 pixels across the whole height of the window
  for a logo, an avatar that could not even be clicked, and two buttons. The bar
  now appears only with a second account; its actions are meanwhile held by the
  menu under the avatar in the list header, the same as on the phone. The
  conversation thereby got 89 pixels back — on a laptop 1024 wide, almost nine
  percent of the screen.
- The conversation list can be folded. A button was added to the header of an
  open conversation that hides the list and brings it back, so the whole window
  is available for reading a longer conversation. The choice survives a restart
  of the application.

## 0.1.0 (45) — 2 September 2026

Released from the source `f5b82dc`, tag `v0.1.0+45`, built from a clean
worktree.

Play (closed testing, the alpha track): the release `(45) 0.1.0` is `completed`
with version code 45. The AAB has 84,298,278 B and the SHA-256
`6a63491c6f6ddb3dba63eb712d5221d385c985e7afa3aa96275b27fd10f7fdf4`, SHA-1
`bd2f07a55a8fecd44e4b42b91f0390e5672ca51d`. The notes in six languages were
verified by a query back to the track.

Windows: a desktop package is released for the first time too. The ZIP has the
SHA-256 `84e330681f2e8b68243840616dd35d9d67ea3508b5ccc69142a16139c2a6895a` and
is deployed on `win-test-1` by a new installation script into
`C:\Program Files\NKS Talk`; `nextcloudtalk.exe` reports `0.1.0+45`.

TestFlight and macOS: NOT RELEASED. `build-mac` is not connected to the RemoteCmd
relay and Codemagic is not connected to this repository yet, so no Apple
artifact came into being at all. No false evidence is issued for it.


- A link to a conversation finally opens the application on Windows too. The
  scheme `nctalk:` is registered by the installer, which the project never had,
  so every manual unpacking of a build silently lacked deep links — there was
  not even a record of the link in the registry. The registration is now done by
  the new installation script and the running application takes the link over
  instead of starting a second time.
- An installation script for Windows was added. It came out of a mistake that
  must not be repeated: a build was unpacked next to an older installation, the
  older one kept its shortcuts and the tester then opened a week-old version for
  a week. The script always installs over an existing copy, redirects the
  shortcuts and refuses to finish with two copies on one machine.

## 0.1.0 (44) — 2 September 2026

Released from the source `26a1c5c`, tag `v0.1.0+44`, built from a clean worktree
of `origin/main`.

Play (closed testing, the alpha track): the release `(44) 0.1.0` is `completed`
with version code 44. The AAB has 84,298,247 B and the SHA-256
`cfa37169aad17dc30c23b114c5e2ff7dde9400442b79d7211f721f30ea8961f3`, SHA-1
`75560d3ac0d4755a2297d9c5edd1cc9804aee738`. The notes in six languages were
verified by a query back to the track. The license gate passed with 148 Flutter
packages and 113 Android runtime components. On an Android 16 emulator the
`versionCode=44`, a running process and a log without FATAL/ANR were verified.

TestFlight: NOT RELEASED, the same as with build 43 — `build-mac` is not connected
to the RemoteCmd relay, so no iOS artifact came into being and neither iOS nor
macOS was tested.


- The performance metrics were going out with an extra breadcrumb trail. The
  server-side verification of build 43 showed that an event arrives with records
  about the lifecycle, the battery and navigation, even though it is built empty
  and sent with a cleared context — the SDK adds them after it. They are now
  knocked down in the same place where it is already done for the attachment
  diagnostics. An ordinary crash report keeps its records.
- The accessibility probes additionally cover the input bar, the
  new-conversation screen, the diagnostics and the room password dialog.

## 0.1.0 (43) — 2 September 2026

Released from the source `c171d71`, tag `v0.1.0+43`, built from a clean worktree
of `origin/main`, not from the working copy.

Play (closed testing, the alpha track): the release `(43) 0.1.0` is `completed`
with version code 43. The AAB has 84,298,648 B and the SHA-256
`02f8e35b3630671a2151c73e1b8216f276276a30e4dbd4d9f4c99f9ebee6cf9a`, SHA-1
`547ad0066276685f4de18adf200eef509e206db1`. The notes in six languages were
verified by a query back to the track. The license gate passed with 148 Flutter
packages and 113 Android runtime components.

TestFlight: NOT RELEASED. The machine `build-mac` was not connected to the RemoteCmd
relay at the time of the release, so no iOS artifact came into being and neither
iOS nor macOS was tested. No false evidence is issued for it; the iOS half of
build 43 remains.

- The confirmation dialogs can be answered even at double the system font size.
  The dialog "Share this file into the conversation" overflowed by 48 px
  downwards in English, so the Cancel and Share buttons ended up off-screen and
  the file could neither be shared nor the dialog dismissed. Measured on a real
  screen, not on a copy in a test. The same protection is deployed on another
  twelve dialogs that have no scrolling of their own — deleting a message,
  removing an account, leaving and deleting a conversation, clearing the
  history, removing a participant, cancelling an unfinished upload, the password
  to an open conversation, the certificate fingerprint, editing a message and
  naming a thread.
- A rejected attachment finally says why. A report from the field (a Galaxy Z
  Fold 6, Android 16): the paperclip → choose an image → immediately "try
  again". In the telemetry it was a single tag `dispatch`, because all the
  causes were caught with a single `on Object`. And yet they are four different
  problems with different fixes — a room one may not write into; an account
  whose server diverged from the request; a missing app password; and an
  application that did not return to the foreground after the gallery was
  closed. The service now reports them typed and the next occurrence will be
  recognizable at a glance. The cause of that report itself is not fixed by this
  yet.
- The performance metrics are really being measured for the first time. The
  layer had been finished earlier, but nobody called it; it now measures the
  application start, the synchronization of the list, opening a conversation, an
  attachment upload and a wake-up by push. What goes out is the name of the
  operation from a closed enumeration, the result and a bucket of the duration —
  never the address of the server, a room token or a file name. Sentry tracing
  stays off deliberately: its automatic spans are labelled with the URL they
  went to.
- Two accounts on two servers with the same conversation token: it was
  documented that a request goes to its own server with its own password, that
  the read state of one account does not move the other, and that a running
  query of one account never answers for the other.
- The accessibility audit was extended from two screens to five real ones: the
  conversation workspace, the settings, the diagnostics, the conversation detail
  and the confirmation dialogs. It now also guards the reading order of the
  screen reader and the number of live regions, not just the names of the
  controls.

## 0.1.0 (42) — 2 September 2026

Released from the source `9393081`.

Play (closed testing, the alpha track): the release `(42) 0.1.0` is `completed`
with version code 42. The AAB has 84,293,448 B and the SHA-256
`7b98dbd729171b754e7171cb9c5c9f670bb713795dd0c1181fe60181e6136d08`. The notes in
six languages match the source after the upload.

TestFlight: the IPA has 30,237,979 B and the SHA-256
`7ab21ef2f1648ae05cab61ee312172e133e3a4454a6eb636815c6e919cf2e97c`, the delivery
UUID `284a27cd-7cc1-496d-b3ab-02e61767963f`.

Both artifacts are built from a CLEAN checkout of `origin/main` for the first
time, not from the working copy. That one carries unfinished work of another
branch (the iOS Share Extension, the transcription, the lifecycle policy) and
locally built builds could have contained it — with this release that is ruled
out.

- The bar "This account must be signed in again" fits on the screen even with an
  enlarged system font. The text and the button used to be crammed into one row
  and in Czech at double the font size they overflowed 228 px off the display;
  above roughly 1.3× scale the action now stacks under the message.
- Three gates were added inside that guard this by themselves: a contrast matrix
  of 28 colour pairs (the lowest measured value 6.4606:1), a probe for a layout
  overflow at 200% text verified against itself with a deliberately overflowing
  case, and a check that every control with nothing but an icon carries a name
  for the screen reader.
- The offline scope of the first release was decided (Q-004): a cache of the
  history, a durable text outbox and durable attachments with recovery after a
  restart; the other actions stay online-only and fail-closed, because no replay
  contract exists for them.
- A measuring layer for performance metrics was prepared. It sends nothing yet;
  only six named operations can be measured and a measurement carries only the
  name of the operation, the result and a bucket of the duration, so neither an
  account, nor a room, nor an address can be put into it.

Still to be checked: in a trial on a hand-assembled confirmation dialog it
overflowed in English too, but it was measured on a copy in a test, not on a
real screen — described in `docs/TODO-quality-operations.md`.

## 0.1.0 (41) — 1 September 2026

Released from the source `5fd2a0a`.

Play (closed testing, the alpha track): the release `(41) 0.1.0` is `completed`
with version code 41. The AAB has 84,291,246 B and the SHA-256
`2fdbec524a211642d9109ef0554174404cc90dd8d667d539d8ed4b342cebac6f`. The notes in
six languages match the source after the upload.

TestFlight: the IPA has 30,237,177 B and the SHA-256
`629e358d6ac8a839f0a591373294cf59735c9381dbe62ab00679680338a50bef`. Both the
delivery UUID and the build record are
`4c804b9b-dd16-4822-9d5e-469fdc920a3f`, the state `VALID`, a minimum of
iOS 15.0, encryption `false`, both groups `IN_BETA_TESTING` and the beta review
`APPROVED`.

The whole suite passed before the release: mobile 1679 tests with 4 skips, the
protocol 1026 tests, neither with a failure. On Android 14 (the emulator, the
release APK of build 41) "Open conversations" in a new conversation is available
live and the reference server answered the query saying it offers no open
conversations — the joining itself is therefore documented so far only by tests,
not by a live pass.

- "Open conversations" were added to the new conversation. The server shows what
  it publishes as open, and one tap joins such a conversation; a protected one
  asks for the password first, which goes in the body of the request, not in the
  address. Joining is counted only by the server's response, so an error
  response hidden in a successful HTTP code does not open the conversation.
- The application understands a remote wipe of the account. When an
  administrator wipes the device, the app password stops working — and because
  an ordinarily revoked token looks the same, the application asks the server
  what is going on. It deletes the account and all its local data only on an
  explicit confirmation; an unavailable server, an unclear response and a
  missing credential never delete anything.

## 0.1.0 (40) — 1 September 2026

Released from the source `ea02f94`.

Play (closed testing, the alpha track): the release `(40) 0.1.0` is `completed`
with version code 40. The AAB has 84,214,115 B and the SHA-256
`af24c7ed8cc3d381fdbdf04f172e061dcbbfa5b59265337dc4cd4f83fa20a928`. The notes in
six languages match the source after the upload.

TestFlight: the IPA has 30,214,746 B and the SHA-256
`3724174384f3ead271a1020dca55a15f7d9293a0accb1faab18019d699a4a73d`. Both the
delivery UUID and the build record are
`fbd805e8-3b28-4fe4-9983-e4d9fe96c714`, the state `VALID`, a minimum of
iOS 15.0, encryption `false`, both groups `IN_BETA_TESTING` and the beta review
`APPROVED`.

Verified live before the release on the iOS 18.6 simulator (build-mac) and on
Android 14 (the emulator, the release APK of build 40): the attachment menu
shows all seven items including the poll and the location, browsing one's own
Nextcloud returned real folders and files, and on iOS the whole sharing of a
file into a conversation went through including the confirmation; the test
message was deleted afterwards. The macOS and Windows runtime could not be
verified — the reasons are recorded in `docs/TODO-platforms.md` and neither of
them is related to this change.

- "File from Nextcloud" was added to the attachment menu. One browses the
  account's own storage a folder at a time and the picked file is shared into
  the conversation — no copy is uploaded and no public link comes into being.
  Before sending there is a confirmation saying that the file stays on the
  server and the participants have access to it until the share is revoked in
  Files.
- The attachment menu stopped freezing. When the conversation learnt about the
  poll or the location only after the menu was opened, the items were added only
  sometimes; now they are always added and a longer menu can be scrolled on a
  short screen.
- A custom or self-signed certificate of the server can be confirmed when adding
  an account. The application shows the SHA-256 fingerprint in pairs so that it
  can be compared with what the server prints, and only after a confirmation is
  anything sent to the server. The fingerprint belongs to the account and
  disappears with its removal; an abandoned server addition leaves no trust
  behind.
- A certificate that changes on an already trusted server is not accepted and is
  not asked about again. A certificate renewal looks the same from the outside
  as an attack, so it is handled deliberately: by removing and re-adding the
  account.

## 0.1.0 (39) — 1 September 2026

Released from the source `daa1039`.

Play (closed testing, the alpha track): the release `(39) 0.1.0` is `completed`
with version code 39. The AAB has 84,005,134 B and the SHA-256
`92ee4e5e7278474ee1f101e46b06b5af6ae834cd8aeacd59fae721cb79d555fd`, signed with
the upload key `CN=NKS Talk`. The notes in six languages match the source
character by character after the upload.

TestFlight: the IPA has 30,173,759 B and the SHA-256
`6054a93a4bb5d55d67fa24582248fb236eca1344846fd3a8ca0ed21f63e93526`. Both the
delivery UUID and the build record are
`74a53a71-e81e-426b-9bcb-3a58cb3daf39`, the state `VALID`, a minimum of
iOS 15.0, encryption `false`, both groups `IN_BETA_TESTING` and the beta review
submitted.

While preparing this build I caused a regression myself: converting `loadPreview`
into a non-asynchronous method started throwing an exception before the caller
could catch it in a `Future`. The existing test
`chat_media_repository_test.dart` caught it and the fix is part of the released
source.

- Images and GIFs in an open conversation no longer flicker every few seconds.
  The previews were held under a key that carried the whole account row, and
  every synchronization overwrote it — the image was therefore downloaded again
  every time. The key now holds only what really determines the download.
- A link preview shows the image when the server offers it. It is loaded
  exclusively from one's own Nextcloud, which proxies it; the address of the
  linked site is not fetched, so opening a conversation reveals nothing about
  the reader.

## 0.1.0 (38) — 1 September 2026

Released from the source `7c8e2fb8e5b2e0209d589669c79515cd7564e6ac`.

Play (closed testing, the alpha track): the release `(38) 0.1.0` is `completed`
with version code 38 and is the only one on the track. The AAB has 83,989,490 B
and the SHA-256
`ad435dce6e0db02f376d8ed3cd044da1d3b81a4023f37056928a7c99e446d6a8`, is signed
with the upload key `CN=NKS Talk` and `jarsigner` reports `jar verified`. The
notes in all six languages match the source file character by character after
the upload.

TestFlight: the IPA has 30,167,493 B and the SHA-256
`0729aeb954ed92d301d340bc665ee7ea5032999db01a16345ded03f2d18f60af`. Both the
delivery UUID and the App Store Connect build record are
`ec28eef5-d5d4-4d34-9e71-b09185b685a6`. App Store Connect returns `VALID`, a
minimum of iOS 15.0, encryption `false` and Czech notes. Both groups are
`IN_BETA_TESTING`; the beta review was submitted and is pending at the time of
writing.

The `apps/mobile` suite ended with 1635 passed and 4 skipped. Two failures
(`ios_app_icon_metadata`, `macos_push_capability`) are older and fail on a clean
base too, because `Podfile.lock` is missing in a fresh worktree.

- The sign-in field starts at `https://` and understands an address pasted from
  the clipboard. A link copied from the browser is stripped of the parameters and
  the anchor and shortened to the address of the server, so `.../index.php/apps/spreed/`
  no longer ends with an error. A subdirectory of the installation is preserved
  and a pasted `http://` is not silently changed into a secure one.
- The GIF picker searches as you type. Fast typing sends one query instead of
  one per key, and clearing the field returns to the recommended ones.
- Settings → Diagnostics shows the unfinished attachments: the type, the phase,
  the age and a range of attempts, nothing more. Only what really can be
  cancelled can be cancelled; an attachment already handed to the server has a
  lock instead of a button, so that it is not pretended that it was not sent.
- The bubble of a message being sent is lower and looks like an ordinary
  outgoing message instead of a separate card. The state, the retry and the
  cancel all stayed.
- The link preview card has a readable hierarchy: first the title, the source
  below it, and the description only after that. A link with a thumbnail and one
  without hold the same shape.

## 0.1.0 (37) — 1 September 2026

Released from the source `0a388e63263d8e9aa47cd75652611cd37235b324`.

Play (closed testing, the alpha track): the release `(37) 0.1.0` is `completed`
with version code 37. The AAB has 83,952,784 B and the SHA-256
`8c969f7d4c8369ab1b4458a92ef2495b1ea7a1df6d889f1443aa954eb1b65566`, is signed
with the upload key `CN=NKS Talk` and `jarsigner` reports `jar verified`. The
release notes in all six languages match the source file character by character
after the upload. The Sentry and Rybbit hosts are set in the package.

TestFlight: the IPA has 30,166,266 B and the SHA-256
`f33f82aedc252f61ff055c4466f0b7a11872622d8511b4c96667c35340fd4cbc`. Both the
delivery UUID and the App Store Connect build record are
`aebb5664-02d5-4c24-b0c0-5e6458d865e8`. App Store Connect returns `VALID`, a
minimum of iOS 15.0, encryption `false` and Czech notes. The group Testeři is
`IN_BETA_TESTING`; Externí testeři were submitted to a beta review, which is
pending at the time of writing.

- An attachment held back by the ordering in the room no longer stops the whole
  queue. Previously one older job waiting for a confirmation was enough and
  every further image in the same conversation stayed at "Waiting to upload"
  forever, without an error and without a way to get it going. A rejected plan
  now means only skipping that one job; a parked confirmation additionally does
  not prevent the finalization of later attachments, because it itself moves
  only on an explicit retry. Outstanding attachments finish by themselves, even
  after the application restarts.
- Background network jobs no longer stay unattended when their owner is gone.
  Client Push cancels the capability request, the connecting, the handshake, the
  event stream and the backoff; it closes a socket connected late and with
  several accounts signals the cancellation to all of them at once. The public
  boundary of the conversation synchronization converts transport errors into a
  typed sync state and preserves the force-full retry after a failure of a
  weaker incremental flight.
- The watchdog telemetry explicitly enables AppHang 2 s, native breadcrumbs and
  scope sync. The previous run stores only four privacy-safe tags: the type of
  run, the lifecycle, the RSS bucket and the recorded memory pressure. After the
  scope is cleared, the release gate adds these tags again and a test checks the
  real resulting Sentry event.
- An audit of the historical Sentry groups told the synthetic release gates from
  the real crashes. `NKS-TALK-2` from build 1 could not be reproduced on the
  original or the current layout, so no speculative fix was made. The real
  `NKS-TALK-P` from build 36 — a physical iPhone in the phase `localPrepared`
  without a single attempt and without a credential retry — is fixed by the first
  point of this release. The bug was not in the Apple Keychain: a zero count of
  credential retries and the missing event about an unavailable sign-in prove
  that the run never got to the credentials at all. A pass on a physical device
  with this build remains.

## 0.1.0 (36) — 1 September 2026

Play: build 36 was not released in this priority iOS fix.
TestFlight: Apple ContentDelivery accepted exactly one IPA of the size
30,149,946 B, verified its MD5
`AD2E839D201A6A640A17D50CDFDA9357` and completed the upload without an error.
Both the delivery UUID and the App Store Connect build record are
`<profile-uuid>`. App Store Connect returns `VALID`, a
minimum of iOS 15.0, encryption `false`, Czech notes matching this changelog,
both the internal and the external group `IN_BETA_TESTING` and the beta review
`APPROVED`.

The original local IPA was removed by mistake by an automatically repeated
release job after the successful upload, so its SHA-256 cannot be honestly
documented. A repeated export had a different size and MD5 and its SHA is not
passed off as the distributed artifact. The distribution source is the exact
commit `9edf7c6` with the same tree as `da84214`; the git archive had
13,086,720 B and the SHA-256
`5266F1494A636BCADD51321F36F288D0CCA482F93A7D3CDBAC8215B6938E93BB`.
The Flutter tests ended 95/95 and the protocol attachment tests 30/30. The store
build contains four ordinary production telemetry values, but the synthetic
release gate is off, so the testers do not create verification events on every
start. After the release, approximately 1.68 GiB of precisely delimited build,
archive, export, DerivedData and temporary content was removed; the clean
source, the simulator data, the installed simulator build 36 and the signing
were kept.

- An iOS upload no longer stays in the phase `localPrepared` forever after an
  attachment is successfully accepted, when a second read of the Apple Keychain
  temporarily returns `-25320` or `-60008`. The scheduler catches the error,
  repeats the read after 2 s, 10 s and 60 s and on a permanent failure shows a
  reauthentication instead of waiting endlessly. The same flow respects the
  cancellation of an account, closing the service, FIFO and an existing retry
  timer.
- Sentry has a mandatory release gate for both an application error and
  structured attachment data. The Android 14 release and the iOS 18.6 Simulator
  build 36 sent both events under `production` and `dist=36`; the attachment
  payload contained no user, no request and no breadcrumbs. All the previously
  open NKS Talk issues were closed after the fix was assigned and verified; at
  the moment of the release gate the query `is:unresolved` returned an empty
  list. The later `NKS-TALK-P` is described under Not released.
- A real iOS 18.6 PHPicker upload of build 36 passed from picking the JPEG
  through the app-owned copy, WebDAV and the Talk finalize all the way to one
  authoritatively confirmed server-side message. The source was released, the
  job had no error and the test message was deleted after the evidence was
  taken.

## 0.1.0 (35) — 1 September 2026

Play: build 35 was not released in this priority iOS fix.
TestFlight: the IPA has 30,151,224 B and the SHA-256
`35C44CAC2C468D28725069626A375B81E13F45C270D3CBBE3A5F827F05843A1E`.
App Store Connect returns the build record
`f9f729fa-e50b-4733-b4ef-ae706db5b10a` in the state `VALID`, a minimum of
iOS 15.0, encryption `false`, exact Czech notes and both the internal and the
external group `IN_BETA_TESTING`; the beta review is `APPROVED`.

The clean build-mac source at `e9b52fe` passed 75/75 focused tests and the analyze
with no finding. The distribution artifact has a valid Sentry configuration in
the environment `production`. After the build, approximately 1.62 GiB of
archive, export, DerivedData, Pods and temporary data was removed; the simulator
data and the signing were kept.

- Build 35 fixed the blocking of a new upload by an older automatic retry and
  added phase diagnostics. The subsequent physical test, however, documented a
  second independent bug: a temporarily refused second Keychain read ended the
  scheduler future and the attachment nevertheless stayed at "Waiting to
  upload". This build is therefore not the final fix of the iOS gallery; the
  complete fix comes only in the following slice.
- In the conversation detail, owners and moderators on a server with `bots-v1`
  can display the available bots and turn them on or off. The list loads only
  after the section is opened, handles an empty/error state and re-verifies the
  current permissions before every change.
- When the Apple Keychain temporarily refuses access during sleep or a dark
  wake, the application no longer reports this situation as a crash or as a
  missing password. The stored account stays untouched and both the
  synchronization and the push registration are safely repeated; a late attempt
  after an account is removed cannot re-register it.

## 0.1.0 (34) — 1 September 2026

Play: the AAB with Sentry and Rybbit enabled has 83,485,780 B and the SHA-256
`<fingerprint>`.
The Publishing API uploaded it and committed it into the closed `alpha` track; a
new edit returns `(34) 0.1.0` in the state `completed` and six genuinely
translated sets of notes.
TestFlight: the IPA has 30,024,771 B and the SHA-256
`<fingerprint>`.
App Store Connect returns `VALID`, a minimum of iOS 15.0, encryption `false`,
Czech notes and both the internal and the external group `IN_BETA_TESTING`; the
beta review is `APPROVED`.

The Android 14 release build preserved the account as an upgrade and passed live
through the app lock, both a cold and a warm Direct Share of text, References
across a restart in light/dark, and the fixed composer. The iOS 18.6 update
install preserved the account; the paperclip is at x=12 on its own on the left
and Giphy, emoji, the microphone and Send are on the right at
x=240/288/336/384. The signed native XCTests ended 27/27.

- The action row under the input field has the paperclip alone on the left.
  Giphy, emoji, the microphone and Send are grouped on the right again in their
  original order; the layout stays the same during loading and after an error of
  a voice message.
- On Android, text or one file from another application can be shared into NKS
  Talk. After both a cold and a warm start the exact account and conversation
  are chosen; the file is first safely copied into the application's storage and
  a repeated system delivery does not send it a second time.
- Ordinary HTTPS links in messages are displayed as an OpenGraph card on a
  server with the References API. An unknown provider has a safe generic
  preview; on an error the original inline link stays and a tap never uses a
  target planted by the server.
- One file can be dragged into an open conversation on Windows, macOS and Linux.
  A directory, several files or an input that is too large are rejected; an
  accepted file is immediately safely copied and continues with the same upload
  as the paperclip.
- In the settings on Android and iOS the app lock can be turned on. The accounts
  and messages are not shown after a start or a return from the background until
  the system confirms a biometric or the device passcode; a cancellation and an
  error leave the application locked with an option to try again.

## 0.1.0 (33) — 1 September 2026

Play: the AAB with Sentry and Rybbit enabled has 82,500,756 B and the SHA-256
`5239FEBE8009AFA24945F873148401F24152A3708913A2E58E3AB936A177DE38`.
The Publishing API uploaded it and committed it into the closed `alpha` track; a
new edit returns `(33) 0.1.0` in the state `completed` and six genuinely
translated sets of notes.
TestFlight: the IPA has 29,783,651 B and the SHA-256
`8D5E5C68F34ECC399262E4E0578598A9D3454E1377DBEC8A7CE93D75FE6E9DC2`.
App Store Connect returns `VALID`, a minimum of iOS 15.0, encryption `false`,
Czech notes and both the internal and the external group `IN_BETA_TESTING`; the
beta review is `APPROVED`.

The Android release APK was installed as an upgrade on Android 14 with the
account preserved. A cold start opened the signed-in conversation list, the
process stayed alive and its log had no FATAL, no ANR and no unhandled
exception.

- From the paperclip, a contact from the system address book can be picked and
  sent as a standard vCard attachment. Neither Android nor iOS requires blanket
  access to the contacts; the user picks exactly one card. The photo is removed
  from the export, the size is limited to 2 MiB and the attachment uses the same
  safe upload as the other files.
- Before every server-side mutation, the call lifecycle activates the exact Talk
  room session and carries its cookie only within that account. A real call
  started from a web Talk session appeared on iOS in the live banner and
  disappeared again after it ended. The WebRTC media and the join button stay
  disabled.
- Support for iOS Universal Links for the reference Nextcloud host is prepared.
  A single HTTPS/no-userinfo validator preserves the order of cold/warm links.
  The server now publishes a versioned AASA document for `/call/*` and
  `/index.php/call/*` without a redirect. The production Apple CDN returns the
  same document and iOS 18.6 opened an HTTPS link directly in the correct room
  without Safari.
- The Czech iOS system location permission no longer mixes in an English purpose
  string. Build 33 contains a separate Czech and English `InfoPlist.strings` and
  a live iOS 18.6 dialog showed the correct Czech sentence.
- The Android release license gate now tracks the exact Maven coordinates and
  the content of the real runtime graph too. A change of a dependency therefore
  regenerates the SBOM and the notice instead of using an old cached output;
  build 33 also covers `play-services-location` brought in by the production
  geolocation plugin.

## 0.1.0 (32) — 1 September 2026

Play: the AAB with Sentry and Rybbit enabled has 82,411,005 B and the SHA-256
`9E9A7A6B1558777F8E7070E3641AFBC4AED393A1DF0823A66CB44019B1845C02`.
The Publishing API uploaded it and committed it into the closed `alpha` track; a
new edit returns `(32) 0.1.0` in the state `completed` and six genuinely
translated sets of notes.
TestFlight: the IPA has 29,760,109 B and the SHA-256
`<fingerprint>`.
App Store Connect returns `VALID`, a minimum of iOS 15.0, encryption `false`,
Czech notes and both the internal and the external group `IN_BETA_TESTING`; the
beta review is `APPROVED`.

The Android release APK was installed through `adb install -r` with the account
preserved. It confirmed live the toolbar from the left edge, the Poll in the
paperclip of a supported room and three identical threads after two further
refresh cycles. The same commit on the preserved iOS 18.6 simulator confirmed
the order of the toolbar, the Poll, a real conversation-list underlay during an
edge swipe and a stable trio of threads after two pull-refresh gestures.

- The actions under the input line start from the left edge in the order
  paperclip, Giphy, emoji, microphone and Send. The same alignment applies
  during loading and after an error.
- Ordinary threads derived from replies no longer disappear every other refresh
  of the list. A refresh marks a locally derived row as recent again and
  preserves its subscription, detail and notification level; a server-side named
  row does not overwrite the local projection.
- An open paperclip menu reacts to the completion of a capability check. The
  Poll appears without the menu being closed and reopened; after a failed check
  only the loading state disappears and an unsupported action stays hidden.
- The iOS swipe back from the main conversation uses a real route above a live
  cached list. The interactive preview therefore shows real conversations, the
  same as a return from a thread detail. From a child detail the first step back
  returns the main conversation and only the second the list; the Android system
  back is unchanged.
- The peer's typing in a 1:1 conversation works again. Before the HPB
  connection, the client activates the Talk room, uses the returned non-zero
  session ID and holds the session cookie only in the memory of that account.
  The cookies are not shared even between two accounts on the same server. A
  serialized lease prevents an old cleanup from cancelling a newer session; a
  deactivation, a 401, closing the API and removing the account all end only
  their own generation. Account removal atomically closes the admission, the
  server-side session and the HPB lane before the credentials are revoked; a
  delayed activation cannot reopen it.

## 0.1.0 (31) — 1 September 2026

Play: the AAB with Sentry and Rybbit enabled has 82,281,069 B and the SHA-256
`011F43C5C9A8C187510E87A8B03DD3F801F23EEF8BE1F9F5EF3196BD34E9882A`.
The Publishing API uploaded it and committed it into the closed `alpha` track; a
new edit returns `(31) 0.1.0` in the state `completed`.
TestFlight: the IPA has 29,724,195 B and the SHA-256
`<fingerprint>`.
App Store Connect returns `VALID`, a minimum of iOS 15.0, encryption `false`,
Czech notes and both the internal and the external group `IN_BETA_TESTING`; the
beta review is `APPROVED`.

On the preserved iPhone 16 Pro Max / iOS 18.6 an upgrade installation from the
same commit passed. A real photo from the PHPicker ended `completed` even with
an older exhausted `retryable` job without a timer in the same room. The old job
was preserved, the new source was released and the server confirmed the exact
message ID and the file name through an authenticated context request. The test
messages, the fixture and the local backup were removed after the evidence was
taken.

- Secure Storage has versioned migrations of its own, separate from the schema
  of the database. An interrupted move of credentials is safely resumed, and a
  conflicting copy and an unknown newer version fail without deleting the app
  password.
- The desktop settings offer starting automatically after signing in. Windows
  uses the user `HKCU Run`, macOS 13+ `SMAppService` and Linux XDG Autostart;
  after a change the client re-verifies the real system state.
- Removing an account first stops its root and thread long polls, the upload
  requests and the retry timers. A late response after the logout can no longer
  write a state or start an upload again and the other accounts stay active.
- New remote messages in a conversation that is currently open are handed to the
  screen reader. The history, one's own outbox, system and reaction messages are
  not announced and several quick arrivals are merged into one short
  announcement.
- In the conversation detail a custom background colour of the messages can be
  set, or one can return to the application theme. The choice is separated by
  account and room, applies in threads too, and a contrast gate weakens it
  according to the light, the dark and the server theme so that the texts and
  the dividers stay readable.
- An old upload waiting for manual handling after its automatic retries were
  exhausted no longer blocks a newly picked photo in the same conversation. A
  newer attachment can go through both the upload and the finalize; the original
  job and its file are preserved for a manual retry or a cleanup.

## 0.1.0 (30) — 31 August 2026

Play: the AAB with Sentry and Rybbit enabled was uploaded through the Publishing
API and committed into the closed alpha track; the track returns build 30 in the
state `completed`.
TestFlight: the build is `VALID`, without non-exempt encryption, from iOS 15.0
and in both the internal and the external group `IN_BETA_TESTING`; the beta
review is `APPROVED`.
The previous iOS build 29 was expired after the poll renderer was found and
removed from both groups; it was not uploaded to Play.

- The colour accent of the application follows the theme of the currently
  selected Nextcloud account. The colour is verified from the authenticated
  capabilities, is stored separately for each account and changes on an account
  switch without state being shared between servers.
- The input line has the paperclip as the first action, with Giphy and emoji
  next to it. The microphone is directly before Send and the duplicate quick
  image button with `+` was removed; the gallery stays in the paperclip.
- On a supported server, a poll can be created from the paperclip, one or more
  answers chosen and voted on right away. The client binds the mutations to the
  current account, room and thread and does not blindly repeat them on an
  unclear response.
- A shared location shows a local preview with a marker directly in the message.
  It loads live OpenStreetMap tiles only after an explicit tap; it uses only
  validated coordinates and ignores the link supplied by the server.
- When the system denies access to the camera, the photo gallery, saving an
  image or the microphone, the error state offers to open the application
  settings directly. Network, quota and server errors do not offer this action.
- The Push notifications settings show the real system state of the permission.
  A first request can be made there, or the application settings opened after a
  denial; the state is refreshed automatically after the return.
- The iOS gallery passed on a clean iOS 18.6 Simulator with a real asset: the
  durable copy, WebDAV/finalize and the server-side message all finished in
  2.16 s. That evidence, however, did not contain an older exhausted upload
  preserved during a TestFlight update. A subsequent report from the physical
  build 29 therefore revealed a further blockage of the queue, which build 30
  does not yet fix.

## 0.1.0 (28) — 31 August 2026

Play: uploaded and committed into the closed alpha track through the Publishing
API; after the commit the track returns build 28 in the state `completed`.
TestFlight: not released. The RemoteCmd/build-mac tool is not available in this
session, so the Apple build is not pretended to be done.

- The quick image button with `+` for a direct pick from the gallery returned
  into the main input line. The paperclip for the other sources and a separate
  GIF stay.
- Android 13+ uses the system predictive-back branch instead of the deprecated
  callback. When access to the location is permanently denied, the error message
  offers to open the application settings directly.
- After the first load, the Giphy picker reopens from a warm account-scoped
  cache without a further trending request and a full-screen spinner. The
  paperclip for attachments stays in the toolbar even during the initial Giphy
  check.
- The Location was added to the paperclip. The application requests a foreground
  permission, finds the current coordinates, shows them before sending and
  shares them only on a server that supports this feature. It does not use
  background location tracking. If the server's response is lost after sending,
  the application warns about a possible success instead of blindly repeating
  and risking a duplicate message.

## 0.1.0 (27) — 31 August 2026

Play: uploaded and committed into the closed alpha track through the Publishing
API; after the commit the track returns build 27 in the state `completed`.
TestFlight: not released. The RemoteCmd tool is not available in this session
and the last verified state of the build-mac relay rejects the stored tokens with a
401; the Apple build is therefore not pretended to be done.

- A photo picked from the iOS Photos no longer starts the network part of the
  upload until the application really returns to the foreground after the picker
  is closed. The attachment therefore does not hang at "Waiting to upload"; if
  the return does not complete, the wait is bounded and offers a retry.
- The paperclip in the input line groups the gallery, the camera and a file. The
  GIF stays as a quick icon next to the field. A long press of the Send button
  now offers a silent and, where the server supports it, also a scheduled send.
- An ordinary chain of replies opened from the thread list no longer ends with a
  message that the thread is not available on the server. Such an item comes
  from the local history and now opens straight into the chat; the server-side
  detail stays only for genuinely named threads.
- A message can be translated into one of the languages the connected Nextcloud
  offers. The application can have the source language detected, preserves the
  mentions and allows the result to be copied. The option is shown only on a
  server with an active translation provider.
- In the detail of a supported conversation, shared files, images, recordings,
  locations, polls and other server-side categories are available. The list is
  paginated, an unsuccessful load can be retried in it and a tap opens the
  original message even inside a thread.
- When switching conversations in a wide three-pane layout, the detail no longer
  carries over the controls and the permissions of the previous room.

## 0.1.0 (26) — 31 August 2026

Play: uploaded and committed into the closed alpha track through the Publishing
API; after the commit the track returns build 26 in the state `completed`.
TestFlight: the build is `VALID`, without non-exempt encryption, a minimum of
iOS 15.0, in both the internal and the external group with Czech notes.

- The local diagnostics shows the real stored as well as the expected version of
  the database, the state of the migration and the number of foreign key
  violations. Previously it showed only the number built into the application,
  so it did not recognize an old or a newer database.
- The contract for creating a conversation rejects a group room with an
  invitation to a specific user. Talk does not support that combination; users
  are added into a group only through the participant endpoint.
- The summary in the conversation detail aligns with the controls right after a
  change of the public access, the read-only mode or the picture. Previously it
  showed the original type, state and avatar after a change.

## 0.1.0 (25) — 31 August 2026

Play: uploaded and committed into the closed alpha track through the Publishing
API; after the commit the track returns build 25 in the state `completed`.
TestFlight: the build is `VALID`, without non-exempt encryption, a minimum of
iOS 15.0, in both the internal and the external group with Czech notes.

- When a voice recording does not start on iOS, the wait ends after 10 seconds
  with an error and the application stays usable. A further attempt no longer
  blocks the previous native recording.
- The Czech error message of a voice message fits into the bottom bar together
  with all the actions. Previously it overflowed off-screen.
- An empty group or public room can be created from the new-conversation screen
  without searching for and inviting the first participant.
- A shared location is displayed in the chat with the name of the place and a
  map icon. A tap opens it in OpenStreetMap; invalid or planted coordinates stay
  safely inert.
- In a private conversation, the current out-of-office of the other person is
  shown, including the period, the message and any substitute. A long text does
  not stretch the banner across the whole chat even with an enlarged system
  font.
- Above the chat, the nearest calendar event that links to that conversation is
  recalled. The banner shows the name and the time and can be dismissed.
- A shared contact in the vCard format is displayed as a contact instead of a
  general file. A tap safely downloads it and opens it in the system contact
  preview.
- In an open conversation it is shown who is currently typing. Several people
  typing are merged into one row; the indicator disappears after the typing ends
  or after a connection outage and respects the privacy setting of Nextcloud
  Talk. One's own indicator is sent correctly after the signaling is restored
  too; an old non-empty draft does not restart it by itself.
- A GIF received from a server without an active Giphy integration no longer
  offers a non-working retry. Instead it shows that GIFs are not available on
  the server; the link itself is not displayed.
- The GIF picker remembers the thumbnails it has already downloaded within an
  account. It does not download them again when the same grid is reopened.
- In the detail of a supported conversation, a moderator can turn on a phone and
  SIP connection with a personal PIN, without a PIN, or turn it off. The options
  are shown only when the server and the account really support them. After it
  is turned on, every participant sees the server-side instructions, the meeting
  ID and possibly their personal PIN.

## 0.1.0 (23) — 30 August 2026

Play: submitted for review. TestFlight: the build is `VALID`, both groups.

- A crash was fixed that could happen when opening a conversation from a
  notification or a link at the moment when the main screen was closing. An
  unfinished navigation now ends safely.

## 0.1.0 (22) — 30 August 2026

Play: published 30 Aug 14:39, available to the testers, 177 countries.
TestFlight: the build is `VALID`, both groups.

- "Choose image" on iOS opens the Photos library. Previously this option
  mistakenly opened the document browser, so a screenshot stored only in Photos
  could not be attached to a message.

## 0.1.0 (21) — 30 August 2026

Play: published 30 Aug 13:36, available to the testers, 177 countries.
TestFlight: the build is `VALID`, both groups.

- When dragging an open conversation back, the real conversation list is now
  visible beneath it. Previously the chat moved correctly but uncovered only an
  empty background.

## 0.1.0 (20) — 30 August 2026

Play: published 30 Aug 8:51, available to the testers, 177 countries.
TestFlight: the build is `VALID`, both groups.

- An emoji as a conversation picture can be given a colour. A row of background
  colours was added to the emoji picker. By default the colour is not sent at
  all, so the background follows the light or the dark mode as it did until now.

This build also brings everything from builds 17 to 19, which Play did not
manage to approve and replaced with it:

- Searching is possible within a single conversation too. A magnifier was added
  to its bar that searches only it; searching from the conversation list still
  goes across all of them.
- The status can be cleared by itself: in 30 minutes, in an hour, in 4 hours,
  today or this week.
- A message in a group can be replied to privately.

## 0.1.0 (19) — 30 August 2026

Play: submitted for review, replaced by build 20 before approval.
TestFlight: skipped, build 20 replaced it.

- Searching is possible within a single conversation too. A magnifier was added
  to its bar that searches only it; searching from the conversation list still
  goes across all of them. The application had always been able to do it, but
  there was nowhere to click for it.

## 0.1.0 (18) — 30 August 2026

Play: submitted for review, replaced by build 20 before approval.
TestFlight: skipped, build 20 replaced it.

- The status can be cleared by itself. A "Clear status" option was added next to
  the message field: in 30 minutes, in an hour, in 4 hours, today or this week.
  Until now the status could be set but not cancelled by time, so "I'm at lunch"
  hung by the name until the evening.
- "Today" ends at midnight and "This week" on Sunday, both according to the time
  of your phone.

## 0.1.0 (17) — 30 August 2026

Play: submitted for review, replaced by build 18 before approval.
TestFlight: skipped, build 20 replaced it.

- A message in a group can be replied to privately. "Reply privately" was added
  to the menu of someone else's message: the written reply is sent into your
  private conversation with the author and carries a link to the original
  message with it, so the other side sees what it is about. The conversation is
  created by itself if it does not exist yet.
- A private reply would, meanwhile, not have gone through at all until now. The
  application expected the server to name a private conversation with a list of
  both participants, whereas it sends the name of the other person. The
  verification therefore failed every time.

## 0.1.0 (16) — 29 August 2026

Play: published. TestFlight: the build is `VALID`, both groups.

- The licenses of the libraries the application is made of were added to the
  settings. They are in the Local diagnostics. The application stands on 171
  packages and their licenses require their text to travel with the program —
  until now there was nowhere in the application where it could be read.

## 0.1.0 (15) — 29 August 2026

Play: published. TestFlight: the build is `VALID`, both groups.

- Written text is sent as the caption of an attachment. When you have something
  written and attach an image or a file, the text goes with it instead of
  staying in the field. An empty field sends no caption and a voice message does
  not take one.

## 0.1.0 (14) — 29 August 2026

Play: published. TestFlight: the build is `VALID`, both groups.

- A lost connection to the notification channel stopped being reported as a
  crash of the application. When the system puts the phone to sleep and discards
  the connection, closing it fails — that is an ordinary end of a connection,
  not a crash.
- The application also stopped freezing on it: the cleanup of that connection
  never finished in such a case.

## 0.1.0 (13) — 29 August 2026

Play: published. TestFlight: the build is `VALID`, both groups.

- A moderator can delete a message they did not write too. The server has always
  allowed it, but the application offered deletion only for one's own messages,
  so a moderator could do nothing about an inappropriate post.

## 0.1.0 (12) — 29 August 2026

Play: published. TestFlight: the build is `VALID`, both groups.

- A conversation you may not write into no longer offers an input field. Until
  now a message could be written and sent and only then came the refusal. It
  concerns two cases the application could not tell apart: a moderator took your
  right to write in the conversation, or the conversation has not started yet
  and you are waiting in the lobby. In place of the field there is now a lock
  that says which of the two it is.
- A message cannot be forwarded into a conversation where you would not send it
  anyway.

## 0.1.0 (11) — 29 August 2026

Play: published. TestFlight: the build is `VALID`, both groups.

- Threads in the list are named after the message they came from. A thread
  without a name was called just "Thread" until now, so two threads in one
  conversation could not be told apart.
- The thread list no longer claims there are none before it asks the server. The
  loading was started only after the first render, so the screen answered before
  it had a chance to ask.
- A network outage during a wake-up on a notification stopped being reported as
  a crash of the application. A sync will ordinarily fail at such a moment,
  because the device is only just connecting; the other wake-up route had always
  taken it that way.

## 0.1.0 (10) — 29 August 2026

Play: published. TestFlight: the build is `VALID`, both groups.

- The thread list also shows the threads that came about by replying. The server
  reports only named threads in the list, so a conversation full of replies
  looked empty. The application now adds the ones it knows from its stored
  messages.

## 0.1.0 (9) — 29 August 2026

Play: submitted for review. TestFlight: the build is `VALID`, both groups.

- A link to a conversation no longer brings the application down. The link
  arrived twice: once through our channel, which evaluates it against the
  signed-in accounts, and a second time as a named route from the system. The
  application had nothing to answer the second one with and crashed on every
  opened link. It was reported by telemetry from a real device.

## 0.1.0 (8) — 29 August 2026

Play: published 29 Aug 9:29. TestFlight: the build is `VALID`, both groups.

- An empty thread list no longer confuses. A reply to a message does not create
  a thread, which the screen kept quiet about until now and it looked as though
  the application was hiding replies the user demonstrably had.

## 0.1.0 (7) — 29 August 2026

Play: published 29 Aug 6:36. TestFlight: the build is `VALID`, both groups.

- Nothing interrupts reading the history any more. A message that arrives while
  you are deep in older messages leaves you exactly where you are. Until now it
  pushed you down by the height of its bubble. The timeline is now a
  `CustomScrollView` with a `center` key, so one end of the list does not
  reindex the other.
- An animated GIF is decoded to the size it is really drawn at, instead of a
  hardcoded 1080 pixels.

## 0.1.0 (6) — 29 August 2026

Play: published. TestFlight: the build is `VALID`, both groups.

- Dragging from the left edge takes you back to the conversation list. In the
  compact layout the conversation is not pushed as a route, so the system
  gesture had nothing to pop off the stack and did nothing.
- A silent send applies to a written message too, not just to attachments. A
  server without `silent-send` rejects the request instead of sending it out
  loud.
- Windows keeps a single instance and adds an icon to the system tray.

## 0.1.0 (5) — 29 August 2026

Play: published. TestFlight: the build is `VALID`, both groups.

- The second tick on a read message is no longer lost after returning into the
  conversation. The aggregated read marker was enabled on no server, because the
  capability profile had it hardcoded off.
- Other people's reactions reach an open conversation. Until now only the ones
  added from this device were visible.
- A sent message disappears from the input field right away. When typing
  continued during the send, it stayed there and could be sent a second time by
  mistake.
- A jump to the end of the conversation after going deep into the history.
- A reply by dragging the bubble.
- An emoji on its own in a message as well as in a reaction is rendered larger.

## 0.1.0 (4) — 29 August 2026

TestFlight only; this number did not reach Play, because Apple already had
builds 1 to 3 taken and the numbers were being unified.

- The same content as 0.1.0 (2) plus the telemetry compiled into the build.

## 0.1.0 (3) — 28 August 2026

TestFlight only, the build `VALID` from 28 Aug, assigned to both the internal
and the external group. The first build that got Czech notes for the testers.

## 0.1.0 (2) — 28 August 2026

Play: published 28 Aug 23:10, the first release available to the testers.

- Notifications reach a user who also has the official Talk application. The
  push device registration sends the correct User-Agent, by which the server
  determines the type of the application.
- Images are not distorted, either in the preview or after being opened.
- The bundle stopped asking for permissions to photos and videos that the
  application does not use.

## 0.1.0 (1) — 27 August 2026

TestFlight only, the build `VALID` from 27 Aug. The first build of the
application that reached the testers at all. The route to it and the four
blockers that fell along the way are described in
`docs/architecture/apple-distribution.md`.
