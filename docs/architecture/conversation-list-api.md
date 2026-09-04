# Conversation list contract

Verification date: 31 August 2026.

State: the OpenAPI, the synthetic response fixtures, the capability and runtime
wire scenarios, the production pure Dart parser and merge planner, the privacy
guard and an authenticated read-only live smoke test are all runnably verified.
The Flutter application now contains an account-scoped Drift store, a conversation
sync service, a cache-first list, an avatar resolver and an account-aware
adaptive UI. After a real login, the current Android APK loaded a live
conversation list and opened a room detail.

## Scope

The contract describes `GET /ocs/v2.php/apps/spreed/api/v4/room` as the first
read-only part of the conversation slice. It verifies:

1. the candidate API v4 based on the account capability `conversation-v4` and its
   subsequent runtime confirmation through the cursor/hash wire profile;
2. a full and an incremental request without a background change of presence;
3. the OCS envelope, the room read model and the server response headers;
4. the account-scoped merge and the atomic storage of the cursor;
5. protecting the cache against a wrong empty full list;
6. a read-only live run without printing names, tokens or messages.

This is not a new server endpoint and not an adoption of an upstream model. The
OpenAPI captures the existing wire format and the Python validator separately
expresses the client invariants JSON Schema cannot describe.

The OpenAPI 3.1 is in
[`contracts/conversation-list/openapi.json`](../../contracts/conversation-list/openapi.json).
The accepted mapping of the contract into the pure Dart runtime is described by
the [Dart conversation runtime design](../plans/2026-08-22-dart-conversation-runtime-design.md).
The implementation is in
[`packages/talk_protocol/lib/src/conversations`](../../packages/talk_protocol/lib/src/conversations).

## The verified server contract

