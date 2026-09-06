# Decisions and open choices

States:

- **Accepted**: the user decided, it is a necessary invariant, or it is a
  verified technical baseline for the implementation.
- **Recommended**: the analysis has a preferred variant, awaiting confirmation.
- **Open**: without a choice, the corresponding scaffold or feature must not be
  locked in.
- **Deferred**: not in the first release, but the architecture preserves the
  boundary.
- **Superseded**: the decision stays historically traceable, but a new slice no
  longer follows it.

## Accepted decisions

### D-001: A multi-server product

State: Accepted.

The client is not a white label for a single server. The reference instance
serves only for testing.

Consequence: no production URL, capability or account may be a global constant.

### D-002: Multi-account isolation

State: Accepted as a necessary consequence of the multi-server product.

Credentials, the cache, push identities, connections, the badge and deep links
are scoped by accountId.

Asynchronous UI actions capture the accountId of the object when it is opened and
use it for the whole request and the subsequent sync. A later change of the
globally selected account must not redirect the action; account-specific view
filters are reset on a switch.

At the verified Android upstream SHA `5428960`, the conversation-list filters
combine unread and mentions as an AND. The archived view is available only behind
`archived-conversations-v2`; without it, and without an active filter, archived
rooms stay hidden. The mention filter accepts an explicit `unreadMention` and
also every unread one-to-one or former-one-to-one room.

### D-003: Capability-first

State: Accepted as a protocol invariant.

The Talk release number is not a feature flag. The resolver combines the global,
features-local and room-scoped capabilities.

Every mutation must verify the signed-in account-scoped snapshot in the
responsible service or protocol layer, not merely hide a button in the UI.
Archiving, for example, must not issue a request without an unambiguous
`archived-conversations-v2` capability.

Room settings respect the exact upstream contract, not an invented common gate.
`message-expiration` is enabled only for a moderator with the capability of the
same name and uses non-negative seconds, where 0 turns it off; a value enforced
by the server stays authoritative. At the verified upstream SHA, `notify-calls`
has no capability of its own and uses only the absolute levels 0/1. Both
responses decode the authoritative room again instead of a local toggle with
optimistic state.

`important` and `sensitive` are not moderator room metadata but personal
participant-scoped settings. Each requires its own capability and an absolute
POST/DELETE without a body; federated rooms are supported. A classified room must
not turn `sensitive` off and the server error `classified` must not be turned
into a local success. Here too, the source of truth is the authoritative room
from the response.

At the verified upstream SHA `f2958bb`, conversation tags are also
participant-scoped, not moderator-only. Behind the capability
`conversation-tags`, the client loads the definitions, offers only custom tags
and on a change sends the complete resulting set of `tagIds`; neither a local
delta nor hidden predefined tags may overwrite the server state.

At the verified server SHA `f2958bb`, the SIP room setting uses
`PUT .../room/{token}/webinar/sip` and the absolute states 0 (off), 1 (personal
PIN) and 2 (no PIN). The UI requires `sip-support`, the authoritative room flag
`canEnableSIP` and a non-classified room; state 2 additionally requires
`sip-support-nopin`. HTTP 412 means a missing server-side SIP bridge, not a
success and not a generic network error. The room in the response is
authoritative and an empty success response is rejected, because the client would
not know the personal `attendeePin`. The room-specific `sipDialinInfo` is loaded
from the bounded signaling settings GET; neither the instructions nor the PIN are
persisted in the call snapshot, and diagnostic strings always redact them.

`clear-history` is a destructive moderator-only online operation without a client
idempotency key. After a fresh authenticated capability snapshot it uses a single
DELETE without a body and never enters the outbox or an automatic retry. Both
HTTP 200 and 202 mean the deletion was performed; 202 additionally requires a
warning that federation or an external bridge may hold copies. The local purge is
account/room-scoped and must not delete drafts, durable upload sources or a
pending outbox. A failure of the subsequent refresh must not prompt the user to
repeat a DELETE that already happened.

