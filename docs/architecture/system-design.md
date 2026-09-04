# System design

## Evaluated variants

### Variant A: a single Flutter project

All API clients, models, storage and the UI live in one application project.

The advantage is the fastest start. The disadvantage is a strong risk that OCS,
WebDAV, signaling and the platform lifecycle grow into the UI. Pure Dart contract
tests and later CLI diagnostics would depend on the Flutter runtime.

### Variant B: a modular client and a platform push boundary

The Flutter app uses a small pure Dart package for the wire protocol. Storage and
sync stay inside the application in clear modules. Android uses Notifications Web
Push directly; an iOS APNs relay is created separately, only in its own slice.

This is the recommended variant. It separates the real trust and runtime
boundaries without creating a package for every class.

### Variant C: many Dart packages and federated plugins from the start

Every feature, signaling, storage and platform capability has its own package.
That makes isolation easier, but before a second implementation exists it creates
a large configuration and release overhead. For the first implementation it is
premature.

## Recommended topology

~~~mermaid
flowchart LR
    UI[Flutter features] --> APP[Application controllers]
    APP --> SYNC[Account-scoped sync engine]
    APP --> STORE[Relational local store]
    SYNC --> STORE
    SYNC --> PROTO[Pure Dart Talk protocol]
    PROTO --> NC[Nextcloud OCS and WebDAV]
    PROTO --> HPB[Internal or HPB signaling]
    WEBPUSH[Android Web Push ingress] --> ROUTER[Account-scoped push router]
    ROUTER --> SYNC
    NC --> ENDPOINT[Per-account Web Push endpoint]
    ENDPOINT --> WEBPUSH
    NC -. future iOS .-> RELAY[Publisher APNs relay]
    RELAY -. APNs and PushKit .-> IOS[iOS platform ingress]
    IOS --> ROUTER
    APP --> PLATFORM[Android, Apple and desktop modules]
    PLATFORM --> MEDIA[Future WebRTC media engine]
~~~

## Repository boundaries

Once the design is approved:

~~~text
apps/
  mobile/                 The Flutter application and the platform targets
packages/
  talk_protocol/          Pure Dart OCS, Talk, WebDAV and wire models
docs/
  research/
  architecture/
  adr/
~~~

Another package is created only when it has its own release/test boundary or two
real implementations. Call signaling may start as a module inside the
application; it is separated only when both the internal and the HPB transport
are really implemented. A future iOS relay gets its own service or repository
boundary only after the APNs contract is verified; Android does not need it.

## Responsibilities

### talk_protocol

- canonicalization of the server origin and safe URL composition;
- OCS request headers, the envelope and error mapping;
- Login Flow v2 wire models;
- the capability resolver;
- the rooms, chat, threads, reactions, polls and call APIs;
- WebDAV path encoding, the upload session and the Files share payload;
- Rich Object String transport models;
- internal and HPB signaling wire messages, only in the call preparation phase.

The package must not import Flutter, the UI, secure storage or a specific
database.

### Account runtime

Every accountId owns:

- the canonical server origin and the user identity;
- a reference to the app password in secure storage;
- the capability snapshot;
- the HTTP session and the cancel scope;
- the long-poll or websocket lifecycle;
- the sync lane;
- push registration and key references;
- the local data partition.

The active UI account is only presentation. Background push and sync must not use
a global activeAccount as an authorization source.

### Sync engine

The sole owner of turning server and local events into database state. A UI
controller must not manually rewrite the message, thread or room tables.

Inputs:

- the initial/catch-up HTTP page;
- the chat long poll;
- the HPB chat relay;
- a push wake-up;
- an outbox response;
- an explicit refresh;
- a change of credentials or capabilities.

The output is atomically committed local state that the UI only observes.

### Flutter features

The feature modules compose the application use cases and the UI:

- onboarding/accounts;
- conversations;
- chat/threads;
- composer/media/voice/Giphy;
- search/shared items;
- notifications/settings;
- calls, after the signaling slice.

The compact phone and the expanded tablet/desktop shell use the same use cases
and route models. The layout must not create a second desktop repository or a
different account scope.

Transport DTOs are not exposed to widgets. The UI receives a domain read model
with explicit loading, stale, pending and failed states.

### Platform layer

Android:

- the UnifiedPush connector and the embedded FCM distributor as the Web Push
  entry point;
