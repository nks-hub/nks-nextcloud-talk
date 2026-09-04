# Technical decisions

[Back to decisions and open choices](decisions.md)


### D-007: A modular client

State: Accepted for the first implementation baseline on 22 August 2026.

Pure Dart `talk_protocol` + the Flutter app. Storage and sync stay inside the app
until another real implementation justifies a package. Android Web Push uses the
embedded distributor without a project gateway; a future iOS APNs/PushKit relay
is a separate Apple platform boundary, not part of the client runtime.

### D-008: The standard Notifications app

State: Accepted as a compatible server boundary; D-025 refines the Android
transport.

Android uses the standard Notifications Web Push directly. Neither a new Talk
event listener nor a thin bridge is created, because it would not cover the
complete notification and markProcessed/delete semantics. The historical
Notifications push-v2 gateway contract remains research evidence, not a mandatory
service.

### D-009: A relational SQLite store

State: Accepted for the first implementation baseline on 22 August 2026.

A message, a thread, a parent, a room and a read marker require atomic
transactions. Drift will be used. The local Flutter 3.44.4/Dart 3.12.2 and the
pub.dev metadata of 22 August 2026 confirm compatibility of the Drift 2.34 and
`drift_flutter` 0.3 lines. The Flutter application now pins Drift 2.34.3 and
`drift_flutter` 0.3.1, uses account-scoped tables and a transactional
conversation merge. The Android and Windows debug builds and the repository tests
passed; the message/outbox migration and the Apple/Linux builds remain mandatory
evidence of further slices.

Drift calls `onUpgrade` on a downgrade too. The migration strategy therefore
first rejects `versionBefore > schemaVersion`; an older build must neither
overwrite the `PRAGMA user_version` of a newer database nor continue on top of an
unknown schema. A file-backed test checks not only the error on open, but also
that the original version and the data are preserved after a rejected rollback.

Talk does not provide a list of reader identities. `lastCommonReadMessage` is the
room-wide minimum of the markers of public user actors only; guests are not
included. The client may show the aggregated state only for its own
server-confirmed message, and only if the current account simultaneously proves
the capability `chat-read-status` and a public `config.chat.read-privacy`. A
private, missing or invalid policy explicitly invalidates the marker; a missing
header must not leave a stale "read". The invalidation stores the sentinel 0
atomically into both the chat scope and the cached conversation and reprojects
the outgoing UI back to `sent`. A later public snapshot without a new server
marker must not restore the historical value.

### D-010: Riverpod for application/UI state

State: Accepted for the first implementation baseline on 22 August 2026.

Chatujme provides a verified local pattern and Riverpod allows account-scoped
providers. The database state, however, stays the source of truth; a provider
must not duplicate the sync store. The first slice uses hand-defined providers
without code generation; the generator is added only when it reduces real
complexity.

### D-019: Adaptive navigation and form factors

State: Accepted as the mobile implementation baseline.

A phone uses the stack `onboarding → conversations → chat → thread`. Bottom
navigation is not added without at least three equivalent top-level
destinations. Tablet, foldable and desktop use an adaptive list-detail over the
same route model. From 720 logical px onwards the account rail, the list and the
detail are shown; the onboarding moves to two columns from 900 px. A deep link
first selects the `accountId` cryptographically or through a local account
mapping and only then builds the room/thread stack; it must not implicitly use
the currently active account. A unified-search result likewise preserves its own
account, room, message and canonical thread identity. A root result opens the
room scope, a reply opens an ordinary or a named thread according to a valid
cached root, and a missing or mismatched root fails closed instead of opening in
a different scope. The jump loader has to check the target after the last allowed
history fetch too, not only before it. Every asynchronous completion is
additionally bound to the route identity, the generation and the account; the
result of an older search navigation must not control a newer route, not even
after a delayed history fetch.

iOS preserves the edge-swipe back and Android both the system and the predictive
back. Gestures are only shortcuts with a visible alternative. A touch target is
at least 44 pt on iOS and 48 dp on Android. The detailed checkpoint is in the
[mobile design](../plans/2026-08-22-original-flutter-client-design.md).

Windows, macOS and Linux are not a separate client. The same Flutter codebase
additionally has to pass a window resize, keyboard navigation, focus/hover states
and a build on every target OS. The current foundation proves the layout and the
Windows runtime, not all desktop lifecycle features.

### D-020: Rich chat as a typed online mutation boundary

State: Accepted and implemented in the pure Dart runtime; the Flutter transport,
Drift and live server evidence remain part of slice 4.

Mentions, threads, reactions, edit/delete, pin, reminders and schedule are
selected exclusively from unique global and local Talk features. Every request
and response is bound to the account, the canonical server and the available
room/message/thread context. The rich state is an account-scoped layer over the
existing chat snapshot and changes only through a single-use candidate plan.

The nested `first` and `last` messages of thread metadata are trustworthy only
when the room token and the canonical `threadId` match. `first.id` must be the
root of the thread and `last.id` must match `lastMessageId`; both messages must
carry the same canonical `threadId`. A metadata-only rename in one candidate
reprojects the new title into the cached first/last/root, all their parent copies
and their immutable wire representations.

Markdown is not passed directly into Flutter widgets. The `markdown` package
creates an AST and our own renderer converts it into a bounded semantic tree with
typed Rich Object Strings, inactive raw HTML and a same-origin link policy. Both
plaintext and Markdown share a node budget consumed before a semantic node is
constructed; a late check of an already materialized tree is not a security
boundary.