A thread request must separate the target message from the identity of the
canonical root. The notification-level request uses only the canonical `threadId`
as its target, even though the historical name of the route parameter on the
server is `messageId`. The response wrapper must carry `threadId` and a legacy
`messageId` is rejected fail-closed. The decoder rejects a room/root mismatch and
preserves the original request; the merge planner rejects an account/server
snapshot mismatch. An arbitrary root returned by the server is not accepted.

### D-004: No fake subsystems

State: Accepted per the project rules.

Call preparation means a working signaling state machine and contract tests, not
an inactive button or an interface returning OK.

### D-005: One public application identity

State: Accepted as a consequence of the public multi-server product.

One distributed build uses a stable applicationId/bundle ID for all supported
Nextcloud servers. Connecting another server must not change the binary, the
signing or the identity of the application.

Push delivery differs per platform. Per D-038, both Android and Apple register
against our own proxy `nks-talk-notify`, which holds both the FCM and the APNs
branch; per D-025, Web Push remained a switchable Android fallback and only that
one works without a publisher Firebase project and an own gateway. Firebase or
APNs credentials are never downloaded from an arbitrary connected Nextcloud.

### D-006: An outbox only with a verified replay contract

State: Accepted as a data and security invariant.

Neither a local operationId, a referenceId nor the HTTP method proves server-side
idempotency on its own. Every operationKind may be enqueued into the durable
outbox only after a capability/SHA-bound contract describing a safe retry before
sending, reconciliation of an ambiguous result, the terminal responses,
compensation and the user action. An unverified operation must not be presented
as offline supported.

### D-013: An original Talk-inspired implementation

State: Accepted by the user.

The client will not be a pixel-faithful copy or a translation of the GPL
Android/iOS source code. An original Flutter implementation will be created
according to the public protocols and our own specifications. It will preserve
Talk's familiar information architecture, but use its own components, a visual
variation, and add multi-server, offline and diagnostic states.

Upstream is used as an SHA-bound reference for behaviour, wire compatibility and
test scenarios. The license is settled in D-018; the original implementation
process stays as it is.

### D-014: Application identity

State: Accepted by the user.

The Android applicationId, the iOS and macOS bundle IDs and the Linux application
ID are `com.nkshub.nextcloudtalk`. Windows uses the same product name and
publisher namespace in the runner metadata. The identity does not change with the
connected Nextcloud server and is not downloaded at runtime.

A separately signed fork distribution may change the identity, but it is a
different binary with its own release/signing responsibility.

### D-015: A safe client bootstrap

State: Accepted as a trust and multi-account invariant.

The server entered by the user is first canonicalized and verified through the
public status. Both the Login Flow v2 URL and the credential `server` must
preserve the same origin and Nextcloud base path; in production the origin must
be HTTPS. Cross-origin, a base-path escape, userinfo, a query, a fragment,
encoded ambiguity and production HTTP are rejected before a URL is opened or a
token sent. An explicit debug HTTP policy has to be preserved through the
normalization, the Login Flow and the credential validation.

Anonymous capabilities are only onboarding data. After a one-time success the app
password is stored directly in the platform secure storage, a random local
`accountId` is created, and only the signed-in capability snapshot is stored as
the account-scoped authority. An HTTP 404 poll does not distinguish the pending,
invalid, expired and consumed states and must not be interpreted more precisely.

An authentication HTTP 401 is stored as a durable `reauthRequired` and stops
further account requests. Re-auth uses the Login Flow again, but the server is
locked to the original origin and base path and the result must have the same
login and `accountId`. A foreign credential must not be stored and is revoked on
a best-effort basis. Only a successful match replaces the secure credential,
preserves the account cache, clears the error and resumes the live sync.
Invalidating the capability cache after a 401 must simultaneously match the
credential fingerprint, the origin and the most specific base path; the same
Basic Auth on a different server must not lose its healthy snapshot.

