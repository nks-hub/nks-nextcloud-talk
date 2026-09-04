# talk_protocol

Pure Dart types and validation logic for the public Nextcloud and Talk wire
contracts. The package performs no network requests and stores no credentials.
The HTTP transport, secure storage and account-scoped persistence are owned by
the mobile application.

The implemented slices cover:

- canonicalization and trust validation of the Nextcloud server origin;
- the `status.php`, Login Flow v2 and OCS capabilities endpoints;
- safe classification of the server status and of the Login Flow poll response;
- a typed capability snapshot without losing unknown namespaces;
- the same fixture contracts as `contracts/client-bootstrap`;
- an exact full/incremental conversation v4 request builder bound to the account,
  the request ID and the server origin;
- classification of success, re-auth, OCS failure and HTTP 426/429/503;
- strict cursor/hash headers, typed immutable room and preview models;
- activation of the cursor-v4 profile only after a valid full probe;
- a clean account-scoped merge plan with an origin check and a two-phase
  full-empty confirmation;
- separate active, re-auth, deferred and unsupported results of the profile
  probe;
- capability-first chat history, future, long poll, text send, reply, read and
  mark-unread requests bound to the account, the origin, the room and the thread
  scope;
- a bounded UTF-8/JSON parser, deeply immutable message models, decimal cursors
  without a lossy integer conversion and redacted diagnostics;
- an atomic single-use chat merge plan, ChatBlock convergence and a text-send
  outbox with per-room FIFO/single-flight, restart and ambiguous-send
  reconciliation.
- capability-bound mentions, threads, reactions, edit/delete, pin, reminder and
  scheduled-message requests for 21 rich-chat operations;
- a bounded immutable rich-chat response parser and an account-scoped single-use
  plan for messages, thread first/last, room preview, reactions, reminders and
  schedule;
- a GFM and Rich Object String renderer into a safe semantic tree without
  executable raw HTML or unsafe active links;
- capability-bound attachment probe and finalize requests with a stable
  `referenceId`, a fixed `allowUpdate: false` and a typed file/voice contract;
- a normal WebDAV PUT as well as resumable chunked MKCOL/PROPFIND/PUT/MOVE with
  exact lengths, safe relative paths and a bounded DAV XML parser;
- an immutable account-scoped attachment runtime with a source check, FIFO
  finalization, re-auth, cancel/cleanup and no blind retry of an ambiguous
  finalize.
- internal OCS long poll and bounded batch plans with exact classification of
  200/400/401/404/409 and protection against replaying a possibly sent body;
- external HPB settings, TLS endpoint trust, welcome, full hello 1.0/2.0, a
  30-second resume, room join, reconnect/backoff and session loss;
- an account/connection/room-scoped signaling runtime, a participant/federation
  snapshot, MCU/no-MCU topologies and an explicit ban on fake media admission.
- one provider-token handle for multiple accounts, a per-account RSA key handle,
  deterministic single-flight registration, exact retry, 409 recovery and
  capability/logout cleanup preserving a safe revocation order;
- ephemeral push routing bound to the ciphertext, the signature, the
  account/key/token generation, the current runtime snapshot and exactly one
  valid OAEP or PKCS#1 v1.5 decrypt result.

The package loads all fixtures directly from `contracts/client-bootstrap` and
`contracts/conversation-list`, `contracts/chat-messages` and
`contracts/rich-chat`, and implements the same attachment contract as
`contracts/attachment-upload` and the same settings/server-frame contract as
`contracts/signaling`. The push contract test additionally loads all 8 fixtures
directly from `contracts/push-client`. It currently passes
`dart analyze --fatal-infos` with no findings and 527 Dart tests, including real
release AOT executable and signaling loopback HTTP/WebSocket tests. The planner
prepares a complete candidate account snapshot; the real SQLite transaction, the
platform network and crypto transport and the background scheduler will be owned
by a future Flutter/Drift layer.

The package is part of a project licensed under `GPL-3.0-or-later`; the canonical
text is in the root `LICENSE` file.