An authoritative reaction/edit/delete response is propagated within one candidate
plan into the canonical message, every reply and scheduled parent copy, the
thread first/last, the room preview and their immutable wire representations.

Rich mutations are online-only in this slice. An ambiguous result is not retried
automatically and is not written into the text-send outbox. An offline replay may
only arise through a separate contract for every operation kind per D-006.

### D-021: An attachment as a confirmed durable two-phase job

State: Accepted and implemented in the pure Dart runtime, the Flutter HTTP
transport, the Drift job store and the orchestration; the combined
live-server/process-death and platform lifecycle evidence remain part of slice 5.

An attachment uses one durable job for the Talk OCS Draft probe, the WebDAV
normal or chunk upload, the Talk finalize and the subsequent confirmation by
chat. The job may hold only an app-owned copy or a persistable URI grant and
before every upload or resume it re-verifies the size and the SHA-256. A source
mismatch must not send different content under the original `referenceId`.

Chunk v1 does not use an HTTP `Range`; the byte range is only in the chunk name
and the `MOVE` always sends the exact `OC-Total-Length`. The XML multistatus is
UTF-8-only, rejects DTDs and entities and has a continuous byte, depth and node
limit.

An upload never overwrites the target path. A normal PUT uses `If-None-Match: *`,
a chunk MOVE `Overwrite: F`, and HTTP 412 is a typed collision after which the
job durably picks the next of at most 16 candidate names. A foreign colliding
path must not be deleted, not even during a later cancel or cleanup.

The finalize is not atomic. A successful response, a 5xx, a lost response, a body
that may have been sent and a restart in `finalizing` all lead to
`awaitingConfirmation`, never to a blind POST. The job is completed by exactly
one account/server/room/reference-bound `file_shared` message with the correct
`comment` or `voice-message` type and a file rich object. Zero matches is not
proof that nothing happened and several matches stays ambiguous.

After an ambiguous finalize or a restart, an ordinary reply may accept a compact
deleted parent only with an exact `parent.id == replyTo`, missing parent
room/thread metadata and a positive outer `threadId`. A named thread has a
separate deleted-root shape bound to the canonical root. After a restart the
client does not repeat the finalize POST; it waits for an authoritative catch-up
and exactly one match completes the job as well as the one-time cleanup of its
durable source.

Within one room, FIFO and single-flight apply to the finalization. A cancel
before the finalize cleans up only the chunk session and the Draft temp file
owned by the job; once the finalize has started, a possibly final file is not
deleted automatically.

The Flutter transport opens the app-owned source once, verifies the whole
snapshot and, for the individual chunks, requires an efficient bounded range read
without linearly discarding the preceding bytes. Cancel, timeout and close are
detachable and a lease obtained late is closed. The cleanup has a shared bounded
budget, but after one action fails it continues with the further steps; none of
this transport evidence yet proves a Drift resume or a real server-side upload.

### D-022: Separate signaling transports and an ephemeral session epoch

State: Accepted for the implementation of slice 10.

The internal OCS long poll and the external HPB WebSocket have a separate wire
profile and reconnect semantics. They share the account-scoped preparation
coordinator, the participant snapshot and the topology model, not a common queue
of JSON messages.

An HPB resume is used only within the 30-second server window and must preserve
the signaling session ID. A full hello creates a new session epoch, discards the
old participant/room confirmations and all pending peer frames, and requests a
new room join. Signaling frames are ephemeral and never form a durable outbox.

The state `signalingReady` is not `mediaReady`. Slice 10 exposes neither a call
REST mutation nor user-facing call controls; server-side in-call flags will only
arise with a real media engine in slice 11.

### D-023: A per-account push key handle and a shared Dart orchestrator

State: Superseded for Android by decision D-025. The implemented pure Dart
Notifications push-v2 runtime remains historical protocol evidence and a basis
for a future iOS relay, but does not drive Android delivery.

One provider token issued by the application's Firebase/APNs project may serve
several accounts, but it is not their identity. Every `accountId` has a separate
non-exportable RSA-2048 key handle, public key, generation and registration
revision. The private key never leaves the Android Keystore or the iOS Keychain;
Dart receives only the handle and a cryptographically verified result.

The pure Dart runtime owns one deterministic single-flight registration queue,
the authority/token/key binding, the exact retry, 409 recovery and revocation. An
incoming envelope may be routed by exactly one candidate with a valid signature
and decrypt. Before routing, the completion is compared again with the current
provider token, the registered state, the key handle/generation and the
registration revision. Zero, several or a stale candidate select no account and
start no OCS sync.

Disabling the capability preserves the account key in case it is enabled again.
Removing an account performs the Nextcloud unregister, the gateway unregister and
only then destroys the key. A transient remote cleanup stays as a durable
account-bound revocation tombstone; a capability refresh must not turn a
previously requested logout into merely disabling push. Neither a second account
nor the shared provider token may be removed.

### D-024: At-least-once push delivery and idempotent mobile processing

State: Superseded for Android at the transport boundary by D-025. The general
requirement for idempotent mobile handling of duplicates remains valid; the
gateway queue part does not carry over to Android Web Push.

A repeated `/notifications` batch is deduplicated before the durable enqueue by
the registration and the digest of the opaque envelope. The provider worker uses
a bounded lease and an at-least-once retry. FCM provides no application
idempotency key, so a crash after the provider ACK and before the local commit
may deliver the same envelope again; the gateway must not declare exactly-once.