### D-016: An account-scoped conversation merge

State: Accepted and implemented in the pure Dart parser, the merge planner and
the Flutter Drift transactional adapter. A complete multi-server and
process-death runtime matrix is still missing.

`conversation-v4` in the signed-in capability snapshot only selects a candidate
endpoint. The active profile `cursor-v4` is created only after a schema-valid
full response with a canonical cursor and a non-empty Talk hash. A legacy wire
profile without those headers stays unsupported until a separate adapter is
created. HTTP 401 means re-auth, while 426, 429, 503 and a valid OCS failure only
defer the confirmation of the profile; they do not by themselves prove an
incompatible wire format.

The request carries the `accountId`, a local request ID and the canonical server
origin. The decoded response preserves that same request and the planner derives
the whole context only from it. The stored account state carries the expected
origin and a different server is rejected before upserts or deletions are
computed.

The validated room model must pass `objectType`, `avatarVersion`,
`isCustomAvatar` and an optional `remoteServer` to the client; the federated
state is derived only from a non-empty `remoteServer`. Talk/PHP may serialize
empty `messageParameters` and `reactions` as `[]`. The parser normalizes that
single variant into an empty map, but rejects a non-empty array so that it does
not hide a schema drift.

The store key is `(accountId, roomToken)`. An incremental response never deletes
missing rooms; a valid non-empty full response may remove them. The first
full-empty response with an existing cache only establishes a confirmation state.
A deletion may only be confirmed by another full request within 300 seconds.
Older evidence expires and a non-empty intervening delta cancels it immediately.

The room upsert, any deletions, the server cursor and the Talk configuration hash
are committed in a single transaction. A schema, OCS, semantic or DB error does
not move the cursor. Schema diagnostics may contain only the structural path and
the validator type, never a value from the response. A change of the hash
requests an account-scoped capability/settings refresh, not a deletion of rooms.
The type of merge is decided by the explicit mode of the request, not by the
value of `modifiedSince` alone.

Once it has a cursor, the foreground loop uses the cheap incremental mode. A
manual refresh explicitly requests a full reconciliation, because a delta has no
removal tombstone and only a full response may remove a room the server no longer
returns. Per-account single-flight is mode-aware: a full intent behind a running
delta must, once the delta completes, start or join a new full request and must
not be considered satisfied by the delta. The full-empty protection keeps both
confirmation attempts in full mode and with different request IDs. Removing a
stale conversation cache must not delete a pending outbox or the same room token
of another account.

### D-017: An authoritative chat cursor and a safe text-send outbox

State: Accepted and implemented in the pure Dart planner/outbox and the Flutter
Drift repository. A live restart and the remote reconciliation matrix remain
unproven.

Chat history and future are two directions of the same account/room/thread scope.
`X-Chat-Last-Given` is the authoritative boundary even with an empty visible
body; a history `304` ends the older history and a future `304` confirms
convergence. A response may be committed only when the request anchor matches the
current cursor. Message identities, intervals, parent/thread, read values and the
outbox reconciliation change atomically, and schema diagnostics contain no
message values.

An authoritative edit or deletion of a message must not be stored only into the
separate parent row. Within the same Drift transaction it is projected into every
full parent copy in the cached replies of the same account and room, and possibly
into the conversation preview. Both a full and a compact deleted parent are
rendered in the UI as deleted, without the original author, content or an
interactive jump target.

Read and mark-unread mutations are serialized in order only within the lane
`(accountId, roomToken)`. The real order read → unread as well as unread → read
is therefore preserved within one room, while other rooms and accounts can
continue concurrently. Expected runtime and DB exceptions are mapped at the
service boundary onto `invalidResponse`, a programmer `StateError` is not hidden,
and the lane is always released after both kinds of error. None of these
mutations gets a blind replay.

