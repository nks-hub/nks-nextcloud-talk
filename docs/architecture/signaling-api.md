# Signaling preparation contract and runtime

Verification date: 23 August 2026.

This slice prepares a real internal and HPB signaling transport without
pretending to have WebRTC media. The pure Dart package creates single-use HTTP
and WebSocket plans, accepts responses bound to the same account and epoch, and
returns an immutable candidate state. The network client, the socket lifecycle
and the atomic persistence commit stay owned by the future Flutter application.

## Verified upstream

- Talk server `f2958bb25be6604240c58a3faf9a2033a30d20e5`;
- stable Talk `f9b9e9474e3621b47f74bf8890c4642cb49eed97`;
- Talk Android `5428960f9d1eca708df1b39a0831141dcbba4729`;
- Talk iOS `2d31eda5e2acbf3cef27aa289376942bdf0de25d`;
- the high-performance backend `e007e2ed972c7322b53926d7da24a2b3faeaeccb`.

The executable contract is in `contracts/signaling`. The OpenAPI 3.1 describes
only the HTTP part, because OpenAPI is not a wire schema for WebSocket messages.
A separate validator therefore also checks the HPB client/server frames and the
runtime scenarios.

## HTTP profile

The contract contains three operations:

<!-- markdownlint-disable MD013 -->

| Operation | Wire | Purpose |
| --- | --- | --- |
| `getSignalingSettingsV3` | `GET /ocs/v2.php/apps/spreed/api/v3/signaling/settings` | Authenticated selection of the internal or the external profile |
| `pullInternalSignalingV3` | `GET /ocs/v2.php/apps/spreed/api/v3/signaling/{token}` | One account/room long poll |
| `sendInternalSignalingV3` | `POST /ocs/v2.php/apps/spreed/api/v3/signaling/{token}` | A bounded batch of ephemeral peer messages |

<!-- markdownlint-enable MD013 -->

On HTTP 200 the internal pull accepts only messages followed by exactly one final
`usersInRoom` snapshot. A snapshot before another message, a duplicate snapshot
or a missing snapshot are a malformed response with no partial commit. HTTP 400
requires a new settings/capability profile, 401 suspends only that account, 404
requests an authoritative room session refresh and 409 ends the current session
epoch.

A transport error of the settings GET releases exactly the matching pending
request and moves to `settingsRefreshRequired`, so a new bounded attempt can be
scheduled. An ambiguous GET never requests a media renegotiation on its own. The
settings, HPB and embedded internal JSON reject duplicate object members
including escaped keys.

The batch POST contains a URL-encoded `messages` array. Every item must have
`ev=message`, a JSON string `fn`, the current Nextcloud session ID and a specific
recipient. A transport error before the body allows a new plan. A possibly sent
body, or a server error in reply to one, is not retried: it opens a new room
epoch, which rebuilds every peer connection, and releases the pull of the old
epoch so a fresh one is planned. The sticky renegotiation flag is not raised on
this path.

## Settings and endpoint trust

The internal profile accepts only `signalingMode=internal`. The external profile
requires a TLS HPB endpoint and at least one complete hello credential profile. A
production endpoint may only use `https` or `wss`, must have no userinfo, query
or fragment, and the canonical socket ends with `/spreed`.

The Nextcloud app password, cookies and Basic auth are never sent to the HPB. A
full hello 1.0 carries only the server-issued ticket, the user ID and the backend
URL derived from the same Nextcloud identity. Hello 2.0 carries a server-issued
token. A federation endpoint, the remote Nextcloud origin, the room token and the
hello token form a separate trust boundary; local credentials are not forwarded
to the remote server.

The ticket, the JWT, the TURN credential, the federation token, the resume ID,
SDP and ICE candidates are not part of `toString()`, of an exception or of the
durable snapshot.

The settings response additionally carries a bounded `sipDialinInfo` with
room-specific phone instructions. Flutter uses it only transiently in the
conversation detail; the value may contain phone numbers, so it is neither logged
nor stored in the durable call snapshot.

## The HPB handshake and epochs

After the socket opens, the runtime waits at most one second for an optional
`welcome`, so that time remains within the two-second server hello limit.
`hello-v2` from the `welcome` enables hello 2.0 only with a V2 token available;
otherwise the full V1 profile is used. A missing safe fallback is `unsupported`.

A successful full hello:

1. creates a new signaling session and room epoch;
2. discards the participant snapshot and all old ephemeral peer frames;
3. sends a room join with the current Nextcloud session ID;
4. marks signaling as ready only after the room is confirmed.

A disconnect preserves the resume for 30 seconds only. A successful resume must
return the same HPB session ID and preserves the room epoch. An expired resume or
an authoritative `no_such_session` move to a new full hello. `too_many_requests`
creates a separate backoff deadline and must not cause an immediate reconnect
loop. The flag for a required renegotiation is sticky: a settings refresh, a
resume and a room confirmation must not clear it by themselves. A repeated
reconnect must not extend the original 30-second resume deadline.

A socket callback is applied only when the account ID, the server, the credential
and capability generation, the settings revision, the room token, the connection
epoch and the room epoch all match. An authoritative re-auth/settings/room
refresh explicitly closes the old socket and discards its pending requests.

## Participant and federation state