The gateway acknowledges an item as accepted only after the DB commit. At the
verified SHA, Notifications does not repeat the same batch at the application
level after a transport error, so an in-memory or prematurely acknowledged
enqueue would irreversibly lose the wake-up.

After the cryptographic account routing, the phone computes the SHA-256 over the
exact decrypted payload bytes and keys the ledger by the pair accountId +
fingerprint within the same AES-GCM state commit as the event queue. A payload
with `nid`, `nids` or an activation token has a strong TTL of 7 days; delete-all
and a Message without a server ID are weak, only 60 seconds. The ledger is
limited to 128 items per account and 512 globally. Old state without a ledger is
loaded as empty. A repeat may safely start an OCS catch-up, but must not enqueue,
display or mutate a second event.

### D-025: Android over Notifications Web Push

State: SUPERSEDED by D-038 on 27 August 2026. Web Push remains a switchable
fallback, but since then the default transport on Android is our own proxy and
FCM. Everything below describes that fallback branch, not the default state.

The original state: Accepted after verifying Nextcloud Notifications 34.0.3 at
SHA `2a62d472d31b97de522c897c979912cd49b820a9`; the P1 platform reception and the
durable lifecycle are implemented, the server-side P2 orchestration and the
delivery E2E are missing.

Android uses the capability `webpush`, the UnifiedPush connector baseline 3.3.5
and the embedded FCM distributor 3.1.0. The upgrade in `1250c44` preserved the
existing API, the verified Apache-2.0 license and the separate version of the
distributor, and passed the Kotlin tests, compile, the duplicate-classes check
and `assembleDebug`. The server supplies the VAPID public key, the client obtains
the subscription endpoint and completes the register → activation token →
activate flow at runtime for every `accountId`.

The Nextcloud administrator explicitly enables Web Push with a toggle in
Administration → Notifications; they enter no FCM credentials and no gateway. The
client assigns every account its own connector instance and subscription
generation. A callback is accepted only for the currently valid pair and then
starts an account-scoped OCS catch-up.

The Android platform notification ID is neither the server `nid` nor a global
constant. An encrypted bounded ledger maps `(accountId, nid)` onto a stable
positive ID, skips reserved values and, on a hash collision, deterministically
looks for the next one. A tap, reply, read, delete-one and delete-all all first
resolve the same account route; they must never dismiss or open a notification of
another account. An upgrade of old state without a ledger starts with an empty
map and preserves the other push state.

In the fallback Web Push branch, a public Android build needs no publisher
Firebase project, no `google-services.json`, no own mobile gateway and no
per-server rebuild; the default proxy branch per D-038, by contrast, has them.
The embedded distributor is a library inside the APK, not another application.
Nextcloud 34+ needs no addon; a possible Nextcloud 33 backport must be a complete
standalone AGPL implementation of Web Push, not a thin bridge.

A duplicate or delayed payload may only idempotently wake an account-scoped OCS
catch-up. The subscription endpoint, the auth secret, the activation token and
the payload must not be logged. The exact flow and the test matrix are in the
[push analysis](../research/push-fcm.md).

If the signed-in capabilities do not contain `webpush`, the client must not read
the VAPID key, ask for the notification permission or start a registration. An
existing active or in-progress generation is durably moved into
server-revoke-pending and the credentialed OCS DELETE may only be repeated
idempotently. A local retire/unregister is allowed only after HTTP 200/202; a
transient error keeps both the credential and the generation for a bounded
account retry.

The native P1 adapter stores a callback synchronously into an AES-GCM envelope
protected by the Android Keystore, and only then announces the available event to
Dart. The endpoint commit is separate from the event `ack`. Replacing the
subscription uses make-before-break: the old generation may be unregistered
natively only after a confirmed server-side revoke. A spontaneous distributor
unregister cannot be reopened under the same generation. A late endpoint and a
late commit after `UNREGISTERED` therefore must not restore a generation or
overwrite the ID of the last server-confirmed endpoint. These invariants have
focused Dart/Kotlin tests and a two-step instrumentation after the process was
terminated; they do not yet prove the OCS activation, a local notification or a
background/killed payload from a real Nextcloud.

The provider ACK is not the source of truth for the content of notifications.
Every active account therefore performs a bounded OCS reconciliation after
foreground/resume, after connectivity returns and at most every six hours.
Wake-ups are coalesced globally as well as per account; a transient sync error is
retried, but one error must not block another account. Removing an account first
increases the epoch and suspends its lane. A late lifecycle or notification-open
callback with the old epoch then must not restart the registration or a catch-up
before the revocation completes.

This guarantee only begins with the connector callback. The embedded FCM
distributor 3.1.0 acknowledges the GMS broadcast/RPC to the provider before it
hands the message to the application receiver; the current build therefore does
not prove a durable commit before the provider FCM ACK. A process crash in that
window may lose a wake-up, but never server-side OCS data. On foreground/resume
and in bounded periodic work, the client has to perform an account-scoped OCS
reconciliation. Forking the distributor is not a condition of P1; it would become
necessary only with a future requirement for a stronger transport guarantee.

### D-026: The minimum platform baseline

State: Updated after the first real macOS build on 26 August 2026.