The ordinary reply view and the named-thread network scope are separate
projections. A transition from the ordinary view into a named thread must not
migrate the ordinary cursor or move the new network scope. A root merge may be
projected only into the same account and room. These boundaries have automated
regression tests.

An open thread route, including entry from a search, derives the kind and the
title continuously from the canonical cached root; the snapshot from the moment
of navigation is not the authority for a further send. An asynchronously prepared
media request is immutable: the resolver binds it to the current root and the
durable repository re-verifies the exact binding within the same transaction just
before the insert. A change of ordinary ↔ named, a missing, deleted or invalid
root makes the admission fail closed; the repository does not silently rewrite
the metadata. The same authority applies to text: after the asynchronous
capability read, the cached root is decoded again and must be undeleted,
non-system and canonical. A named root additionally requires a non-empty bounded
title and a matching `threadId`; otherwise neither an outbox row nor an HTTP POST
is created. A valid ordinary ↔ named change, on the other hand, is used as the
current wire binding.

A full embedded parent from a thread response may restore the cached thread
original only when the room token, the parent/original ID and the thread ID all
match. An explicit server-side `threadReplies` is authoritative. When it is
missing, the Flutter repository derives the count from the unique reply IDs of
that account/room/thread scope, leaves out the original and the replay, and
preserves a higher stored count. A mismatched parent must not overwrite the
cached original.

`referenceId` is a correlation, not an idempotency key. The first allowed durable
registry kind is only `textSend` with the revision
`talk-chat-text-send-f2958bb-f9b9e947-r2`. Revision r2 adds an explicit
`threadId` for a named-thread send; an ordinary message has both
`replyTo == null` and `threadId == null`, a reply uses `replyTo` and a
named-thread message uses only `threadId`. The named-thread admission and replay
additionally require the local capability `threads`; an r1 operation must not be
automatically replayed under r2 authority.

The request and response semantics are not identical. A plain request has no
`threadId`, but a plain direct response is parentless and the server returns
`threadId == messageId`. A same-room reply returns the topmost thread ID from the
immediate parent. A cross-room private reply returns the local copied-parent ID
and `parent.threadId == 0`; a named-thread direct response stays parentless with
the requested thread ID.

A request demonstrably stopped before the body may be retryable. A possibly sent
body, an interrupted process, a `201 null` or an identity mismatch move to
`awaitingConfirmation` and must not be sent again automatically. A single
authoritative match of the same plain/reply/thread context completes the
operation, several matches stay ambiguous and zero matches does not prove that
nothing happened. A manual resend requires a warning about duplication and must
not continue once a server-side match is found. HTTP 400 `error=message` and 5xx
are ambiguous; only a documented pre-save 429 `error=mentions` is retryable per
`Retry-After` or a local backoff. Within one room FIFO and single-flight apply,
different rooms may continue concurrently. The cross-room private-reply wire
format is known, but the command admission stays rejected without a complete
eligibility snapshot. An unknown kind or revision makes the admission fail.

The pure Dart single-use plan provides a common candidate snapshot for the chat
merge and the outbox confirmation, and a complete rollback by discarding the
plan. The Flutter `ChatRepository` loads the snapshot, creates the plan and
stores the message/scope/outbox changes inside a single Drift transaction. A
fault-injection test confirms a complete rollback of both the message and the
outbox when the view projection fails. An ordinary reply stays visible from the
pending state through HTTP 201 and the Reply UI requires a resolved profile with
the capability `chat-replies`.

Schema v5 stores a nullable `threadId`; a file-backed reopen preserves both a
queued and a sending named-thread operation, and restart recovery converts
`sending` into `awaitingConfirmation`. A legacy schema migration preserves and
completes a queued named send. A confirmed named-thread message — whether a
parentless direct POST or an authoritative history/future shape with an exactly
bound full or compact deleted root — simultaneously restores the cached root
`threadId`, `isThread` and `threadReplies`. A live process death and remote
reconciliation are still missing.

### D-018: The license of the mobile client

