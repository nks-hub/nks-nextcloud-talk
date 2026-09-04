# Synchronization and local data

## Database choice

The required atomic relations are relational. The authoritative local store is
therefore SQLite with foreign keys, transactions and versioned migrations. The
Flutter application uses Drift; the current schema v10 holds accounts,
conversations, avatars, chat scopes, messages, text-send operations, drafts and
durable attachment jobs. Opening the database enables and checks foreign keys. A
newer `user_version` is rejected fail-closed before any migration, so an
application rollback does not stamp its older version onto an unknown schema.

Hive may stay only for simple non-authoritative preferences. It is not suitable
as the main Talk store, because a message, a parent, a thread, a room and a read
marker have to change within one transaction.

## Identity

### The server origin

Before storing:

- only a supported scheme;
- a lowercase host;
- a normalized port;
- the trailing slash removed;
- any Nextcloud subpath preserved;
- no credentials in the URL.

The redirect and discovery result is stored separately from the value entered by
the user.

### accountId

A local random UUID created after a successful login. It is not derived from the
userId alone, because the same user may have several app-password installations
and several servers.

Every primary or unique key of synchronization data starts with the accountId.

## The logical model

<!-- markdownlint-disable MD013 -->

| Entity | Key | Purpose |
| --- | --- | --- |
| Account | accountId | The server, the login identity, the credential reference and the lifecycle |
| CapabilitySnapshot | accountId + scope + revision | Raw and normalized feature/config values |
| Conversation | accountId + roomToken | Room metadata, permissions, counters and the last message |
| Participant | accountId + roomToken + actor key | The participant, the role, the session and federation data |
| Message | accountId + roomToken + messageId or localId | The author, the text, the state, parentMessageId, parentRoomToken and thread bindings |
| MessageParameter | accountId + roomToken + message key + placeholder | A Rich Object String parameter without losses |
| ReactionSummary | accountId + roomToken + message key + reaction | The count, the self flag and optionally separately loaded actors |
| Thread | accountId + roomToken + threadId | The original message, the title, counts and the subscription |
| ChatBlock | accountId + roomToken + thread scope + start/end | A contiguous confirmed interval of history |
| ReadMarker | accountId + roomToken | lastRead, lastCommonRead and the explicit unread state |
| OutboxOperation | accountId + operationId | A persistent local mutation, the correlation and the outcome certainty |
| UploadJob | accountId + uploadId | The local media, WebDAV and Talk share phases |
| PushRegistration | accountId + channel | The connector instance, the current subscription generation, the activation and revocation state |
| PushEndpoint | accountId + channel + generation | A reference to the Android Web Push subscription secrets or the iOS APNs/PushKit token |
| NotificationRoute | accountId + platform tag/id | The server nid, roomToken, messageId and threadId |
| RevocationTombstone | revocationId | Minimal secure cleanup data after a local account removal |
| CallSession | accountId + call id | Only the necessary persistent recovery state, not media objects |

<!-- markdownlint-enable MD013 -->

Raw server JSON may be kept only as a diagnostic or forward-compatible part of
the model with a clear migration. Domain logic must not read a dynamic map every
time.

## The bootstrap state of an account

After the first durable commit an Account starts as `capabilitiesPending`. The
credentials are already stored safely, but the room sync, the push registration
and the feature UI must not start yet. A successful signed-in capability snapshot
switches it to `ready`.

A network or 5xx error leaves `capabilitiesPending` and allows a safe retry. HTTP
401 switches the account into `reauthRequired`; anonymous capabilities must never
switch it to `ready`. The state is durable and a further sync must not perform a
new network request until the user explicitly completes the re-auth. A new Login
Flow is bound to the original `accountId`, the canonical server origin, the base
path and the login. A different identity must not overwrite the credential or the
cache; a newly issued foreign app password is revoked on a best-effort basis. A
successful match replaces the secure credential, preserves the account-scoped
cache, clears the sync error and restarts the live sync.

## Message identity

A server message has a messageId. A local pending message has a localId and a
referenceId. Upstream allows several server messages with the same referenceId.
The value is therefore a correlation, not a server-side idempotency key.

The rules:

- the referenceId is a UUID and does not change;
- the localId is unique only locally, but always under an accountId;
- a server response or a relay may connect a messageId with exactly one waiting
  local operation through the referenceId;