- Android minSdk 24, targetSdk 36 and compileSdk 37 in the verified debug build;
- iOS deployment target 13.0;
- macOS deployment target 11.0; `gal 2.3.3`, used for saving media, declares the
  same minimum in both the Swift Package and the CocoaPods contract;
- Windows and Linux per the toolchain baseline of Flutter 3.44.4.

Raising the minimum requires a specific dependency or OS API reason. The first
remote macOS build documented exactly the conflict of the original 10.15 with the
native minimum of `gal`. Lowering the minimum requires a real build and a runtime
test, not merely a change of a number.

### D-027: The desktop as a full product target

State: Accepted by the user on 23 August 2026.

Windows, macOS and Linux use the same account, protocol, Drift and feature model
as mobile. The expanded shell is three-pane and responds to a window change.
Desktop-specific keyboard handling, hover/focus, the system tray, auto-start,
file drop and background delivery are created only as verified platform slices;
they must not be faked by the existence of a generated runner.

Auto-start is a local preference of the application, not of the account. Windows
owns it in the per-user `HKCU Run`, macOS 13+ through `SMAppService.mainApp` and
Linux through an XDG Autostart file in the user config directory. After a write,
Flutter always reads the real OS state again; neither an incomplete write nor a
login item awaiting approval may be shown as enabled. macOS 11–12 stays
explicitly unsupported instead of a legacy helper or a write outside the sandbox.

The Windows evidence from source `0be4c88` passed the release build, a 29/29
bundle manifest and a responsive runtime on a dedicated Windows 11 VM. The
Inspector capture proves the Flutter render, not the real pixels of the release
DirectComposition window; a signed-in desktop E2E therefore stays a separate
gate. Commit `1b1066a` packaged the same product as a per-user Inno Setup
installation. A dedicated VM verified a clean install, launch, an upgrade while
running, a rejected downgrade with no byte changed, preservation of the support
data and uninstall. Release signing stays open.

The Apple evidence from source `83078cd` passed on macOS 15.7.4 arm64 through
analyze, a clean debug as well as universal release build, codesign verify and a
live 800×628 window. The real Flutter inspector render proves the debug UI; the
native window capture failed and is not evidence. The same source passed a clean
iOS Simulator build, install, launch and framebuffer capture on an iPhone 16 Pro
with iOS 18.6. Neither the ad-hoc signature nor the simulator prove distribution
signing, a physical device, a Keychain login, APNs/PushKit or the background
lifecycle.

### D-028: Giphy as a rendered reference

State: Rewritten on 25 August 2026 by an explicit user decision. The previous
attachment variant is described below and no longer applies.

The GIF is not stored in the user's storage. A selection in the picker sends the
`resourceUrl` as a message and the bubble renders it: the client resolves the
reference through the account-scoped Nextcloud References resolver and shows the
animated GIF inline. The user therefore does not see a URL, but an animation.

The reason for the change is that an attachment creates a file in the user's
Files, which is disproportionate for sending a GIF. A rendered reference matches
how Chatujme solves it.

The security boundaries stay: the client accepts only `integration_giphy_gif`,
the same-origin proxy of the specific server and valid `image/gif` bytes. The
loader is account-scoped, bounded and with an LRU. The only visible external link
is the mandatory GIPHY attribution in the picker.

The picker thumbnail repository shares a concurrent request for the same URL and
holds at most 32 verified images or 16 MiB per account instance. The cache is
discarded together with the repository; an explicitly cancelled load stays
separate, so that one caller does not cancel the others.

A known limitation: a recipient without the Giphy integration enabled on their
server will not resolve the reference and will see a link. That is the price of
the chosen variant.

### D-028a: The historical variant of Giphy as a Talk attachment

State: The original wire-reference variant was replaced on 25 August 2026 by an
explicit user decision. Commit `7ca580e` wires the picker to the real attachment
flow and has automated evidence; a live server round trip stays open.

The selected `resourceUrl` serves only as an input into the account-scoped
Nextcloud References resolver. The client accepts only `integration_giphy_gif`,
the same-origin proxy and valid `image/gif` bytes. It stores the bytes into a
durable app-owned source and sends them through the same Talk
Draft/WebDAV/finalize flow as any other image attachment. The Giphy URL is never
inserted into `sendText`, the composer or the text message outbox.

The original renderer of the hidden wire URL remains only for compatibility with
older messages. The historical Android test of this variant is valid evidence of
the behaviour of that time, but does not prove the new target attachment flow.
The new flow must not fall back to a URL text message on any error.

### D-029: Presence only from the server user status

State: Accepted on 25 August 2026, commit `85fdb44`. Verified live against the
reference instance on `emulator-5554`.

Presence is derived exclusively from the `status` field of the conversation v4
room object, which the server supplies after `includeStatus=true`. The client
must not guess presence from local activity, the time of the last poll, an open
websocket or from `lastActivity`. The badge is rendered only for a one-to-one
room (`type = 1`); `offline`, `invisible` and an unknown value render no badge at
all.

`statusIcon` and `statusMessage` are the user's own status. The client shows them
only until `statusClearAt` has passed; after it expires, only the basic state
remains, without foreign text.

An incremental response returning a room without the `status` key preserves the
previous value. A full response is authoritative and overwrites the value even
with an empty one. The reason is that a delta is a partial view, while a full
fetch represents the complete server state of the account.