State: Accepted by the user on 22 August 2026.

The mobile application and its own source code are licensed under
`GPL-3.0-or-later`. The full text is in the root `LICENSE` file. The choice
allows a GPL-compatible adoption from the official Talk clients, but no such
adoption may be hidden: it must have a traceable origin, preserved copyright
notices and a separate license audit.

The accepted original Talk-inspired direction from D-013 does not change. Every
asset and dependency must be GPL-compatible before distribution and recorded in
the continuous audit.

## Accepted technical decisions

Moved to [Technical decisions](decisions-technical.md): D-007 to D-010 and D-019
and up, so that this file stays under the limit from D-030. Product decisions and
open choices stay here.

## Settled choices

### Q-001: License

State: Settled in D-018.

The user chose `GPL-3.0-or-later`. The audit of the origin of the code, assets
and dependencies is a continuous distribution gate, not an open choice of
license.

### Q-002: Minimum platforms

State: Settled in D-026.

### Q-004: The offline scope of the first release

State: Settled on 2026-09-02 according to what the code already enforces.

The chosen scope: **a history cache + a durable text outbox + a durable
attachment runtime with recovery after a restart**. Everything else is online-only
and fail-closed.

The decision did not arise as a preference, but as a description of the state the
invariants in the code already hold:

- History is cache-first and paginates with gap detection in the chat blocks.
- Sending text has a durable outbox with retry, cancel and an ambiguous state; it
  is the only `operationKind` in the whole tree (`'textSend'`).
- Attachments do not go through that outbox, but through their own durable
  runtime (`AttachmentJob`) with recovery of unfinished uploads after an
  application restart. The "upload resume" from the original variant 2 is
  therefore done, only by a different route.
- The remaining mutations — editing, deleting, reactions, read/unread, favorite,
  archiving, the notification level, reminders, scheduled messages, the classic
  share — have no replay contract and must not be queued. Offering them as
  offline supported would mean promising a delivery nobody guarantees.

The practical consequence: without a network the application shows the history,
accepts both text and an attachment into the queue and completes them as soon as
the connection is back. The other actions will not be offered and an error is
shown right away instead of a silent deferral.

This is a product choice: if the product owner wants to move it (adding offline
reactions, say), it is a change of scope, not a fix — and it means a replay
contract for every additional `operationKind` first.

### Q-005: Giphy mode

State: Settled in D-028.

### Q-007: The Android gateway implementation stack

State: Settled as unnecessary in D-025.

The historical Go/Node comparison is not implemented for Android. A future iOS
relay will go through a new selection together with the APNs contract and has no
pre-chosen stack.

## Open choices

### Q-003: Release signing and Apple push

The application identity is settled in D-014. For development, iOS can be signed
for one's own device. Before public distribution, the Android release key
workflow, the Apple developer team, store provisioning and the APNs/PushKit relay
credentials are still missing. An Android publisher Firebase project is not
needed.

### Q-006: Supported server lines

The minimum Nextcloud/Talk line has to be determined. Multi-server does not
automatically mean support for every historical version.

## Deferred decisions

### D-011: Full call parity

State: Deferred behind chat and push parity.

The architecture preserves the signaling, coordinator, platform and media
boundaries. The specific WebRTC package will be chosen only after the
internal/HPB signaling prototype and the Android/iOS lifecycle spike.

### D-012: A Share Extension and App Intents

State: Partially accepted.

Android accepts `ACTION_SEND` through a persistent native inbox. The URI grant is
only a short-lived trust boundary: a bounded app-owned copy is created before
handing over to Flutter and a repeated cold/warm delivery is deduplicated.
Flutter selects the account and the room and uses the existing chat or attachment
durable flow; no new share transport is created. The iOS Share Extension is built
on the same shape (an App Group inbox, a bounded copy, cold/warm dedup, text and
file) and must not be pretended to be undone. App Intents on iOS stay deferred and
must not be pretended to be done.
