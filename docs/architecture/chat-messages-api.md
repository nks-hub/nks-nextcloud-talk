# Chat message contract

Update date: 25 August 2026.

State: the OpenAPI, the synthetic request/response fixtures, the capability
resolver, the transactional merge, the durable text-send outbox and the safe live
modes are all runnable. The Flutter client has a cache-first chat/thread UI and
an automated foreground HTTP-adapter/Drift/UI bridge, a persistent text-send
outbox and a named-thread send. A historical Android build has a verified build,
update install, login, opening a room and the Giphy wire-reference flow including
a return after the process was terminated. The new Giphy attachment flow replaces
that evidence and has no live server round trip yet. A real incoming thread smoke
test belongs to the previous APK and a bidirectional E2E to an even older one.
The named-thread send, root/history, read-unread and the restart/outbox matrix
have no current device E2E yet.

## Scope

The contract covers four existing Talk operations:

- `GET /ocs/v2.php/apps/spreed/api/v1/chat/{token}`;
- `POST /ocs/v2.php/apps/spreed/api/v1/chat/{token}`;
- `POST /ocs/v2.php/apps/spreed/api/v1/chat/{token}/read`;
- `DELETE /ocs/v2.php/apps/spreed/api/v1/chat/{token}/read`.

The OpenAPI 3.1 is in
[`contracts/chat-messages/openapi.json`](../../contracts/chat-messages/openapi.json).
The schema preserves unknown server fields, but requires the identities and
values needed for a safe merge.

## The server and client baseline