The original schema v8 added the projection columns without backfilling the old
`raw_json`. Schema v13 therefore repairs v8–v12 databases once, and only when the
whole presence quadruple is NULL and `raw_json` contains a valid textual
`status`. It never overwrites an existing projection and a malformed or
status-absent payload is a safe no-op; the repair is idempotent.

`includeStatus=true` changes the nature of an incremental fetch: in it the server
returns all 1:1 rooms so that it can refresh presence. A compact refresh is
therefore not free and that price is knowingly accepted in exchange for presence.

The badge colors are defined per theme separately and every state has its own
glyph, so that the state does not depend on color alone. A text alternative is
mandatory, because a colored dot on its own is invisible to a screen reader.

### D-030: Atomizing hand-maintained files

State: Accepted by the user on 26 August 2026.

A hand-maintained source or test file should stay under 1000 lines. A larger unit
is split by responsibilities into smaller files with a narrow public interface;
merely moving lines without reducing responsibility is not a completion.
Generated files are exempt from the limit, but must not be edited by hand.

The initial audit recorded 24 hand-maintained files over the limit. A fresh audit
on `83078cd` found none; the largest hand-maintained files have 977 lines. Above
the limit remain only the generated `app_database.g.dart` and the localization
`lib/l10n/generated/app_localizations*.dart`. The limit stays a continuous gate
so that further changes do not undo the atomization.

### D-031: Offline admission of a text message from a persistent snapshot

State: Accepted on 26 August 2026, commits `47ec902` and `83078cd`.

Only `sendText` may, on a transient failure to load capabilities, use a
persistent account-scoped snapshot. The snapshot must have the lane `ready`, its
fingerprint must match the canonical `talkFeaturesJson` of the account exactly
and the profile must still allow a text send. A missing, corrupted or mismatched
snapshot, a 401, a cancellation and an invalid response all stay fail-closed.

The offline branch only admits a durable operation in the `queued` state. It must
neither claim it nor issue a POST, because without network evidence the transport
would create a false ambiguous state. The in-memory capability cache is not
online evidence: the API returns the provenance `network` or `memoryCache` and
the send admission forces a fresh request. A failed fresh read removes the
superseded hot cache and only then may the persistent fallback be used. A fresh
foreground sync reloads the authoritative capabilities; only with a still valid
generation/replay authority does it send the operation exactly once. Commit
`924f44c` wakes the room binding through a coalesced connectivity/lifecycle
signal, cancels an active poll without closing the binding and forces a fresh
capability read again before a claim. A false signal claims nothing. The Android
E2E confirmed, without a restart, the transition from `queued`, attempt 0, to
`completed`, attempt 1, with a single server-side as well as cached message. The
decision still introduces no background scheduler and does not close the live
process-death/offline matrix.

### D-032: A desktop credential vault per the native platform

State: Accepted on 26 August 2026, macOS slice `9695c9f`.

The desktop must not replace platform secure storage with plaintext in Drift or
in a file. macOS uses the non-synchronized login Keychain with the accessibility
`AfterFirstUnlockThisDeviceOnly`; for a sandboxed ad-hoc runner it does not use
the Data Protection Keychain, because that rejects a round trip without a
matching access-group entitlement. A native test verified adding, reading and
deleting a real generic password item and removed it afterwards.

This decision proves neither a signed-in macOS E2E nor Linux. Linux has to get a
separate verified Secret Service/keyring backend; when it is unavailable, the
credential must not be silently stored less securely.

### D-033: Redacted security and migration gates

State: Accepted on 26 August 2026, commits `5f91e37`, `f184f9d` and `73ce1fc`.

The continuous secret/log gate scans tracked source files and, on request, also
explicit build or runtime-log artifacts. A finding discloses only the path, the
line number and a stable rule ID; never the match, the surrounding line or the
value found. A clean run returns 0, a finding 1 and an input or Git error 2.
Synthetic test values must not make the gate fail over itself.

The supported release database inputs are the Git-backed schemas v7 to v13. Each
is opened from a separate file-backed snapshot, migrated to the current v14, and
the preservation of the account/conversation data, presence, archiving, the new
tables, `user_version` and foreign-key integrity is verified. A newer schema
continues to be rejected fail-closed without changing the version or the data. A
future release schema has to be added to the same matrix at the same time as
`schemaVersion` is raised.

### D-037: The selected conversation is the single source of truth for both window widths

State: Accepted on 27 August 2026, commits `052a006` and `1b8687d`.

The open conversation is held exclusively by the selection in the shell. A narrow
window renders it in place of the list, a wide window in the right pane.
Switching between them is therefore purely a question of layout and works in both
directions without special logic. The system back button and the back button in
the header cancel the selection, they do not close the application.

The previous attempt handed the conversation to the navigator as a pushed screen.
Narrowing the window worked, widening it did not: the application stayed in
single-column mode even in a maximized window. The cause was not a missing pop,
but that two sources of truth arose — the selection in the shell and the
navigator stack — and copying went only in one direction.

It could not be fixed from the inside. The navigator does not build routes under
the first opaque route, so neither the workspace nor the shell is built and
neither of them learns about a window resize; measured by an instrumented test
that counted zero shells built and one route. Any reaction to a resize written
under a pushed screen is therefore dead code.

In this model a deep link has to first remove everything above the root screen
and only then set the selection. A link can arrive while the user is anywhere,
and merely setting the selection would leave them looking at whatever is on top.