- notification actions and channels;
- secure key storage;
- a foreground service for future calls;
- audio focus, Bluetooth, PiP and screen capture, only in the call slice.

iOS:

- the Keychain and the App Group;
- the Notification Service Extension;
- the APNs token lifecycle and the future publisher relay;
- the PushKit token lifecycle, only in the call slice;
- later PushKit, CallKit and the ReplayKit Broadcast Extension.

Desktop:

- safe credential storage according to the OS;
- resize, focus, hover, keyboard shortcuts and the file picker/drop;
- the system tray, auto-start and background delivery, only in a separate slice;
- no use of the Android embedded distributor.

A platform module implements no Talk business rules. It passes typed events into
the account router or the call coordinator.

### Push delivery

Android:

- the authenticated capability `webpush` is the only feature authority;
- the server provides the VAPID public key;
- the connector and the embedded distributor create a per-account subscription;
- the client completes the register, activation token, activate and unregister
  lifecycle;
- Notifications sends the standard and the delete payload directly to the Web
  Push endpoint;
- the payload only wakes an account-scoped OCS catch-up.

The Android build has no publisher Firebase project, no `google-services.json`
and no project gateway. The Nextcloud administrator installs no bridge. Nextcloud
33 may only get a complete standalone AGPL Web Push backport, not a simplified
Talk listener.

iOS:

- the APNs token is bound to the bundle ID, the Apple team and the entitlement;
- the provider credential stays only with the publisher;
- a single future publisher relay serves the supported servers without handing
  the Apple key to their administrators;
- PushKit VoIP uses a separate token and delivery lifecycle.

The detailed platform boundary and the test matrix are in the
[push analysis](../research/push-fcm.md). The historical push-v2 gateway contract
is not implemented as an Android service.

## Dependency rules

The allowed direction:

UI → application → sync/store/protocol → the platform or network boundary.

Forbidden directions:

- protocol → Flutter UI;
- a push callback → a foreign account partition;
- a widget → Dio/HTTP;
- a platform notification callback → activeAccount;
- a repository → a specific screen;
- a feature controller → a direct write into several synchronization tables.

## Runtime flows

### Adding an account

1. The user enters the server origin.
2. The client normalizes it, verifies the status and the anonymous onboarding
   capabilities.
3. The Login Flow returns the app password and the client verifies the credential
   server again.
4. A random accountId is created and the secret is written into the
   Keystore/Keychain.
5. A local transaction creates the Account and the credential reference in the
   capabilitiesPending state.
6. The signed-in capability request stores the account-scoped snapshot and
   switches the account to ready.
7. The initial room sync starts.
8. Push registration runs separately and its failure does not break chat.

A network error in step 6 leaves the secured account in capabilitiesPending and
the request can be retried without a new Login Flow. The exact wire and trust
contract is described by
[adding a Nextcloud account](client-bootstrap-api.md).

### App lock

The global Android/iOS preference is off by default and can only be turned on
after a successful system device authentication. When it is on, the root gate
does not build `_AppHome` at all before unlocking, so no account data is shown
and the push, deep-link and account coordinators do not start. A failure to read
the preference is fail-closed; a cancel or an authentication error stays on the
lock screen and the only unlock runs single-flight. `hidden` or `paused` locks an
unlocked session again, but the lifecycle of the system biometric dialog does not
trigger a recursive lock. The application neither reads nor stores biometric data
or the device credential.

### Opening a room

1. The UI reads the local room and the available chat blocks.
2. The sync engine picks an anchor and performs a catch-up.
3. The merge transaction fixes the messages, threads, room preview and read
   markers.
4. The long poll or the HPB relay continues from the confirmed anchor.
5. The UI shows a stale indication until the server catch-up is confirmed.

History and future have separate cursors. A response may be committed only when
its request anchor still matches the stored scope. The authoritative boundary is
set by `X-Chat-Last-Given`, not by the last visible message; a history `304` and
a future `304` have different meanings. The detailed wire and merge model is in
the [chat message contract](chat-messages-api.md).

### Sending text

1. A database transaction creates a temporary message and an OutboxOperation with
   a stable referenceId.
2. The account sync lane marks the operation as sending.
3. talk_protocol sends the chat POST.
4. The HTTP response or the relay correlates the pending operation through the
   referenceId.
5. One transaction replaces the temporary identity with the server message id and
   completes the outbox.