The server POST flow is verified on Talk master
[`f2958bb25be6604240c58a3faf9a2033a30d20e5`](https://github.com/nextcloud/spreed/blob/f2958bb25be6604240c58a3faf9a2033a30d20e5/lib/Controller/ChatController.php#L381-L463)
and stable v24.0.4
[`f9b9e9474e3621b47f74bf8890c4642cb49eed97`](https://github.com/nextcloud/spreed/blob/f9b9e9474e3621b47f74bf8890c4642cb49eed97/lib/Controller/ChatController.php#L376-L458).
The GET flow is verified on master
[`f2958bb`](https://github.com/nextcloud/spreed/blob/f2958bb25be6604240c58a3faf9a2033a30d20e5/lib/Controller/ChatController.php#L873-L964)
and stable
[`f9b9e94`](https://github.com/nextcloud/spreed/blob/f9b9e9474e3621b47f74bf8890c4642cb49eed97/lib/Controller/ChatController.php#L868-L959).
The read/unread flow is verified on master
[`f2958bb`](https://github.com/nextcloud/spreed/blob/f2958bb25be6604240c58a3faf9a2033a30d20e5/lib/Controller/ChatController.php#L1907-L2007)
and stable
[`f9b9e94`](https://github.com/nextcloud/spreed/blob/f9b9e9474e3621b47f74bf8890c4642cb49eed97/lib/Controller/ChatController.php#L1889-L1989).
Storing the `referenceId` is verified in
[`ChatManager`](https://github.com/nextcloud/spreed/blob/f2958bb25be6604240c58a3faf9a2033a30d20e5/lib/Chat/ChatManager.php#L383-L524).
Deriving the `threadId` is verified in `Message.php` at both
[`f2958bb`](https://github.com/nextcloud/spreed/blob/f2958bb25be6604240c58a3faf9a2033a30d20e5/lib/Model/Message.php#L197-L216)
and
[`f9b9e94`](https://github.com/nextcloud/spreed/blob/f9b9e9474e3621b47f74bf8890c4642cb49eed97/lib/Model/Message.php#L197-L216).

The client intervals, catch-up and optimistic-send behaviour are compared with
the iOS SHA
[`2d31eda5e2acbf3cef27aa289376942bdf0de25d`](https://github.com/nextcloud/talk-ios/blob/2d31eda5e2acbf3cef27aa289376942bdf0de25d/NextcloudTalk/Chat/NCChatController.swift#L92-L398)
and the Android SHA
[`5428960f9d1eca708df1b39a0831141dcbba4729`](https://github.com/nextcloud/talk-android/blob/5428960f9d1eca708df1b39a0831141dcbba4729/app/src/main/java/com/nextcloud/talk/chat/data/network/ChatMessageSyncer.kt#L39).
This is a clean-room specification of observed behaviour, not a translation of
upstream code.

## Capability profile

The resolver uses exact feature values, never the release number alone:

| Feature | Required conditions |
| --- | --- |
| Read | `chat-v2` |
| Text send | `chat-v2` + `chat-reference-id` |
| Reply | text send + `chat-replies` |
| Cross-room private reply wire | reply + `private-reply`; see the limitation below |
| Background catch-up | read + `chat-keep-notifications` |
| Thread fetch | read + `threads`, non-federated room only |
| Explicit read | read + `chat-read-marker` + `chat-read-last` |
| Mark unread | read + `chat-read-marker` + `chat-unread` |

In the analyzed SHAs, the federated server proxy flow carries neither `threadId`
nor `replyToToken`. The client therefore must not present these features as
supported based on the global feature list alone.

For a cross-room private reply, the capability resolver only determines the
possible server wire profile. Without an authoritative snapshot of the exact 1:1
room, the user actors, the membership, a replyable parent, a foreign author and,
on master, a non-classified source room, command eligibility cannot be decided
safely. Both the current request builder and the new outbox admission therefore
reject the cross-room command.

## The GET request

The request builder always sends `format=json`, `OCS-APIRequest: true` and a
stable `User-Agent` with the Android identity `com.nkshub.nextcloudtalk`.

History uses:

- `lookIntoFuture=0`;
- `timeout=0`;
- an explicit `lastKnownMessageId`, `lastCommonReadId` and a limit of 1 to 200;
- `includeLastKnown=1` only where the algorithm needs the anchor included.

Future uses `lookIntoFuture=1`, an immediate catch-up with `timeout=0` and, only
after convergence, a long poll with `timeout=30`.

An interactive fetch may update presence/notifications, but in this contract the
read marker is set exclusively by an explicit read operation. A background fetch
always sends:

- `setReadMarker=0`;
- `noStatusUpdate=1`;
- `markNotificationsAsRead=0`.

## The GET response

The HTTP and the OCS layers are evaluated separately. An HTTP 200 with an OCS
failure is not an empty success. Before the commit these are verified:

- the room token of every message;
- any `threadId` against the request scope;
- unique server `messageId` values within one response;
- a strictly descending order for history and an ascending order for future;
- the canonical response cursors;
- the direction of the cursor relative to the returned IDs and the request
  anchor.

`X-Chat-Last-Given` is authoritative even with a `200 []`, if the server
processed an invisible or expired message. The client has to move the interval up
to this header, not only to the highest visible ID.

`304` has two meanings:

- history: the older history is exhausted;
- future: the given anchor is convergent and one can move to a long poll or a
  relay.

A change of `X-Chat-Last-Common-Read` alone must not move the history/future
cursor.

## The foreground long-poll runtime

The pure Dart runtime has been implemented since 23 August 2026 in commit
`d90a66f5ed9bd79eb6585ccbff903e48d3da580f`. It forms the protocol and state
contract on which the Flutter foreground integration described below now builds.

A poll session is immutably bound to the `accountId`, the server origin,
`(roomToken, threadId|null)`, the credential generation and the capability
generation. At most one request may run for each scope. A completion is accepted
only for the exact pending request, an unchanged session, the current future
cursor and the same account generations. A stale completion must not be projected
into the cache.

The state flow keeps these invariants:

- the first foreground future catch-up uses `timeout=0` and the currently
  committed future cursor;
- after a valid response, including a `304`, the next request uses `timeout=30`
  and the reloaded committed future cursor of the same room/thread scope;
- `304` confirms the catch-up, but does not by itself move the cursor;
- `401` atomically switches both the account and the poll session into the
  re-auth state without a retry;
- an HTTP transient error and a transport failure preserve the catch-up or long
  poll mode and use an exponential backoff with a jitter of 0.8 to 1.2, a base
  ceiling of 30 seconds and an absolute ceiling of 36 seconds;
- a lifecycle cancellation switches the session into `stopped`, removes the
  pending request and creates neither an error nor a retry.

The observed behaviour is compared with the Talk Android SHA
[`5428960f9d1eca708df1b39a0831141dcbba4729`](https://github.com/nextcloud/talk-android/tree/5428960f9d1eca708df1b39a0831141dcbba4729):

- [`OfflineFirstChatRepository.kt` lines 285 to 324](https://github.com/nextcloud/talk-android/blob/5428960f9d1eca708df1b39a0831141dcbba4729/app/src/main/java/com/nextcloud/talk/chat/data/network/OfflineFirstChatRepository.kt#L285-L324)
  load the newest message for the room/thread, send the first request with
  `timeout=0` and the next with `timeout=30` from the newly loaded newest ID;
- [`OfflineFirstChatRepository.kt` lines 554 to 559](https://github.com/nextcloud/talk-android/blob/5428960f9d1eca708df1b39a0831141dcbba4729/app/src/main/java/com/nextcloud/talk/chat/data/network/OfflineFirstChatRepository.kt#L554-L559)
  stop scheduling further requests on pause and resume them on resume;
- [`ChatMessageSyncer.kt` lines 117 to 149](https://github.com/nextcloud/talk-android/blob/5428960f9d1eca708df1b39a0831141dcbba4729/app/src/main/java/com/nextcloud/talk/chat/data/network/ChatMessageSyncer.kt#L117-L149)
  compose future, timeout, last-known, thread, the limit and the zero read
  marker;
- [`ChatMessageSyncer.kt` lines 577 to 659](https://github.com/nextcloud/talk-android/blob/5428960f9d1eca708df1b39a0831141dcbba4729/app/src/main/java/com/nextcloud/talk/chat/data/network/ChatMessageSyncer.kt#L577-L659)
  distinguish `200`, `304`, `412` and an error. The Dart contract deliberately
  does not adopt the generic `runCatching` retry: a cancellation is a terminal
  lifecycle transition;
- [`NcApiCoroutines.kt` lines 497 to 502](https://github.com/nextcloud/talk-android/blob/5428960f9d1eca708df1b39a0831141dcbba4729/app/src/main/java/com/nextcloud/talk/api/NcApiCoroutines.kt#L497-L502)
  confirm the account credential in `Authorization` and a typed query map GET.

### The Flutter foreground bridge

`ChatRoomPane` creates an account/room/thread-bound live binding through
Riverpod. `ChatService` prepares the capability profile and the request, the
production `HttpNextcloudApi` performs the HTTP adapter flow and `ChatRepository`
commits the message, the future cursor, the convergence and a safe error state
into Drift. The UI publishes a change only when it observes the committed
database; the opposite root or thread scope does not change.

Two widget-integration tests execute the whole chain
`ChatRoomPane → ChatService → HTTP adapter → Drift → Riverpod → UI` separately
for the root and for a thread. In both cases they verify the timeouts
`0 → 30 → 0`, the cursor transition 109 → 120, displaying an external message,
the subsequent convergence after a `304`, an empty opposite scope and zero UI
exceptions. The HTTP adapter in the test uses a deterministic `MockClient`; the
test therefore proves neither a real socket nor a Nextcloud server.

A thread response may carry a complete embedded parent. The Flutter repository
uses it to update the cached thread original only when the account, the room
token, the message ID and the thread ID all match. The server `threadReplies` is
authoritative. If the field is missing, the client derives the count from the set
of unique message IDs in that thread scope and the replies currently being
received, leaves out the original and preserves a higher previously stored count.
A replay of the same reply ID is therefore not counted again, a batch is added
exactly once, and a mismatched embedded parent must not overwrite the cached
original. The whole merge happens within the same Drift transaction and a reply
still does not leak into the root scope.

The targeted suite `chat_service_integration_test.dart`,
`chat_scope_isolation_test.dart` and `chat_room_live_sync_test.dart` passed 22/22
on 24 August 2026. The thread repository slice alone passed 7/7 including an
explicit server count, a missing count, replay/batch derivation and a mismatched
parent. The separate UI suites cover the isolated thread pane, opening a valid
thread without replies, a safe inline link and the internal viewer of image
attachments. A fresh selection of seven chat/Giphy test files after commit
`8724281` passed 63/63 and `flutter analyze` ended with no findings.

### Generic References and OpenGraph

Commit `71fe53c` attaches generic links only behind the authenticated capability
`core.reference-api`. From one message it takes at most three distinct valid
HTTPS URLs and calls
`GET /ocs/v2.php/references/resolve?reference=...&format=json` with a limit of
1 MiB, 10 seconds and redirects forbidden. The response is accepted only under
the exact map key of the original link.

The cache is bound to the account, the login and the exact server origin, holds
at most 128 items for one hour, and concurrent identical resolves share a single
request. A known rich object is rendered typed, an unknown provider uses a
bounded `openGraphObject`. The server field `link` is not a navigation authority:
both the displayed host and the tap always use the original validated URL. An
error, an inaccessible reference or an invalid payload preserve the ordinary
inline link. The contract/protocol suite passed 969/969 and the affected
reference/content/Giphy suite 40/40. Android 14 release build 34 sent an ordinary
HTTPS link, rendered a generic OpenGraph card and after a force-stop resolved it
again in light/dark; the text and the icons had 6.646:1 / 6.371:1, the log was
clean and the test message was deleted. A recipient-side, iOS and desktop pass is
still missing.

### Historical Android Giphy wire-reference runtime

Commit `5f6e2f4` has a debug APK with SHA-256
`0d38d4ab2a665883d0ee0de7426f201c107cefc6b5f7e701b1c856255f6195cf` and a size of
203,683,536 B. The update install through `adb install -r` passed and the
installed `base.apk` had the same hash. On this APK a real Login Flow, the
conversation list, opening a room, selecting and sending a Giphy message and a
return after the process was terminated all took place. Two cold starts took
5094 ms and 4587 ms.

The implementation of the time sent the Giphy `resourceUrl` as an internal Talk
wire reference. Both the confirmed message bubble and the local pending bubble
rendered it as an animated inline GIF through the account-scoped References
resolver; the URL was neither displayed nor clickable. The reply preview and the
conversation preview used the text `GIF`. That held for the exact URL wire form
with `markdown=false` or with the `markdown` field missing too.

The targeted regression of the fix passed 11/11 and the broader chat/Giphy suite
75/75; the analyzer had no findings. Two different crop hashes of the same bubble
proved a change of the animation frame. After the process was terminated, the
same message was loaded and rendered again without a visible URL. Loading the
GIFs after a cold start took roughly eight seconds; a short
`Chat is temporarily unavailable` state disappeared after a retry. This scenario
did not repeat the whole root/thread/read-unread/outbox runtime.

This wire-reference flow is now replaced and remains only for reading history. A
new selection must not put the URL into a text message. The resolver supplies
validated `image/gif` bytes into a durable app-owned source and the standard Talk
Draft/WebDAV/finalize attachment flow. Commits `5d49cbb`, `9de5727` and
`7ca580e` wire this flow from the picker to the finalize. The composer
integration passed 4/4, loader/media composer 15/15 and the scoped analyze had no
findings. The historical live run above still does not prove the new
upload/finalize flow.

### Historical real thread smoke

The previous debug APK SHA-256
`<fingerprint>` was
update-installed through `adb install -r`; the cold start preserved the account.
An existing thread was opened from the root timeline through `Open thread`. One
new web thread reply appeared in the foreground Flutter in 2.3 s. The thread root
was rendered exactly once, a redundant parent preview not at all, the incoming
reply was not in the root timeline and the reply counter on the root updated
to 4.

The scenario historically proves the incoming Nextcloud transport, the foreground
poll, the Drift/UI update and both the root/thread scope and presentation
isolation. It does not prove the same behaviour on the new post-review APK, nor
the reverse direction from this Flutter composer into the web Talk.

Per `sha256sum`, the installed `base.apk` has the same SHA-256 as the local build
of the time. The light, dark and light-200-percent captures show the thread, the
date, the root, 4 replies and the composer without a layout defect. The explicit
pixel report passed 24/24 with a text minimum of 7.2725:1 and a UI minimum of
3.252078:1. The redacted process-scoped logcat has no warning, error, fatal or
known UI diagnostic. After the capture, the original values `night=yes`,
`font_scale` unset/null and the running application process were restored.

The runtime conversation list showed 9 tiles and 9 avatars: 3 network images, 4
fallback icons and 2 sets of initials. An incoming group message had a
participant avatar; an outgoing-only test thread correctly showed no avatars. The
avatar pixel report passed 4/4 with a minimum UI icon of 7.2725:1 and initials
text of 7.2739:1.

### Historical bidirectional baseline

The older APK SHA-256
`1c4372cad3bbf3f7b1d56664c5da9f353be24bb2b456a919b2393cd6879ba861` proved two web
replies in different polling cycles, their absence from the root timeline and a
reply from the Flutter thread composer delivered into the web Talk. This is a
historical transport baseline, not a repetition of the bidirectional scenario on
the previous runtime APK or the current build. The room token and the message
texts stay only in the ignored local artifacts. The temporary room was removed on
2026-08-24 through the persistent web E2E session and a follow-up snapshot
verified its absence.

On that older APK, the real light/dark screenshots of the thread passed the PIL
contrast check with a minimum of 5.03:1 for text and 3.25:1 for UI. At font scale
2.0 the messages wrapped, the header and the composer stayed visible and the
logcat had no layout error. The Flutter semantics test confirms exactly one named
editable composer node with `setText` and a tap action. The Android
AccessibilityBridge maps the label/hint into `AccessibilityNodeInfo.hintText`. A
direct Android runtime probe found exactly one editor, returned the expected hint
`Write a message` of length 15 and confirmed both `editable=true` and a click
action; the text and the `contentDescription` stayed empty per the bridge. The
runner passed 1/1. The uiautomator XML does not serialize `hintText`, so
`NAF=true` is a false positive. Audible TalkBack speech was not listened to.

## ChatBlock and the atomic merge

The scope key is `(accountId, roomToken, threadId|null)`. An interval means a
server-confirmed range, not a contiguous numeric series of visible message IDs.
Hidden messages and IDs from other rooms may create numeric gaps inside it
without a local data gap.

Every sync step:

1. verifies the account, the room/thread scope and the exact match of the request
   anchor with the stored directional cursor;
2. validates the HTTP, OCS, schema, headers and message semantics;
3. creates a candidate state;
4. upserts the server identities and joins overlapping intervals;
5. applies the common-read or the explicit read/unread room snapshot;
6. in the production runtime stores the cursor, the intervals, the messages, the
   marker and any outbox reconciliation within one DB transaction;
7. publishes the UI change only after the commit.

A validation error, a stale anchor or a simulated DB failure returns the whole
candidate state. The same room token, thread ID or message ID of another account
must not change. The Python harness now documents the rollback of the merge and
of the outbox confirmation separately. A shared SQLite transaction for both
subsystems will only be proven by the Dart runtime test.

## POST send and replies

Before the admission, the client creates a lowercase UUID `referenceId`. Talk
truncates it server-side to 64 characters, but before the save it does not look
up an existing comment by it. The value therefore correlates the local operation
and is not an idempotency key.

A confirmed response must have:

- HTTP 201 and a successful OCS envelope;
- a non-empty message;
- a matching target room token;
- an exactly matching `referenceId`;
- for a same-room reply, the exact immediate parent and a matching positive
  topmost `threadId` on both the parent and the new message;
- for a cross-room private reply, the original reply metadata, the local
  copied-parent ID as the `threadId` of the new message and `parent.threadId == 0`;
- for a named-thread send, a parentless message in the direct POST response with
  the matching requested `threadId`;
- for a plain send, a parentless message with `threadId == messageId`;
- a valid server `messageId`.

The `threadId` in a plain response is therefore not a copy of the nullable
request field. The server derives it as the ID of the new thread root. A
`201 null`, a different token or a different reference are ambiguous results. The
same rules apply to a lost response after the body may have been sent.

A same-room reply sends `replyTo`. The verified cross-room wire format also sends
`replyToToken`; normalizing an already stored payload additionally preserves
`parentRoomToken`. In the analyzed servers, the original message ID and the
conversation token are projected into the parent snapshot. A new cross-room
command admission is deliberately unsupported in this slice, and a federated
private reply is unsupported always.

A named-thread send is a different wire branch from an ordinary reply: it sends
`threadId`, but no `replyTo`, `replyToToken` or `parentRoomToken`. It requires
`chat-v2`, `chat-reference-id`, the local `threads` profile and a non-federated
room. The response must preserve the same `threadId` and must not add a parent.
Before the admission, Flutter distinguishes a cached named-thread root from a
reply root; an unknown classification is synchronized first. A confirmed message
is stored into the thread scope and, within the same Drift transaction, updates
the cached root `threadId`, `isThread` and `threadReplies`.

## Read and mark-unread

An explicit read is a POST with a specific `lastReadMessage`. Mark-unread is a
DELETE on the same path and the server derives the previous relevant message
again. The response returns a room snapshot from which `lastReadMessage`,
`lastCommonReadMessage` and `unreadMessages` are stored atomically.

Read is a monotonic use case; mark-unread deliberately is not. These operation
kinds must not be merged into one generic `max(lastRead)` rule or into blind
replays.

Commits `67026a0` and `df9d608` serialize both mutations only within the lane
`(accountId, roomToken)`. Read → unread as well as unread → read therefore
preserve their order within one room, while another room or account continues
concurrently. DB and other expected runtime exceptions are mapped onto
`RoomSettingsError.invalidResponse`, but a programmer `StateError` propagates;
the lane is released after both kinds of error. A fresh combined run of
`room_settings_read_marker_test.dart` and `chat_room_live_sync_test.dart` on
`df9d608` passed 21/21.

Commit `e4840e5` adds a truthful Flutter projection of the read state for one's
own outgoing messages. `ChatRepository` joins the outbox confirmation with the
exact `(accountId, roomToken, scopeKey)` and reactively reads `lastCommonRead`.
The `read` state arises only for a completed outbox operation with an actually
stored server message and `messageId <= lastCommonRead`. An unconfirmed or
ambiguous operation stays `sending`; `delivered` is not created at all without
server semantics.

Commit `02b79eb` simultaneously enforces a non-interactive background catch-up. A
profile with `backgroundCatchUp` sends `noStatusUpdate=1` and
`markNotificationsAsRead=0`; the foreground request stays interactive. A combined
run of `outgoing_message_status_test.dart` and `chat_room_live_sync_test.dart`
passed 11/11 and the scoped analyze of the five changed files had no findings.
This is automated HTTP/Drift/UI evidence, not a real server-side read transition
or a background lifecycle.

## The durable text-send outbox

The first allowed registry entry:

```text
operationKind: textSend
revision: talk-chat-text-send-f2958bb-f9b9e947-r2
requires: chat-v2, chat-reference-id
```

The admission rejects an unknown kind, a different revision or a missing
capability. The `operationId` is a local UUID of the worker and provides no
server-side idempotency. A named-thread operation additionally stores `threadId`
and requires `threads`; the previous revision r1 is rejected under r2 authority
instead of an unsafe replay.

<!-- markdownlint-disable MD013 -->

| Event | New state | Rule |
| --- | --- | --- |
| Durable admission | queued | The payload, the reply metadata and the revision are stored |
| Claim | sending | Only one account lane, the attempt is incremented |
| Error before the body | retryable | The same payload can be safely repeated after nextAttemptAt |
| The body may have been sent | awaitingConfirmation | No automatic POST |
| A restart in sending | awaitingConfirmation | The process does not know the server outcome |
| HTTP 400 `error=message` | awaitingConfirmation | The same code can also arise after the comment was saved |
| HTTP 429 `error=mentions` | retryable | The error arises before the save; Retry-After or a local bounded backoff is used |
| HTTP 5xx or another unclear OCS error | awaitingConfirmation | It does not prove that the save did not happen |
| One authoritative match | completed | The specific messageId is stored |
| Several referenceId matches | awaitingConfirmation | All IDs and the ambiguity are preserved |
| A deterministic rejection | failed | The operation stays visible |
| HTTP 401 | retryable + reauthRequired | Only that account is suspended |

<!-- markdownlint-enable MD013 -->

Zero matches in one catch-up window does not prove that nothing happened. A
manual resend is possible only after the risk of duplication is confirmed and
only while no server-side match is known. A relay that arrives before the HTTP
response completes the operation; a later matching HTTP response is idempotent.
Within one room the claim is FIFO and at most one send runs, while another room
may continue concurrently. A manual resend passes through the same lane, FIFO and
single-flight guard. An HTTP result may be applied only to an operation with a
matching room, reference and reply context. An empty successful future result (a
`200` with the cursor/common-read, or a `304`) leaves the operation in
`awaitingConfirmation`.

An ordinary same-room reply can also be confirmed authoritatively from
history/future through a compact deleted parent. It must have exactly
`parent.id == replyTo`, must carry neither `parentRoomToken` nor
`parentThreadId`, and the outer `threadId` must be positive. This exception
applies after an ambiguous POST as well as after a restart; it starts no new POST
and exactly one match completes the operation. A different parent, added parent
metadata or a zero outer thread stay without a match.

The named-thread direct POST response and an authoritative catch-up do not have
the same shape. With a matching outer `threadId == T`, the direct POST response
may be parentless. An authoritative history/future item without a parent is
rejected; it must carry exactly one of these forms:

- a full root parent with `id == T`, the room token of the operation and
  `threadId == T`;
- a compact unavailable parent in exactly the form `{id: T, deleted: true}`.

A different parent ID, a foreign room token or a different parent thread reject
the confirmation. For a quoted reply, `parent.id` stays the immediate quoted
message `P`, which may differ from the root `T`; both the outer and the
full-parent `threadId` must be `T`.

## An incoming shared location

Commit `c1aa49c` types the upstream `geo-location` parameter. `latitude` and
`longitude` may arrive as a JSON number or a decimal string, but both values must
be finite and lie within the inclusive ranges −90 to 90 and −180 to 180. The
client does not use the server field `link`; both the map HTTPS origin and the
path are fixed and the query/fragment are built only from validated double
values.

Flutter renders a valid location as a map icon and a name inside a single link
semantics node with a minimum target of 48 dp. At 200% text the name is limited
to two lines. An invalid `geo-location` does not turn into an active link and
stays a generic rich-object pill. A live server share was displayed on iOS 18.6
and opened the correct point in OpenStreetMap; the text `#394857` against the
pill `#D4E4F6` had 7.2492:1 in both the light and the dark theme, and the test
message was deleted after the evidence was collected.

Flutter schema v5 added a nullable `threadId` to `text_send_operations` and the
current schema v7 preserves it. A file-backed reopen test preserves both a queued
and a sending named-thread operation, and `recoverInterruptedTextSends` safely
converts an interrupted `sending` into `awaitingConfirmation` without losing the
thread binding. This is DB/repository evidence, not a finished live process-death
or background scheduler scenario.

## Diagnostics and security

- The Authorization, the app password, the room token, the message text, the
  referenceId and the raw payload are not logged.
- A schema error returns only a safe JSON path and the validator type.
- A dynamic `messageParameters` key is redacted in the path as `<member>`.
- A query/form mismatch prints only the names of the differing wire sections, not
  their values.
- The live origin is a strict HTTPS origin without credentials, a query and a
  fragment; both a subpath and a bracketed IPv6 host are preserved.
- Redirects are forbidden in the live validator and the response has a fixed byte
  limit.
- All live credentials and room tokens are read only from environment variables
  and are never printed.

## Runnable verification

Local fixtures:

```powershell
rtk proxy python contracts\chat-messages\validate_contract.py
rtk proxy python contracts\chat-messages\test_validate_contract.py
```

The read-only live smoke test performs exactly two GET requests with no
read/presence side effect:

```powershell
$env:NEXTCLOUD_TALK_TEST_ROOM_TOKEN = '<dedicated-read-room-token>'
rtk proxy python contracts\chat-messages\validate_contract.py `
  --live-origin https://nextcloud.example.com
```

The explicit mutable smoke test uses a different environment variable, sends one
synthetic message and a bounded catch-up has to find it:

```powershell
$env:NEXTCLOUD_TALK_WRITE_TEST_ROOM_TOKEN = '<dedicated-write-room-token>'
rtk proxy python contracts\chat-messages\validate_contract.py `
  --live-origin https://nextcloud.example.com `
  --live-write
```

In both cases the credentials live only in `NEXTCLOUD_TALK_USERNAME` and
`NEXTCLOUD_TALK_APP_PASSWORD`. The mutable command must not be run in a foreign
room.

The current contract result of 24 August 2026: 1 OpenAPI document, 47 fixtures,
of which 46 are schema-valid and 14 are accepted synthetic messages, 24 query
cases, 10 capability cases, 23 merge cases with 25 steps, 43 outbox cases with 83
steps, 17 unit tests, 1 redaction guard and 1 origin case all passed. The pure
Dart chat domain executes the same fixtures. The targeted named-thread/outbox
gate passed 158/158, the whole chat-only suite 194/194 and the separate
foreground polling file with 10 tests. The whole of `talk_protocol` passed
569/569 and `dart analyze` ended with no findings.

The clean Flutter commit `8374f20` contains 354 functional tests and one live
skip only without environment credentials; a later full run of the same
functional source on 25 August 2026 ended with no failures. The named-thread
service/integration tests and the file-backed schema v5→v7 reopen/migration are
part of this suite. Flutter analyze has no findings and the whole of
`talk_protocol` passed 569/569.

The historical `chatujmePixel` run proved the build/install/hash, login, opening
a room and the Giphy wire-reference flow described above including a return after
the process was terminated, but not the new GIF attachment upload/finalize, a
thread, read/unread or an outbox restart. The previous run proved the incoming
thread smoke test, the UI invariants, light/dark/200% WCAG 24/24 and avatar WCAG
4/4. The bidirectional thread E2E and the direct Android runtime `getHintText`
test are historical evidence of an even older APK. Audible TalkBack speech has
not been verified yet.

## What the evidence does not cover

The historical server evidence covers only one incoming thread future reply. The
historical Giphy APK did not repeat the whole thread scenario and the reverse
direction is documented only by an even older APK. It does not prove the new
Giphy attachment flow either. The named-thread request/response/outbox and the DB
reopen have automated evidence, but no real server or device round trip. The
evidence does not prove the root live flow, history pagination, read/unread, or a
queued and ambiguous outbox across a real process restart, an HPB relay, a
background scheduler or multi-server isolation. Not even the fresh read/unread
gate of 21/21 and the deleted-parent reconciliation tests are combined
live-server + process-death evidence. Audibly verified speech and broader
TalkBack navigation are missing. The temporary room was removed and its absence
verified; the other parts remain an open gate of slice 3.
