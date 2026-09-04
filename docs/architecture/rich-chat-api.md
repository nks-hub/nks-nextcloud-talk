# Rich chat and thread contract

Verification date: 26 August 2026.

State: the OpenAPI, the synthetic fixtures, the pure Dart request/response model,
the safe semantic renderer and the account-scoped transactional planner are all
runnable. The Flutter application already has a cache-first root/thread timeline,
text send, GFM/Rich Object display, images with an internal viewer, reactions, a
reply preview and avatars; the rich mutation commands from this contract are not
wired into the Flutter runtime yet.

A text send into a server-side named thread is implemented in a separate chat
contract, revision r2. It uses `threadId` without `replyTo` and does not mean
that rename/notification-level or the other rich thread mutations below are
implemented.

Per D-028, Giphy is sent as a textual `resourceUrl` reference and the bubble
hides it and renders it inline through the account-scoped Nextcloud References
resolver. The historical attachment variant D-028a is no longer the product flow.
The detailed contract is in the
[Giphy integration](../research/giphy-integration.md).

## Scope

The contract covers 21 existing Talk operations:

- searching for mentions;
- recent, subscribed and the detail of threads, renaming and the notification
  level;
- loading, adding and removing reactions;
- editing and deleting a message;
- pin, unpin and hiding a pin for the current user;
- loading, creating and deleting a reminder;
- listing, creating, editing and deleting a scheduled message.

The OpenAPI 3.1 is in
[`contracts/rich-chat/openapi.json`](../../contracts/rich-chat/openapi.json). The
schema preserves unknown server fields, but requires the identities needed for
the account, room, message, thread and schedule binding.

## Verified baseline

The wire and capability behaviour is bound to:

- the Talk server `f2958bb25be6604240c58a3faf9a2033a30d20e5`;
- the stable Talk replay reference `f9b9e9474e3621b47f74bf8890c4642cb49eed97`;
- Talk Android `5428960f9d1eca708df1b39a0831141dcbba4729`;
- Talk iOS `2d31eda5e2acbf3cef27aa289376942bdf0de25d`.

These are our own types over the public wire contract and synthetic data. No
source code or asset of the official clients was taken into this slice.

## Capability profile

The resolver relies only on unique Talk features, never on a release number.

| Feature | Required conditions |
| --- | --- |
| Mentions | `chat-v2` |
| Thread metadata | `chat-v2` + `threads` |
| Thread messages | thread metadata |
| Reactions | `chat-v2` + `reactions` |
| Sending a reaction | reactions and, with `react-permission`, participant bit 256 |
| Editing | `chat-v2` + `edit-messages` |
| Deleting | `chat-v2` + `delete-messages` |
| Pin | `chat-v2` + `pinned-messages` and moderator |
| Hiding a pin | `chat-v2` + `pinned-messages` |
| Reminder | `chat-v2` + `remind-me-later` |
| Schedule | local `scheduled-messages` and a non-federated room |

`scheduled-messages` from the global features is deliberately not accepted. A
federated profile preserves the thread metadata and the capability-bound detail
of thread messages; it rejects only unsupported local schedule operations.

## Request and trust boundary

Every request carries the `accountId`, a local request ID, the canonical
`ServerBase`, the capability profile and the available room, message, thread or
schedule identifier. Account-wide subscribed threads is the only operation
without a room token. The response keeps the original request and the planner
must not accept a merge context on the side.

The notification-level request uses only the canonical `threadId`: both the wire
URL and the response binding point at the root of the thread. The historical name
of the server parameter, `messageId`, does not change its meaning; the server
verifies it before the mutation through `findByThreadId` and both upstream mobile
clients send the canonical root. The decoder rejects a missing or zero root as
well as a room/root mismatch and preserves the original request. Before applying,
the merge planner rejects an account/server snapshot mismatch.

Nested `first` and `last` are only acceptable when the room token and the
canonical `threadId` match. `first.messageId` must be the root of the thread,
`last.messageId` must equal `lastMessageId` and both messages must carry
`threadId == thread.id`. A mismatch is rejected before a merge candidate is
created.

The request builder always uses `format=json`, `OCS-APIRequest: true` and a stable
`User-Agent`. The query, the form body and the headers are immutable. Diagnostics
never print the room token, the message text, the searched text, an emoji, rich
parameters or a user identifier.

Before creating the model, the parser:

1. limits the body to 8 MiB;
2. requires valid UTF-8 JSON and a bounded tree;
3. verifies the HTTP status as well as the OCS `statuscode` for the specific
   operation;
4. binds the data to the original account/server/room/message/thread context;
5. deeply freezes all preserved wire maps and lists.