6. A lost response moves to awaitingConfirmation and triggers a catch-up.
7. Without a confirmation the POST is not repeated automatically; the Talk
   referenceId is not unique and a user resend can create a second server-side
   message.

Before step 1 the outbox admission verifies the capability and the exact revision
of the replay contract. The first allowed kind is only `textSend`. The relay can
complete an operation before the HTTP response; a later matching response is
idempotent. Zero matches in one catch-up window does not return the operation to
queued and several matches are not merged into one server identity. One room uses
FIFO and single-flight, other rooms may run concurrently. We can normalize the
cross-room private-reply wire payload, but a new command admission stays rejected
without a complete eligibility snapshot.

### An incoming push

1. The Android connector hands over the message together with the local
   subscription identity.
2. The router verifies the current account/subscription generation; the active UI
   account is not an authorization source.
3. An activation token may complete only a pending registration of the same
   account and generation.
4. A delete payload modifies only an account-scoped system notification.
5. An ordinary payload wakes the account sync lane and deduplicates the local
   display.
6. The OCS/chat API supplies the authoritative state.

The iOS callback will later use the same account-scoped output, but its own APNs
registration and relay wire. The historical RSA push-v2 decrypt runtime is not the
Android delivery path.

### Signing out

1. The account is first suspended in the account runtime gate. All of its root and
   thread chat bindings end the shared long polls; the attachment lane is
   durably stored as `suspended` before the requests are aborted. A bounded drain
   does not wait indefinitely for a faulty transport, but even afterwards the
   account gate rejects a late commit, a retry and a new enqueue. An in-flight
   upload stays restart-safe: recovery classifies it conservatively according to
   the stored request, but a suspended lane does not send it.
2. The client checks the queued, ambiguous and failed outbox and upload jobs.
   Without an explicit choice by the user it does not delete them.
3. Online, it removes the specific Web Push or APNs registration from Nextcloud.
4. iOS will later also remove the specific relay mapping; Android has no further
   project mapping.
5. It revokes the app password if the server supports it and the user is removing
   the account.
6. Only after the remote cleanup does it delete the secure secrets.
7. In a single local transaction it removes the account partition and the
   notification routing.

For an offline removal the user has to explicitly discard the unsent data. A
minimal RevocationTombstone keeps the credential reference and the signed cleanup
data in secure storage for a strictly limited time. After a success it is
deleted. After it expires, the secret is removed and the UI admits that a manual
revocation on the server is necessary; it must not report a false OK.

## The call-ready boundary

Preparing for calls means a real design, not empty implementations:

- CallCoordinator owns the state machine.
- InternalSignalingTransport and HpbSignalingTransport are two real variants.
- MediaEngine is added only with the WebRTC implementation.
- CallPlatformBridge separates the Android/iOS lifecycle.

The minimum states:

- idle;
- joining;
- ringing;
- connecting;
- connected;
- reconnecting;
- leaving;
- ended;
- failed.

The signaling contract tests have to verify hello, resume, room join/leave,
session loss, reconnect and the MCU/no-MCU differences before the camera is
wired in at all.

## Security boundaries

- The server origin is validated against HTTPS; an explicit dev exception must
  not exist in a release build.
- A redirect must not silently change the origin and carry the Authorization to a
  different host.
- WebDAV path segments are encoded separately; they are never composed by plain
  interpolation of a user-supplied file name.
- Both the OCS envelope and the HTTP status are validated.
- The app password and the private RSA key are not stored in the ordinary DB.
- The VAPID public key and the Web Push endpoint are bound to the authenticated
  capability and to a specific account subscription generation.
- The logging context may contain an accountId hash, an endpoint template, a
  request id and a status, but not a URL with the user, a token or a payload.
- Neither the Android build nor the server holds a publisher FCM service account.
- The future APNs provider key stays only in the relay secret store and never on
  a Nextcloud server or in the mobile application.
- Custom certificate trust is per server/account and requires the fingerprint to
  be shown; it must not be handled by disabling TLS globally.

## Observability

Local diagnostics:

- the anonymized account scope;
- the sync lane and the last confirmed anchor;
- the number of pending/failed outbox operations;
- the last capability refresh;
- the push registration state;
- the websocket resume/reconnect state;
- the upload phase without the local path and the file name.

Future iOS relay metrics:

- accepted/rejected APNs registrations;
- APNs latency and the status class;
- queue depth and retry age;
- the invalid token count;
- rate-limit rejects;
- no labels with a token, a user id or a room id.