A note on traceability: the shell part of this change is carried by commit
`052a006` with a header about adding a widget key, because it arose accidentally
by staging a whole file containing someone else's work in progress. By content it
belongs to `1b8687d`.

### D-034: Desktop density from the input device, not from the window width

State: Accepted on 27 August 2026, commits `7cde8ca`, `520c88e`, `289a6ee` and
`539a776`.

The dimensions of the controls are derived from `defaultTargetPlatform`. Windows,
macOS and Linux get the density for a mouse and a keyboard, the other platforms
stay unchanged at the touch minimum of 48 dp. The boundary is the platform,
because a narrowed window on the desktop is still operated with a mouse and a
widened tablet with a finger — the window width says nothing about the input
device.

Measured by a widget test at 1400×900 and `devicePixelRatio` 1: before the fix, a
standard interactive element was 48 px against 34 px in Nextcloud, a conversation
row 80 px against 53 px and a pane header 76 px against 44 px. After the fix, on
the desktop `IconButton` is 36, `FilledButton` 38, `TextField` 40, a conversation
row 56, an avatar 40, the header 52 and the list width 300, which is
`$navigation-width` from `nextcloud/server`.

The cause is NOT `ThemeData.visualDensity`. Flutter computes it by platform on its
own (`theme_data.dart:412`), so the compact density already applies on the
desktop — but it only takes 8 px off widgets based on `minimumSize` and on
`contentPadding`, and reaches neither the corner radii nor the typography. The
real causes were two: the theme imposed the touch minimum on all platforms, and
dimensions hardcoded in the widgets, which the density does not affect.

Two findings that did not follow from the design and came only from the
measurement. `IconButton` does not react to `minimumSize`, because it is governed
by the padding around the icon and in Material 3 pins itself to
`VisualDensity.standard`; the real knobs are `padding` and `tapTargetSize`. And
`minimumSize` has to be given eight larger than the intended result, because the
desktop compact density subtracts eight points.

The guard test `desktop_density_test.dart` holds the mobile minimum of 48 dp as
well as the lower bound of 24 px, so that the density cannot be reduced
indefinitely.

### D-035: An interrupted database migration recovers, it is not performed atomically

State: Accepted on 27 August 2026, commits `04528c3`, `0b3c201` and `5c7cd96`.

Every `onUpgrade` step has to be idempotent so that it can be safely repeated.
The migration is deliberately not wrapped into a single transaction.

The reason is a state documented on the dedicated Windows VM: `user_version`
stayed at 7, but the schema was already past step 10, so every further start
replayed steps the schema already had and ended with
`duplicate column name: is_archived`. The application did not open, the retry
button merely repeated the same migration and there was no way out from the UI.

Atomicity would never have healed that state, it would only have prevented new
ones. On top of that it would not have been enough by itself: drift writes
`user_version` only after `onUpgrade` finishes, so a crash in that window
produces the same divergent state and the bookkeeping would have to be worked
around by hand.

Only a single step had to be made idempotent. Drift generates
`migrator.createTable` as `CREATE TABLE IF NOT EXISTS`, the indexes have
`IF NOT EXISTS` by hand and the backfills recompute from `raw_json`. The only
non-idempotent one was `migrator.addColumn`, which now goes through a
`PRAGMA table_info` check.

The database also stopped being created in the user's Documents folder. It was
not a problem of a single platform: `drift_flutter` has the default directory
`getApplicationDocumentsDirectory()` everywhere, so on Windows it was a folder
synchronized by OneDrive, on Linux `~/Documents`, on macOS without a sandbox the
same, and on iOS a sandbox visible in Files and backed up to iCloud; only Android
pointed into an app-private directory. The move relocates `-wal` and `-shm` too,
because the main file alone would discard transactions in the write-ahead log,
and it never overwrites an existing file at the destination.

### D-036: Chat providers are released when the room is closed

State: Accepted on 27 August 2026, commit `142d5c6`.

The family providers holding messages, send states, outbox operations and the
scope are `autoDispose`. Without that, every room ever opened permanently held a
live drift subscription and the last complete list of messages, and closing the
room released nothing.

Measured on the production widget path: 2.9 kB of resident memory per cached
message, that is roughly 58 MB for a room with twenty thousand messages. A pass
through twelve rooms of two thousand messages each grew by 57.9 MB before the fix
and by 16.3 MB after it, which is 72% less.

Two related changes were considered and rejected, both with measurements. A
window over the message query has nothing to fix, because a room with twenty
thousand cached messages opens in 231 ms and after `autoDispose` only one is held
open; on top of that it would silently break the jump to a message, because the
blocks describe what has been downloaded, not what the query emits. Evicting
cached messages has nothing to cut, because of the 1199 B per row, 714 B is the
message itself — it would delete user history, not overhead.

### D-038: Our own push proxy is the default transport on both Android and Apple

State: Accepted on 27 August 2026, delivery proven live on 28 August 2026.
Supersedes the Android part of D-025.

Both the Android and the Apple platforms register push-v2 against our own proxy
`nks-talk-notify`, which holds the sending branch to FCM v1 and to APNs. The
project therefore DOES have a publisher Firebase project and its own gateway; the
older claims to the contrary in D-025 and the surrounding paragraphs hold only
for the fallback Web Push branch. Web Push over UnifiedPush stays undeleted and
switchable at runtime.