HTTP 401 switches only the target account into the re-auth state. A documented
validation, permission or not-found response is a deterministic rejection. An
unexpected status, a 5xx or the result of a mutation that may have reached the
server is ambiguous and must not trigger an automatic retry.

## Markdown and Rich Object Strings

The renderer uses `markdown` 7.3.1 with the GFM extension set and converts the
AST into its own immutable semantic tree. Raw HTML is never returned as
executable widget content. A Rich Object placeholder is replaced only inside text
nodes; inline and block code stay literal. A known placeholder always turns into
a typed node, an unknown one stays text.

The shared budget for both plaintext and Markdown allows at most 1 Mi characters,
10,000 parameters, a depth of 64 and 200,000 semantic nodes including the
document root. Every node consumes budget before construction and before a
parameter lookup; an overflow is therefore rejected without materializing the
rest of an attacking input.

Active links allow only `https`, `mailto` and `tel`. A relative link is accepted
only after it resolves to the same server origin. Userinfo, control characters,
`javascript:`, `data:`, `file:`, `intent:` and a cross-origin relative result are
never returned as an active link.

The mention types user, guest, email, user-group, circle, call and federated user
have their own semantic kind. Other Rich Object Strings stay typed generic
objects with immutable metadata, so that a later Flutter widget does not have to
parse them again from raw text.

## Account-scoped state and the atomic merge

`RichChatRuntimeSnapshot` layers rich state on top of the existing
`ChatRuntimeSnapshot`. Every account holds its own server and rooms; a room holds
messages, threads, reminders, scheduled messages and a reference to the last
message. There is no global message or thread registry.

A single-use plan is bound to the identity of the exact source snapshot. Reusing
it or applying it to a newer snapshot is rejected. A simulated DB failure discards
the whole candidate.

- A reaction response replaces the whole aggregate and derives `reactionsSelf`
  from the actor identity; the same response is idempotent.
- A reaction, an edit and a delete replace the authoritative message and, within
  the same candidate, fix every full-parent copy in the room messages, the
  scheduled reply parent, the thread first/last and the room preview. The
  immutable `wire` of the parent is updated as well.
- Thread metadata with a new `lastMessageId` but without the body of the new
  message does not keep the old `lastMessage` under the wrong ID.
- A metadata-only rename reprojects the new title into the thread
  first/last/root, all room and parent copies and their immutable wire within a
  single candidate.
- Reminder and schedule state is keyed inside the account and the room.
- An ambiguous schedule response does not change state and does not create a
  replay.

Online rich mutations are not in the durable outbox in this slice. Every future
operation kind must first obtain its own SHA/capability-bound replay contract per
D-006.

## Runnable verification

```powershell
rtk proxy python contracts\rich-chat\validate_contract.py
rtk proxy python contracts\rich-chat\test_validate_contract.py
rtk C:\work\sources\flutter-sdk\flutter\bin\dart.bat analyze --fatal-infos
rtk C:\work\sources\flutter-sdk\flutter\bin\dart.bat test
```

The current local result:

- 1 OpenAPI document and 21 operations;
- 23 response, 28 request, 8 capability, 9 render and 7 state fixtures with
  8 transactional steps;
- 13 Python validator unit tests;
- 102 Dart rich-chat tests covering the contract, state, security and a real
  release AOT executable;
- the scoped analyzer has no findings.

The historical attachment branch was created in `5d49cbb`, `9de5727` and
`7ca580e`, but the user decision D-028 replaced it. Commit `2af2430` switched the
picker to a rendered `resourceUrl` through text-send/outbox and preserved both the
account-scoped References validation and the inline renderer; the later `4cc3594`
and `236e3c4` only atomized the change. This is automated adapter evidence, not a
current live sender/recipient round trip.

## What the evidence does not cover

The Flutter HTTP/Drift/UI foundation exists. The historical Android APK SHA-256
`0d38d4ab2a665883d0ee0de7426f201c107cefc6b5f7e701b1c856255f6195cf` passed login,
opening a room and the Giphy wire-reference send/inline/process-death scenario. It
does not prove the current source, a separate sender/recipient round trip or a
rich mutation round trip. An even older Android APK SHA-256
`<fingerprint>` passed an
incoming thread smoke test, screenshots and a pixel WCAG measurement; that
evidence does not carry over to a newer build. No live round trip was run for
edit/delete, reaction mutations, pin, reminder or schedule, nor for their
restart/reconciliation flow. The automated thread binding and rename evidence has
no current combined live-server + process-death counterpart. The whole rich-chat
mutation checklist still has to pass on `chatujmePixel`; background/killed Web
Push and performance additionally require a physical Android device.
