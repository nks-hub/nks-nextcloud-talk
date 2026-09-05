# Architecture

State: a runnable Flutter foundation and a production pure Dart bootstrap,
conversation, chat, rich-chat, attachment, signaling preparation and historical
push-v2 runtime. The client is licensed under `GPL-3.0-or-later` and uses the
identity `com.nkshub.nextcloudtalk` on Android, iOS and macOS. The same Flutter
codebase also targets Windows and Linux. Commit `cf13cce` closes the platform
runners; their existence alone does not prove a signed build or a live lifecycle
on every platform.

The fresh automated gate has `flutter analyze` with no findings, 1493 passing
Flutter tests with four credential-gated skips and 946/946 `talk_protocol` tests.
Android push in `3c74165` additionally passed 16/16 Kotlin unit and 15/15
connected tests on `chatujmePixel`. The exact split between code, automation,
live evidence and open parts is tracked in the maintainer notes, which are not
part of this repository.

## Design outcome

The accepted smallest complete architecture has two mandatory, separately
testable parts:

1. A Flutter application for mobile and desktop.
2. A pure Dart Talk protocol package with no Flutter dependencies.

Per D-038 the default transport on Android and on the Apple platforms is our own
proxy `nks-talk-notify`, which holds the sending branch to FCM v1 and to APNs.
Notifications Web Push over the UnifiedPush connector and the embedded FCM
distributor remains a switchable fallback on Android; only that one works without
an own gateway. A Nextcloud addon is not part of the installation in either
branch.

Nextcloud → proxy → FCM/APNs → terminated app has been proven live since
28 August 2026 on both Android and iOS on top of `140b0a9`, including decrypted
content, notification actions and delete payloads. A physical device and two real
servers at the same time remain an open gate.

Inside the mobile app, storage, sync and feature modules stay where they are
until a real second implementation justifies another package. The call subsystem
has boundaries for two signaling transports and two platforms from the start, but
the media implementation is not created as an empty stub.

## Documents

- [System design](system-design.md)
- [Synchronization and local data](sync-storage.md)
- [Flutter application foundation](flutter-foundation.md)
- [Historical OpenAPI and client push-v2 runtime](push-gateway-api.md)
- [OpenAPI and fixtures of the client bootstrap](client-bootstrap-api.md)
- [OpenAPI, fixtures and merge contract of the conversation list](conversation-list-api.md)
- [OpenAPI, merge and outbox contract of chat messages](chat-messages-api.md)
- [OpenAPI, renderer and state contract of rich chat](rich-chat-api.md)
- [Server-authoritative shared-items contract](shared-items-api.md)
- [Capability-bound message translation](message-translation-api.md)
- [Capability-bound current location sharing](location-sharing-api.md)
- [Talk OCS, WebDAV and the attachment state contract](attachment-upload-api.md)
- [Internal/HPB signaling contract and runtime](signaling-api.md)
- [Decisions and open choices](decisions.md)
- [Technical decisions](decisions-technical.md)
- [Dependency and asset audit](dependency-licenses.md)
- [Pure Dart talk_protocol](../../packages/talk_protocol/README.md)

## Principles

- Capability-first instead of versions hardcoded in the client.
- Account scope on every data and background boundary.
- One authoritative merge flow for HTTP, HPB, push and the outbox.
- A stable referenceId as a correlation; the Talk server does not enforce it as
  an idempotency key.
- OCS and database transactions decide success, not optimistic UI state.
- Push carries an opaque encrypted wake-up, not the source of truth.
- The platform lifecycle stays in the Kotlin/Swift or desktop runner layer.
- The layout adapts to the window; the desktop is neither a separate client nor a
  stretched phone screen.
- Every vertical slice ends with a real run, not just a build or a mock.