Nextcloud selects the target devices by the `apptype` column, which it derives
exclusively from the User-Agent of the registration request, and sends a Talk
notification to `talk` devices — it falls back to the others only when the
account has no `talk` device. During registration the client therefore identifies
itself as a Talk client (`f52a587`); without that, an account that also uses the
official Talk app receives not a single notification in this application. The
detailed measurement is in `TODO-notifications-calls.md`.

The proxy does not decrypt the content of a notification. It is opened only by
the client RSA key, so the account is determined by the key that decrypted the
payload, not by the host or the active account.

TWO CONSEQUENCES CLOSED ON 3 SEPTEMBER 2026 BY THE OWNER, both as decisions, not
as deferrals. (1) The embedded FCM distributor will NOT be forked. Its weaker
guarantee — an ACK to GMS before handing over to the application — now concerns
only the fallback Web Push branch, and a lost wake-up is caught up by the
authoritative OCS catch-up anyway; forking an LGPL-2.1 library would pay for that
with permanent maintenance. (2) An AGPL Web Push backport for Nextcloud 33 will
NOT be built. On older lines the default path runs through the proxy on the
classic push-v2 `/devices`, which is verified live on Nextcloud 32 as well; a
backport would improve only the fallback branch on one server line, and an addon
must never be a mandatory installation anyway.

### D-039: Typing state is a transient room session with per-composer sources

State: Accepted on 30 August 2026, commit `9499288`.

The indicator turns on only with an authenticated `signaling-v3`, the feature
`typing-privacy`, a public `config.chat.typing-privacy=0` and the external HPB
transport. A missing or private policy is fail-closed: the client neither accepts
nor sends typing state. The decision matches `talk-android@5428960` and
`talk-ios@2d31eda`.

Incoming state is account/room/peer-scoped and disappears after 15 seconds
without a refresh. An outgoing start is refreshed after 10 seconds of continuous
typing and a stop is sent after five seconds of inactivity. It is not durable
data and does not belong in the Drift database. The provider holds only the
non-secret signaling authority needed to restore the lane.

The root and a thread of the same room share one signaling session, but not a
single activity boolean. Every composer has an identity source and the controller
aggregates their set; a stop is sent only after the last source is deactivated.
That keeps an adjacent unfocused root from stopping an active thread in a desktop
split view.

A live web → iOS round trip on the reference instance proved both the start and
the stop without sending a message. The pixel-measured banner had 4.72:1 in light
and 11.15:1 in dark mode.

An addition of 1 September 2026, commits `a9e08f4`, `ea19395`, `3c89513`,
`2760623` and `5c2df5d`: before connecting to the HPB, the typing provider
activates the room through `participants/active` and accepts only a response with
the same room token and a non-zero session ID. The Talk session cookie is in
memory only, under the key of the specific `accountId` and the exact server.
Activation and deactivation have a serialized generation lease, so a late cleanup
of an older provider must not delete a newer session. Removing an account closes
the admission, the server session and the HPB lane before the credentials are
revoked; a late active/settings/call response then must not capture a cookie,
return a success or restore DB state. An API close invalidates the generation,
cancels the response stream in a bounded way and waits for the cleanup tail. A
401, an invalid response, dispose and deactivation all have a bounded cleanup.
The cookie path, domain, expiry, `Max-Age`, an empty value and ordering are
evaluated without sharing between accounts. A live web → Android pass showed the
start within 2 seconds and the stop within 5 seconds.

### D-040: The other party's absence is a transient account-scoped DAV view

State: Accepted on 31 August 2026, commit `16101db`.

The current absence is loaded only for an open 1:1 conversation and only behind
`dav.absence-supported = true`. The user ID comes from the account-bound room and
the GET uses the origin, the login and the credential of the same account. An
account mismatch, a group, an empty user ID or a missing capability must trigger
no request at all.

An absence is neither a chat message nor durable synchronization state. It is not
stored in the Drift database and is loaded from the authoritative DAV endpoint
after a conversation is opened or changed. The owner of the request is the
banner; on a scope change or dispose it cancels both the capability and the
follow-up GET, so that an old result cannot jump into a different room.

The server text stays whole for a screen reader, but the visual lines are
limited. That keeps a valid bounded payload from making the chat inaccessible at
an enlarged font size.

### D-041: A calendar reminder belongs to the exact call location

State: Accepted on 31 August 2026, commit `be6cfe5`.

An upcoming event is not searched for by the name of the room or by the
participants. The key is the exact absolute location
`{accountOrigin}/call/{roomToken}`, which upstream Talk Android uses too. The
endpoint is called only behind `upcoming-reminders` and with the same account
origin, login and credential as the open room.

A reminder is a transient server view, neither a chat message nor a durable
cache. The first usable event is displayed and dismissing it applies to the
currently open pane. On a scope change the request is cancelled and the
generation-bound widget discards the old data even before the new response
completes.

The location in the response must exactly equal the request filter. That keeps
even a valid OCS payload from jumping between two rooms of the same account or
between accounts with an identical token.

### D-042: A shared contact is a vCard file attachment

State: Accepted on 31 August 2026, commits `9d6b0fe` and `f743c45`.

Upstream Android exports a contact into `.vcf` and sends it through the standard
attachment flow. The client therefore adds neither a new rich object kind nor a
special download transport. Reception stays in the account-authenticated DAV file
pipeline.

A strong vCard MIME is authoritative. A generic binary MIME may use the contact
UI only when the last segment of the validated `DavRelativePath` ends with
`.vcf`. The display name is not a trust boundary and may neither supply nor
overwrite the extension.