- two different server messageIds with the same referenceId must not be silently
  merged;
- if the server does not return the referenceId in an old variant, a cautious
  combination of the response binding and the server id is used, never text +
  timestamp;
- update and delete target the server messageId;
- a temporary message is not deleted before the server identity is inserted
  atomically.

A cross-room reply always keeps `replyTo`, `replyToToken` and a normalized
`parentRoomToken`. After a restart, both the outbox and an UploadJob must
reconstruct the same request, not derive the parent room from the currently open
conversation.

A named-thread text send is a separate branch: it stores `threadId`, but no
`replyTo`, `replyToToken` or `parentRoomToken`. A plain text send has neither a
reply nor a thread binding. The confirmation and restart recovery must preserve
this distinction, because the same server ID must not turn a reply into a named
thread or vice versa.

A new Giphy send does not use the text outbox. The selected URL is used only by
the account-scoped resolver to download valid GIF bytes. Before the admission,
the bytes are copied into a durable app-owned source and the attachment job
stores the handle, the SHA-256, the MIME type `image/gif`, a stable
`giphy-<sha16>.gif`, the account, the room and any thread. What follows is
identical to an image attachment: the Draft, the WebDAV upload, the finalize and
the authoritative chat confirmation. The URL is not stored in the server-side text
history.

Older messages may still contain the original hidden wire URL. Their renderer
resolves it account-scoped and hides it, but this compatibility read path must
not be reused for a new send.

## Chat blocks

A ChatBlock represents an interval the client knows to be contiguous.

Operations:

- an initial page creates the first confirmed interval;
- a backward page extends or joins an adjacent interval;
- lookIntoFuture extends the upper boundary;
- a delete does not automatically mean a gap, provided the server supplied a
  delete event;
- an invalid/missing pagination anchor or an expired context marks a gap;
- a numeric discontinuity of message ids is not a gap in itself, because ids need
  not be contiguous within one room;
- thread history has its own scope, so that it does not mix with the main room
  stream.

The highest messageId alone is not sufficient proof that nothing is missing
between messages.

A chat GET must additionally not derive the boundary of the interval only from
the visible messages. `X-Chat-Last-Given` is the authoritative anchor even for a
`200 []`, if the server processed an invisible or expired message. A history
`304` ends the older history, a future `304` confirms convergence. A change of
`X-Chat-Last-Common-Read` alone moves no message cursor.

Every HTTP request carries the anchor it started from. Before the commit, the
merge compares it with the current `historyCursor` or `futureCursor`; a late
future result with an old anchor is rejected entirely. The exact executable model
is in the [chat message contract](chat-messages-api.md).

## The merge transaction

Every input is first normalized into a SyncEvent:

- accountId;
- roomToken;
- source;
- event kind;
- server ids/referenceId;
- payload;
- receivedAt;
- any anchor/header context.

Within one DB transaction:

1. Verify the account and the room scope.
2. Deduplicate the event.
3. Upsert or tombstone the message.
4. Merge the message parameters and reactions.
5. Fix the parent and the thread original.
6. Update the thread summary.
7. Update the room last message and the counters.
8. Apply the read marker rules.
9. Extend or mark the chat blocks.
10. Confirm the corresponding outbox operation.

The UI notification is published only after the commit.

## The outbox

### States

<!-- markdownlint-disable MD013 -->

| State | Meaning | Allowed next state |
| --- | --- | --- |
| queued | Safely stored, not yet claimed | sending, cancelled |
| sending | One account lane is performing the operation | awaitingConfirmation, retryable, failed |
| awaitingConfirmation | The response is ambiguous; waiting for a catch-up/relay | completed, retryable, failed |
| retryable | A transient error and a computed nextAttemptAt | sending, cancelled |
| failed | The automatic retry ended or the server rejected the operation | queued after a manual retry, cancelled |
| completed | The server state is atomically confirmed | terminal and then retention/cleanup |
| cancelled | The user cancelled the operation, where the phase allows it | terminal |

<!-- markdownlint-enable MD013 -->

The retry policy is data, not a Timer in the UI:

- the operationKind and the payload schema version;
- the replayContractRevision bound to the capabilities and the verified upstream
  contract;
- attemptCount;
- nextAttemptAt;
- errorClass;
- the last redacted status;
- the server Retry-After;
- a dependency on another operation.