The server behaviour was compared on Talk master
[`f2958bb25be6604240c58a3faf9a2033a30d20e5`](https://github.com/nextcloud/spreed/blob/f2958bb25be6604240c58a3faf9a2033a30d20e5/lib/Controller/RoomController.php#L243)
and stable v24.0.4
[`f9b9e9474e3621b47f74bf8890c4642cb49eed97`](https://github.com/nextcloud/spreed/blob/f9b9e9474e3621b47f74bf8890c4642cb49eed97/lib/Controller/RoomController.php#L239).
The body of `getRooms()` is identical; only the line offsets differ.

The feature flag itself, however, existed before the cursor variant. Talk v15.0.8
at SHA
[`9c12a6414fc12d6bb81cea387efded16f0301fc5`](https://github.com/nextcloud/spreed/blob/9c12a6414fc12d6bb81cea387efded16f0301fc5/lib/Capabilities.php#L66)
advertises `conversation-v4`, but its
[`getRooms()`](https://github.com/nextcloud/spreed/blob/9c12a6414fc12d6bb81cea387efded16f0301fc5/lib/Controller/RoomController.php#L176-L238)
has no `modifiedSince` and returns the Talk hash without
`X-Nextcloud-Talk-Modified-Before`. The flag therefore only designates a
candidate and the cursor profile is confirmed from the first full response.

Talk v16.0.0 at SHA
[`a0ebfedbce625d43d0a05d72e96df3b0e5a3ef9e`](https://github.com/nextcloud/spreed/blob/a0ebfedbce625d43d0a05d72e96df3b0e5a3ef9e/lib/Controller/RoomController.php#L176-L247)
already has the cursor profile, but does not know `includeLastMessage` yet. It is
therefore an optimization hint, not a correctness condition: the client must
safely accept `lastMessage` even when it sent `includeLastMessage=false`.

Endpoint parameters:

- `noStatusUpdate`: `0` or `1`; a background fetch always sends `1`;
- `includeStatus`: boolean; since commit `85fdb44` the Flutter client sends
  `true`, because presence of 1:1 rooms has no other source of truth;
- `modifiedSince`: a non-negative timestamp; its absence means a full fetch;
- `includeLastMessage`: boolean; a compact refresh sends `false`;
- `format=json` and `OCS-APIRequest: true` force a JSON OCS response.

With `includeStatus=true` an incremental fetch returns all 1:1 rooms, so that it
can refresh presence. `includeLastMessage=false` saves loading the last messages,
shares and the thread preload; a full chat preview will have its own chat
contract.

A room object carries `status`, `statusClearAt`, `statusIcon` and
`statusMessage`. The merge handles them like this: an incremental response
without the `status` key preserves the previous value, a full response is
authoritative and overwrites it even with an empty one. `offline` and `invisible`
are not rendered as presence. One's own status is presented only until
`statusClearAt`. The detail of the decision is in D-029.

### Current absence in a private conversation

The DAV contract was verified on 31 August 2026 against Nextcloud `stable34` at
SHA `a32bcea9cb0e0dec3329d8d8b17be190cea1a767`. The client asks about absence
only for a 1:1 room of the same account with a non-empty `roomName`, which is the
server-side user ID of the other party. First, the specific account snapshot must
contain an exact `dav.absence-supported = true`; a missing or malformed
capability is fail-closed.

The GET goes to the account origin
`/ocs/v2.php/apps/dav/api/v1/outOfOffice/{userId}/now?format=json` with the same
login and credential. `404` means no current absence. A successful response must
have OCS `ok/200`, exactly the requested `userId`, non-negative timestamps in a
valid order and strings of at most 4096 Unicode code points. The body is limited
to 64 KiB. A change of the room or the account, or closing the screen, cancels
both the capability and the DAV request; a late result is not carried into a new
conversation.

`16101db` renders the period, the message and an optional replacement without a
durable cache. The visual title has at most two lines, the message three and the
replacement two; the whole bounded text stays inside a single leaf semantics
label. The exact 200% test with an almost maximal multiline payload has no
overflow. A live POST → GET → DELETE round trip on iOS 18.6 proved the banner in
both themes and the accessibility-large layout; the pixel pair
`#4F4061` / `#EDDCFF` has a contrast of 7.2739:1 in both light and dark. The
follow-up `GET /now` after the cleanup returned 404.

### An upcoming room event

Talk Android `5428960` builds the location filter as the exact absolute address
`{accountOrigin}/call/{roomToken}` and Nextcloud `stable34` at SHA
`a32bcea9cb0e0dec3329d8d8b17be190cea1a767` accepts it through
`GET /ocs/v2.php/apps/dav/api/v1/events/upcoming`. The client calls the endpoint
only behind the feature `upcoming-reminders`; a missing capability is
fail-closed.

The request uses the origin, the login and the credential of the account of the
open room. The location is built from the canonical `ServerBase` and the token of
the same account-scoped conversation snapshot. The response is limited to 64 KiB
and at most 100 events. The first displayable event must have a bounded `uri`,
`calendarUri`, an optional non-negative `start`, a bounded summary and a location
exactly matching the request. A different location rejects the whole response
instead of showing an event of a foreign room.

`be6cfe5` keeps the reminder only in the open pane. A change of the account or
the room cancels the request and the generation key synchronously removes the
previous `FutureBuilder` data; a late result of the old room is not rendered. The
banner shows at most two lines of the title and two lines of the time, keeps the
whole bounded text in a leaf semantics node, and dismissing it has its own 48dp
accessible element.

A live CalDAV create → DAV filter → iOS 18.6 render → dismiss round trip passed
in light, dark and accessibility-large mode; the exact 200% test covers a title
of almost 4096 characters without overflow. The pixel pair `#394857` / `#D4E4F6`
has a contrast of 7.2492:1 in both themes. All four temporary fixtures were
deleted and the follow-up endpoint returned an empty list.

The server captures the value of `X-Nextcloud-Talk-Modified-Before` as the first
operation of the method, that is before the event, the status update and loading
the rooms. Another request with that cursor therefore does not create a time gap.
The delta includes not only new activity, but also changes of the attendee state
and active calls.

## Response headers

A successful response contains:

- `X-Nextcloud-Talk-Modified-Before`: the cursor of the next delta request;
- `X-Nextcloud-Talk-Hash`: the configuration hash of the relevant server, Talk,
  signaling, federation, theming and user settings;
- optionally `X-Nextcloud-Talk-Federation-Invites`, when a non-zero number of
  pending federated invitations exists.

A change of the Talk hash only sets an account-scoped request for new
capabilities and settings. It is not a reason to delete rooms.

## Capability, wire profile and the request builder

The exact feature flag `conversation-v4` in the signed-in capability snapshot of
a specific account enables only the candidate v4 path. It does not activate this
contract by itself. Before the merge, the first valid full response must contain
a successful OCS envelope, schema-valid rooms, the canonical cursor
`X-Nextcloud-Talk-Modified-Before` and a non-empty `X-Nextcloud-Talk-Hash`. Only
then does the account store the active profile `cursor-v4`.

A missing cursor, a missing hash or a non-canonical cursor leaves the active path
empty and marks the profile as `unsupported-wire-profile`. Neither the cache nor
the cursor may change. A legacy conversation-v4 without this profile stays
explicitly unsupported until a separate adapter is created for it. Neither a high
Talk release number nor `conversation-v3` alone is a substitute feature flag.

The request builder carries an explicit `full` or `incremental` mode. Deleting
local data is decided by that mode, not by the value of the cursor. That matters
for the safe case `incremental + modifiedSince=0` too, which still must not
delete anything. A full request sends no cursor; the server default is `0`.

Every request uses Basic auth and the origin of the specific `accountId`, a
stable `User-Agent` with the Android identity `com.nkshub.nextcloudtalk` and the
header `OCS-APIRequest: true`. The Authorization is not logged.

A pure Dart request additionally carries an immutable `accountId`, a local
request ID and the canonical `ServerBase`; the URI is derived directly from that
context. The decoder attaches the same request to every success as well as
failure result. The merge planner therefore does not accept a separate account,
request ID or request and cannot swap them between concurrent servers.

## Response and type invariants

The schema preserves unknown future fields, but requires the stable room values
needed for the list, the unread state, permissions and a future call indication.
`lastMessage` is optional for a compact response.

Before the merge these are additionally checked:

- OCS `status=ok` and `statuscode=200`; a failure inside HTTP 200 is not an empty
  list;
- every room has a valid token;
- the tokens in one response are unique;
- the token of a present `lastMessage` matches the token of its room;
- the cursor, the hash and the optional federation counter match the declared
  format.

Schema diagnostics contain only the structural JSON path and the validator type.
They never take over the `jsonschema` text with the specific wrong value, so a
live schema drift cannot print a room token, a name or the content of a message.

HTTP 401 moves only the affected account into the re-auth state. HTTP 426, 429,
503, a transport error or an invalid OCS response must neither delete the cache
nor move the cursor.

During the first profile probe, HTTP 401 returns a separate re-auth result. HTTP
426, 429, 503 and a valid OCS failure only defer the confirmation. Only a
structurally incompatible HTTP 200 response — a missing cursor/hash or a broken
schema, say — counts as `unsupported-wire-profile`. A temporary error therefore
cannot permanently disqualify a supported account. The HTTP/OCS state is
classified before the full probe mode is checked, so a 401 stays re-auth even
after an incremental request.

## The pure Dart runtime

The `talk_protocol` package now implements the whole platform-neutral boundary:

- `ConversationListRequest` owns the account, the request ID, the server, the
  explicit full/incremental mode, the canonical query string, the OCS header, the
  User-Agent and a subpath-aware URI;
- the response decoder distinguishes success, re-auth, an OCS failure and the
  supported HTTP 426/429/503 without guessing an unknown status, and binds every
  result to the original request;
- headers are case-insensitive and their case variants must not repeat;
- `ConversationRoom` and `ConversationPreview` type the list, unread, permission,
  call and preview values and preserve a deeply immutable wire object. After
  validation the room model also exposes `objectType`, `avatarVersion`,
  `isCustomAvatar`, an optional `remoteServer`, a derived `isFederated`, the
  authoritative `canEnableSip`, a bounded `sipEnabled` in the range 0 to 2 and a
  redacted personal `attendeePin`;
- `messageParameters` and `reactions` are maps. Because of PHP JSON
  serialization, an empty array `[]` is also accepted and normalized into an
  empty map; a non-empty array is rejected as an invalid conversation response;
- one JSON freeze budget applies across all rooms of a response, the depth is
  limited to 64 and the number of rooms to the OpenAPI maximum of 100,000;
- diagnostic `toString()` methods never print the account ID, a token, a name or
  a message;
- the capability resolver accepts only a signed-in `conversation-v4` snapshot and
  activates `cursor-v4` only after a valid full probe; the re-auth, deferred and
  structurally unsupported results stay distinct types.

The HTTP transport deliberately stays outside the pure Dart package. Before the
JSON decode it has to keep the already designed limit of 8 MiB, forbid redirects
and use the credentials of the specific account.

## The account-scoped transactional merge

The primary key of the store is `(accountId, roomToken)`. The pure Dart
`ConversationMergePlanner` executes the same minimal algorithm whose DB
operations the Flutter persistence layer performs atomically:

- an incremental response only upserts the returned rooms;
- a valid non-empty full response may remove missing rooms;
- the cursor and the configuration hash are stored only within the same
  successful transaction;
- a schema, OCS or semantic error leaves both the room data and the cursor
  unchanged;
- a simulated transaction failure discards the candidate plan and preserves the
  original state;
- the same room token in two accounts stays two separate records.
- a request of account or server origin B cannot be applied to the snapshot of
  account A.

The planner returns immutable upserts, the exact tokens to remove and the new
account state. It does not itself claim that the persistence happened. The
transaction failure test discards the whole candidate plan and verifies the
original snapshot and cursor; the current Drift adapter performs the same
operations in a single real transaction.

### The foreground delta and manual full reconciliation

Once a cursor exists, the Flutter foreground loop uses an incremental fetch so
that it does not download the whole list every 15 seconds. A manual refresh calls
the same account-scoped service with `forceFull=true`; the request then sends no
`modifiedSince` and a valid full response may remove a local room the server no
longer returns.

Single-flight is account-scoped and mode-aware. A full request that arrives
behind a running incremental flight first waits for it to finish and then starts
or joins a separate full flight. It therefore cannot settle for a delta result.
An incremental caller, on the other hand, may join a stronger full flight.
Cancelling one waiter does not interrupt the transport while another caller is
waiting on it.

A regression test on a single service instance verifies the sequence full →
incremental → manual full as `modifiedSince = null → cursor → null`. A missing
room is removed only from account A; the same token of account B and a pending
text-send outbox of account A are preserved. Another test blocks a running delta
and proves the follow-up full request.

This rule matches the verified iOS behaviour at SHA
[`2d31eda5e2acbf3cef27aa289376942bdf0de25d`](https://github.com/nextcloud/talk-ios/blob/2d31eda5e2acbf3cef27aa289376942bdf0de25d/NextcloudTalk/Rooms/NCRoomsManager.swift#L178-L229):
an incremental merge does not delete missing rooms and a full merge changes
rooms, messages, chat blocks, threads and federated capabilities within a single
Realm transaction. The cursor is stored per account in
[`TalkAccount.lastReceivedModifiedSince`](https://github.com/nextcloud/talk-ios/blob/2d31eda5e2acbf3cef27aa289376942bdf0de25d/NextcloudTalk/Database/TalkAccount.h#L41).

## Two-phase confirmation of an empty full list

The first valid full-empty response with an existing cache is destructively
ambiguous. The store therefore only records the local ID and the time of the
confirming request and does not move the cursor. Only a second, separate valid
full fetch within 300 seconds may remove all rooms and commit a new cursor.

Reprocessing the same request ID is not independent evidence. An account that has
no rooms already may accept a full-empty response immediately. This protection
does not ignore a legitimate permanent deletion of all rooms, but it prevents a
single transient or faulty response from destroying the local history.

After 300 seconds the old evidence expires and a new full-empty merely replaces
it. Any intervening non-empty incremental response refutes and cancels it;
another full-empty is therefore the first piece of evidence again, not a
confirmation of the deletion.

`forceFull=true` stays a full mode even after the first `confirmationRequired`.
The second attempt therefore uses a new request ID, again sends no
`modifiedSince`, and only its valid empty response may remove the rooms and clear
the confirmation state. A regression test verified three full requests in the
order initial full → first empty evidence → second empty evidence.

## Runnable verification

Local validation from the repository root:

```powershell
rtk proxy python contracts\conversation-list\validate_contract.py
```

Pure Dart verification from `packages/talk_protocol`:

```powershell
dart analyze --fatal-infos
dart test
```

The optional live smoke test loads credentials only from the variables
`NEXTCLOUD_TALK_USERNAME` and `NEXTCLOUD_TALK_APP_PASSWORD`:

```powershell
rtk proxy python contracts\conversation-list\validate_contract.py `
  --live-origin <NEXTCLOUD_ORIGIN>
```

The validator performs:

1. OpenAPI 3.1 and Draft 2020-12 validation.
2. Nine raw response fixtures including compact, empty, 401 and errors.
3. Seven exact query-builder scenarios and the wire round trip.
4. Twelve capability scenarios including the candidate/active state, an
   HTTP/OCS/schema error, a missing cursor, a missing hash and a non-canonical
   cursor.
5. Fourteen merge scenarios with nineteen transactional steps.
6. Rejection of a duplicate token, a preview mismatch and a missing token.
7. A cursor rollback, account isolation, a hash refresh, expiration and
   cancellation of the empty evidence by a non-empty delta.
8. The live-schema redaction guard with a private marker value and the IPv6
   origin case.
9. Manifest completeness and a secret scan of all fixtures.

The current local result: 1 OpenAPI document, 9 response fixtures, 7 query cases,
12 capability cases and 14 merge cases with 19 steps passed. In addition, 1
live-schema redaction guard and 1 IPv6 origin case passed. The same conversation
fixtures are loaded directly by 74 Dart tests; together with the bootstrap tests
that is 128 tests. Among them are regressions for exporting avatar/federation
metadata, PHP empty arrays, rejecting non-empty arrays, the account/origin
binding and the re-auth and deferred profile probes. The targeted conversation
suite freshly passed 74/74 on 25 August 2026, the whole of `talk_protocol` passed
569/569 after the named-thread extension, and the static analysis has no
findings.

The fresh scoped Flutter suite of 25 August 2026 passed 60 tests; 1 read-only
live test was skipped only for lack of environment credentials. It covers the
account repository, onboarding, the HTTP adapter, database migrations, the
conversation sync, the foreground loop, the shell, avatars and the adaptive
layout. It covers a manual full, a full intent behind a running delta,
guarded-empty, a resume and the avatar cache/render.

The authenticated live smoke test performed exactly two GET requests with
`noStatusUpdate=1`, `includeStatus=false` and `includeLastMessage=false`. The
full response contained 17 valid rooms and the immediate delta 0 changes. Both
responses contained the cursor as well as the Talk hash. The output contained no
names, room tokens, messages or credentials.

## What the evidence still does not cover

The Flutter repository and widget tests cover the SQLite migration, the account
scope, the full/delta merge, mode-aware single-flight, manual stale-room
reconciliation and the cache-first list. The debug APK from commit `5f6e2f4` with
SHA-256 `0d38d4ab2a665883d0ee0de7426f201c107cefc6b5f7e701b1c856255f6195cf` was
update-installed on `emulator-5554` on 25 August 2026; after a real Login Flow it
displayed live conversations and avatars and opened a room. The account survived
terminating and starting the process again; that run produced no separate
evidence of the offline conversation cache after a process death.

Still missing: live evidence of a cross-device full/delta update without a manual
refresh, a real removal of a room from another device, favorite/archive and
participant mutations, two accounts on two servers and the corresponding runtime
evidence on the Apple/Linux platforms. Background and killed-process updates have
a separate push gate; the connected Android test does not replace it. The current
state is in the [Flutter application foundation](flutter-foundation.md).