Sending a contact from the platform address book is a separate feature with its
own permission and privacy boundaries. Receiving a vCard neither pretends to be
it nor requires access to the device contacts.

Android and iOS use a foreground system picker that returns exactly one contact
without a blanket permission. The native boundary removes PHOTO, rejects several
cards or a missing FN and enforces a 2 MiB limit. The app-owned vCard continues
unchanged through the existing file attachment admission, so it inherits the
account/room/thread binding, the durable source and the authoritative server
confirmation.

### D-043: The server accent is account-scoped capability state

State: Accepted on 31 August 2026, commit `75127b9`.

The authenticated capability snapshot accepts only an opaque `#RRGGBB`. The color
is stored in a separate table bound by a foreign key to the `accountId`; it is
shared neither with the Talk feature fingerprint nor with another server. A
missing or invalid value removes the old accent and uses the default seed.

The theme is regenerated when the selected account changes. The Material color
scheme stays responsible for the light/dark contrast, which is guarded by a
computation of at least 4.5:1.

### D-044: A live location map requires an explicit consent

State: Accepted on 31 August 2026, commits `4b0e659` and `b3c751e`.

Displaying a message must not by itself send the coordinates to a third party.
The default preview is a local diagram with a marker. OSM tiles are loaded only
after a separate accessible tap; the link supplied by the server is not a trusted
network target.

The loader has a fixed HTTPS origin, redirects forbidden, a limit of four
requests of 256 KiB, a concurrency of two and a timeout. The bytes stay only in a
widget-local `Image.memory`; an account switch or dispose closes the client and
the generation guard discards a late result. No global cross-account image cache
arises.

### D-045: Polls are online-only server mutations

State: Accepted on 31 August 2026, commits `d714f70` and `5f48ca7`.

Poll create, show and vote use the exact upstream Talk v1 contract and the
feature `talk-polls`. Create requires the write permission; show and vote stay
available to a valid participant of a read-only conversation per the upstream
controller attributes. A thread poll additionally requires a canonical, undeleted
root.

Neither create nor vote has an idempotency key, so they are not enqueued into the
durable outbox and are not retried automatically after an ambiguous result. A
received `talk-poll` rich object carries only a validated poll ID; the current
state and the voting are always loaded from the server with an account/room-bound
GET. The canonical server message is an ordinary `comment` with an empty
`systemMessage`, the text `{object}` and an exactly matching
`messageParameters.object`. The viewer therefore binds the parameter to the
placeholder, not to the historically assumed `object_shared`; detached metadata
stays inert.

### D-046: The secure store has its own account-scoped migrations

State: Accepted on 31 August 2026.

The version of the credential vault is not derived from the Drift `schemaVersion`
and no secure store write runs inside `onUpgrade`. Every account has a durable
marker directly in the same platform secure store as its app password. That makes
it possible to open, repair or safely reject the database independently of the
availability of the Keychain or the Keystore.

The v1 to v2 migration is copy-verify-commit-cleanup. The unversioned key is
first copied into a versioned account-scoped key, the copy is verified by reading
it back, and only then is the marker `2` written. The legacy key is deleted only
after the marker is verified. An interruption therefore leaves at least one
complete copy and the next access completes the same step idempotently.

Two different values, an unreadable marker or a version newer than the client
stop the access without overwriting or deleting the secret. Concurrent first
requests of the same account share a single migration future; other accounts stay
independent.

### D-047: The minimum supported line is Talk 22 (Nextcloud 32)

State: Accepted on 3 September 2026.

The client rests on three hard gates: `conversation-v4` (Talk 12), `chat-v2`
(Talk 3.2) and `threads` (Talk 22). The youngest of them sets the minimum, so the
supported line starts at Talk 22, that is Nextcloud 32. Everything else the
client uses exists from a line older than 22 — `chat-replies` 8,
`chat-reference-id` 9, `delete-messages` 11.1, `clear-history` 12.1, `reactions`,
`unified-search`, `silent-send` and `message-expiration` 15, `avatar` 17,
`media-caption` and `note-to-self` 18, `edit-messages` and `federation-v1` 19,
`ban-v1` 20, `archived-conversations-v2` 20.1, `important-conversations` and
`sensitive-conversations` 21.1 — and is therefore always available on Talk 22+.
The only younger capability is `conversation-tags` (Talk 24); it gates only the
tags and may be missing.

Source: `docs/capabilities.md` in `nextcloud/spreed` (branch `main`, read on
3 September 2026), where every capability is recorded under the line in which it
appeared. A server with an older line reports `conversationProfileUnsupported`
(no `conversation-v4`) or lacks `threads`; the application reports both as an
unsupported server, not as a network error. Verifying by measurement on an older
line is not possible without a second server; the decision therefore follows the
upstream documentation, not a run.

Measured on 3 September 2026 on the second server `talk2.example.invalid` (Nextcloud
32.0.14, Talk 22.0.17): line 22 does not send the fields `tagIds`,
`lastPinnedId`, `hiddenPinnedId`, `hasScheduledMessages` or `attributes` in
`v4/room`, and until then the parser required them, so it rejected the whole
conversation list. Since `275c039`/the `talk22` fixture these fields are optional
with an empty/zero default; when they do arrive, they are validated as strictly
as before. The same applies to Login Flow v2 on a server with pretty URLs
(without `index.php`), which the official Docker image uses.