After a process crash, an operation found in `sending` is moved to
`awaitingConfirmation`, not to `queued`. The client does not know whether the
server accepted the request. Only an operation with proof that the request never
left the client is sent again automatically.

A permanent error is not deleted. The user has to see what was not sent.

### The replay contract gate

The durable outbox accepts only an operationKind from a versioned registry. The
local operationId serves for scheduling and deduplication in the worker; it does
not make the server request idempotent. The same holds for the referenceId.

Every replay contract must be bound to the required capabilities, a verified
upstream SHA or a contract fixture, and must define:

- the canonical server target and the required resulting state;
- proof that the request never left the client and can be safely sent;
- the authoritative query or event for reconciliation after an ambiguous result;
- unambiguous proof of completed, of a permanent failure and of any compensation;
- the handling of 401, 403, 404, 409, 429, 5xx, a timeout and a lost response;
- the manual user action including a warning about duplication or overwriting
  state;
- the version and the redaction rules of the stored payload.

The first admission matrix is verified against Talk master
`f2958bb25be6604240c58a3faf9a2033a30d20e5` and stable v24.0.4
`f9b9e9474e3621b47f74bf8890c4642cb49eed97`. The implementations under review are
identical between these SHAs. A newly supported line nevertheless requires a new
contract fixture.

<!-- markdownlint-disable MD013 -->

| operationKind | Identity and authoritative reconciliation | Policy after an ambiguous result |
| --- | --- | --- |
| textSend | roomToken + referenceId; the chat catch-up/relay and the specific messageId | `awaitingConfirmation`; no blind POST, a manual resend warns about duplication |
| messageEdit | roomToken + messageId + the target text; the message context/chat refresh | Confirm the visible target text, otherwise wait; a replay can duplicate the system message |
| messageDelete | roomToken + messageId; the verified deleted verb/tombstone | Reconcile before a retry; 404/405 do not by themselves prove the outcome and concurrency is not safe |
| reactionAdd / reactionRemove | roomToken + messageId + actor + emoji; GET reaction/message | Serially convergent, concurrency unproven; reconcile first, otherwise wait |
| read | roomToken + an explicit lastReadMessage; refetch the room/read marker | Retry-safe only with a stored explicit messageId, never with "the currently last one" |
| markUnread | roomToken + an explicitly derived target marker; refetch the room/read marker | The DELETE recomputes the previous message, so a blind replay is forbidden |
| favorite / archive / notificationLevel | roomToken + an absolute value; refetch the conversation | A retry-safe setter; archive additionally requires `archived-conversations-v2` |
| reminderSet / reminderDelete | user + roomToken + messageId; GET reminder | A retry-safe update-or-insert/delete; after a unique race the authoritative GET decides |
| scheduledCreate | the content + sendAt without a client/server id; the schedule list | `awaitingConfirmation`; a replay would create a second row |
| scheduledEdit | scheduledMessageId + absolute values; the schedule list | Retry-safe only while the item exists and has not been sent yet |
| scheduledDelete | scheduledMessageId; the schedule list | Retry-safe only before sendAt; afterwards its absence does not distinguish a delete from a send |
| draftFolderProbe | user + room + folder; the WebDAV PROPFIND | A retry-safe get-or-create; the rename proposal is re-verified after every run |
| uploadBytes | a random temp URI + the checksum/session; the WebDAV remote state | A resume from a verified offset only before the finalize; afterwards the PUT would create a new draft |
| attachmentFinalize | the draft file + the room + the referenceId; the chat scan and the WebDAV draft/final state | `awaitingConfirmation`; the move can succeed before the chat message fails |
| classicShare | the WebDAV node + the OCS share + a chat scan | Automatic replay forbidden until a separate Nextcloud core audit proves the contract |
| unknown | none | Reject at the command boundary; neither queue nor fake-replay it |

<!-- markdownlint-enable MD013 -->