Join, change, leave and participant updates are merged by HPB session ID.
`participants/update` uses the upstream camel-case `userId` and
`nextcloudSessionId`; the `all=true` variant atomically sets `inCall` on the
whole current snapshot.

Inbound `message` and `control` accept the sender only if it is still in the
current participant snapshot. During `federation_interrupted` federated senders
are rejected, while the current local sender stays allowed.

`federation_interrupted` suspends media admission. With `federation_resumed=false`
only the federated peers are discarded, the local peers stay and the runtime
requests a renegotiation. The feature `mcu` selects the external MCU topology;
without it, external peer-to-peer remains. An unknown top-level server frame is a
bounded `unsupported`, but a malformed known frame is an error.

## The Flutter typing projection

Commit `9499288` wires signaling into the open root as well as thread chat. A
room-scoped provider is created only for an authenticated account with
`signaling-v3`, the feature `typing-privacy` and the public
`config.chat.typing-privacy=0`. A missing, private or invalid policy and the
internal transport end without a banner and without an outbound frame.

Incoming state is kept by HPB peer ID within the exact account/room scope. A
repeated `startedTyping` refreshes the 15-second timeout; `stoppedTyping`, a peer
leaving, a loss of the ready transport or closing the room removes the state. The
local composer sends a start to specific recipients, refreshes it after 10 seconds
of continuous typing and sends a stop after five seconds of inactivity. The root
and the thread share one room session, but every composer has its own source
identity; an inactive root must therefore not stop a person typing in an adjacent
thread.

Commit `030ffac` separates chat typing from media renegotiation after a process
recovery. Through a prepared external HPB, only a payload-free `startedTyping` or
`stoppedTyping` with an empty `roomType` and without `sid`, a sender and a payload
may pass as an exception. `unshareScreen` is the third payload-free peer message:
the web client sends it without a payload when a participant stops sharing their
screen, and a decoder that insisted on one failed the whole batch. SDP, ICE and forged typing stay blocked and their
rejection must not delete a pending typing state of another session. A lifecycle
refresh only re-evaluates the ban on typing; a non-empty old draft without a new
text change does not create a new start.

The design matches the upstream clients `talk-android@5428960` and
`talk-ios@2d31eda`. A live web → iOS round trip on the reference instance verified
both start and stop without sending a message. On `030ffac` the reverse iOS → web
start and the stop after inactivity passed as well. The iOS 18.6 screenshot had a
pixel contrast of 4.72:1 in light and 11.15:1 in dark mode.

Commits `a9e08f4`, `ea19395`, `3c89513`, `2760623` and `5c2df5d` added the
missing Talk room session. An open chat first performs a bounded
`POST participants/active`, verifies the matching token and a non-zero session ID,
and only then starts signaling. The in-memory cookie jar is isolated by
`accountId` and the canonical server. A per-account serial lease prevents an old
dispose/deactivate flow from touching a newer session. Account removal atomically
forbids new activation/start operations, completes its own DELETE and closes the
signaling lane before revoking the credentials. Both the session-scoped signaling
and the call response check the generation before a capture as well as before a
return; an invalidated stream has a bounded cancellation and the cleanup DELETE
uses its own late cookie. The API close waits for the session tails. Redirects
stay forbidden and the cookie domain/path/expiry apply only to a matching
first-party request. The provider and transport tests cover two accounts on the
same server, 401, an invalid 200, dispose and removal during a POST, a stale
generation, an API close, the response stream and the RFC cookie variants.

## Executable evidence

The current contract suite contains:

- 3 OpenAPI HTTP operations;
- 15 HTTP cases;
- 9 settings cases;
- 28 HPB client/server frames;
- 21 runtime scenarios with 33 state transitions;
- 9 Python unit tests of the validator.

The signaling part has 58 Dart tests: 9 contract, 18 runtime, 14 security,
13 lifecycle, 3 real loopback network and 1 release AOT test.

The Dart tests additionally load the settings and server HPB fixtures directly.
The real loopback test uses `dart:io HttpServer`, a real GET pull, a real form
POST and a real WebSocket upgrade. It verifies:

- `welcome` → hello 2.0 → room join;
- a disconnect → a reconnect → a successful resume of the same session;
- a reconnect after the resume expires → a new full hello → a room rejoin.

The release probe builds and runs the signaling scenario as a real AOT
executable. Contract validation runs with:

```powershell
rtk proxy python contracts\signaling\validate_contract.py
rtk proxy python -m unittest discover -s contracts\signaling -p "test_*.py" -v
```

## What this slice does not prove

- The Flutter HTTP/WebSocket adapter and the Drift signaling persistence exist;
  this slice still does not prove the call media engine or the whole call
  lifecycle.
- There is no runnable APK, call UI or WebRTC media engine.
- No write test was performed against a foreign or a production room.
- A local HPB server does not prove TURN, MCU media or a real internet reconnect.
- The `chatujmePixel` signaling checklist stays unchecked until a real
  release/profile APK exists. It has to verify a network change, a resume below
  and above 30 seconds, the internal fallback, a room rejoin, a process death and
  two accounts on two servers.
- Background/killed FCM, long-term performance and real radio/network transitions
  additionally require a physical Android device. Call parity also requires
  physical Android/iOS tests in the future media slice.

Signaling ready therefore only means a prepared signaling transport. It does not
mean `mediaReady`, `inCall` or a finished mobile application.