The detailed source evidence is in the
[protocol matrix](../research/protocol-parity.md#verified-replay-semantics). Next
to the kind, the contract registry must also store the revision; a change of a
capability or of the supported server line must not silently replay an old queued
operation under the new semantics.

### Ordering

- Operations within one room are performed deterministically by dependencies and
  time.
- An edit/delete of a pending message depends on the confirmation of its send.
- An attachment share depends on a successful WebDAV upload.
- Different rooms may be processed concurrently with a per-server limit.
- The scheduler has to be fair between accounts; one unavailable server must not
  block the others.

## The text send failure matrix

<!-- markdownlint-disable MD013 -->

| Situation | Action |
| --- | --- |
| Offline, a DNS or connect error before sending | retryable with the same referenceId |
| A timeout/reset after the body may have been sent | awaitingConfirmation and an authoritative catch-up/relay; no blind POST |
| HTTP 400 `error=message` | awaitingConfirmation; the same code can also arise after the comment was saved |
| HTTP 400/403 `error=reply-to`, 404 `error=actor`, 413 `error=message` | failed; these are documented pre-save rejection branches |
| HTTP 429 `error=mentions` | retryable per Retry-After or a local bounded backoff; the branch is before the save |
| HTTP 5xx | awaitingConfirmation, unless contract evidence proves the request was not committed |
| HTTP/OCS 401 | durably switch the account into `reauthRequired`, stop further requests and preserve the state of the operation; restore the lane only after an explicit Login Flow with a matching accountId, origin, base path and login |
| Another OCS business error | awaitingConfirmation until a pre-save branch is documented |
| The relay arrives before the HTTP response | the pending operation is correlated through the referenceId; the HTTP confirms the specific messageId |

<!-- markdownlint-enable MD013 -->

If the catch-up finds the message, the operation is completed without another
POST. If it does not find it, that absence alone still does not prove the server
did not accept the request. The operation stays `awaitingConfirmation`. The user
may choose an explicit resend with a warning that Talk does not enforce a unique
referenceId and the server may create a duplicate, but only while no server-side
match is known.

The first executable registry item is only `textSend` revision
`talk-chat-text-send-f2958bb-f9b9e947-r2`. The admission, the claim, an error
before the body, an ambiguous transport, a restart, the authoritative
zero/one/several matches, a relay before the HTTP response, a transactional
rollback, re-auth, per-room FIFO/single-flight and account isolation all have
executable fixtures. R2 adds a named-thread `threadId` and requires a current
local `threads` capability for it; an r1 operation is not replayed under r2
authority. Flutter schema v5 introduced the nullable `threadId`; the current
schema v7 preserves it. A file-backed reopen preserves both a queued and a
sending operation, and restart recovery converts an interrupted `sending` into
`awaitingConfirmation`. The chat message/scope/outbox confirmation are committed
in a single Drift transaction. The other operation kinds in the table remain a
design and must not be queued until they get their own equally strong contract.

## The read marker

An ordinary read moves lastRead forward. An explicit mark-unread is a different
command and returns the marker to the previous message id; if there is no
previous message, Talk uses `ChatManager::UNREAD_FIRST_MESSAGE`, that is the
sentinel -2.

Therefore:

- a generic merge must not mechanically use max for an explicit unread event;
- a local pending marker has the operation kind read or markUnread;
- the server lastCommonRead is not derived from the local lastRead;
- the outgoing `read` projection is allowed only for one's own completed
  operation with a real cached server confirmation and
  `messageId <= lastCommonRead` within the same account/room/thread scope;
- an unconfirmed or ambiguous send stays `sending` and the local model does not
  create an undocumented `delivered` state;
- the notification clear is performed only after a server-confirmed or safely
  derived read state.

## The attachment job

### Phases

1. selected or recorded;
2. localPrepared;
3. draftResolved;
4. uploading;
5. uploaded;
6. sharing;
7. completed;
8. retryable or failed;
9. cancelled and cleanup.

An UploadJob keeps:

- the accountId and the roomToken;
- the local app-owned sandbox path or a content URI with a verified persistable
  grant;
- the MIME type, the size, the checksum and a safe display name;
- the Draft folder and the remote path;
- the upload session/chunk state;
- the referenceId;
- the caption, replyTo, replyToToken, parentRoomToken and thread metadata;
- the server file/share identity;
- the cleanup state.

If the upload succeeds and the share fails, the job must not upload the same file
again. If the user cancels a chunk upload, the client cleans up the temporary
server session according to the supported WebDAV flow.

A voice message uses the same job with messageType=voice-message. The recorder
lifecycle and the temporary file are a platform resource, not a special chat
transport.

The transition into `localPrepared` is allowed only after a durable app-owned
copy or after successfully obtaining a persistable URI permission. Before a
resume after a restart, the client reopens the source and verifies both the size
and the checksum. The picker temp path or a temporary grant must not be the only
source of a pending upload.

The Flutter HTTP transport is wired into the account-scoped
`AttachmentRepository`, `AttachmentService` and the Drift jobs. A chunk uses an
efficient bounded seek, not a new read from byte zero; a cancel/timeout/close
closes even a lease obtained late, and the cleanup continues with the other
actions within one bounded budget. A restart resumes the uploads in progress and
an ambiguous finalize stays visible for reconciliation. Since commit `8724281`,
an image attachment with a valid preview opens in the internal authenticated
viewer in the success, loading and error states; the external fallback stays only
for non-images or a missing preview. The automation does not prove a current live
Nextcloud upload or a tap of the viewer on a device.

## Multi-account concurrency

- Every account has its own sync lane and cancellation scope.
- A global scheduler limits concurrent HTTP/upload operations.
- A DB transaction always filters by accountId, even when a seemingly global
  messageId is known.
- The Android Web Push callback is routed through the connector instance chosen
  by the application, bound to the `accountId` and the current subscription
  generation. An unknown or replaced instance/generation is rejected; the payload
  only wakes an account-scoped OCS catch-up.
- A future iOS relay callback has no trustworthy `deviceIdentifier`. The account
  router first verifies the signature against a limited set of user public keys
  and then tries to decrypt with the corresponding per-account device keys using
  the default OAEP and the documented legacy PKCS#1 v1.5 padding. Exactly one
  valid candidate determines the `accountId`; the route hint is only a
  preselection and errors must not form an oracle or sensitive logs.
- A deep link carries the accountId.
- Logout first stops the lane, so that no late write arrives after the partition
  is deleted.

A NotificationRoute is always keyed by accountId. The same server `nid` or
platform notification id on two servers must not collide. `delete-all` deletes
only the system notifications of the selected accountId.

## Account removal and revocation

Removing an account must not silently delete a queued, retryable,
awaitingConfirmation or failed outbox entry, or an upload in progress. The UI
offers:

1. postpone the removal and complete the operations;
2. export a diagnostic list without secrets and explicitly discard the
   operations;
3. cancel the removal.

The online flow first stops the lane, removes the per-account Web Push or APNs
registration from Nextcloud and any iOS relay mapping, revokes the app password
and only then removes the secret and the account partition.

For an offline removal, the UI may hide the account only after the local
operations are explicitly discarded. A separate RevocationTombstone in secure
storage holds only the credential reference and the signed data needed for the
cleanup. It has a fixed retention period, a visible state and a retry. After it
expires, the secret is removed and the user gets a specific instruction to revoke
the app password on the server manually; a failure must not be presented as a
completed revocation.

## Migrations

Every DB version contains:

- a forward migration;
- validation of the foreign keys and the unique indexes;
- a restart-safe procedure for large tables;
- a test of the upgrade from every supported release version;
- a diagnostic export without message content;
- an application rollback must not open a newer schema and silently corrupt the
  data.

Local diagnostics do not derive the migration state from a compile-time
constant. They read `PRAGMA user_version` read-only, compare it with the expected
version of the build and show whether the schema is current, older or newer.
`foreign_key_check` is reduced to a count of violations; table names, rows and
user content never reach the diagnostics.

The secret-store migration is separate from the DB migration. The old secret is
removed only after a verified write of the new one and an update of the
credential reference.

## Mandatory tests

- two messages created in the same millisecond;
- a lost HTTP response and a subsequent relay;
- a lost response without a relay stays awaitingConfirmation and performs no
  blind resend;
- two server messages with the same referenceId stay two messages;
- a relay before the HTTP response;
- two concurrent catch-up calls;
- a gap between two chat blocks;
- a message edit/delete/reaction while a thread is open;
- mark-unread after a newly read message;
- a restart in every outbox and upload phase;
- a restart/reboot opens the durable sandbox copy or the persistable URI grant;
- two accounts with the same server userId;
- the same roomToken on two servers;
- a logout during a long poll and an upload;
- an offline account removal with pending/failed data and a revocation tombstone;
- a push for an inactive account;
- a push for the same server/user in two accountIds with different device keys;
- a push decrypt with the default OAEP as well as the legacy PKCS#1 v1.5 padding
  and without an oracle;
- a colliding platform notification id and `delete-all` across two accounts;
- a DB upgrade with a pending outbox;
- an empty array versus an object in the known upstream JSON variants.
