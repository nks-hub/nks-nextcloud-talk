# Documentation

The documentation is split by how well established the knowledge is:

- [Architecture](architecture/README.md) holds the system design, requirements,
  synchronization invariants and delivery gates.
- [The Flutter application foundation](architecture/flutter-foundation.md)
  describes the implemented login, secure storage, Drift, adaptive layout and the
  runtime evidence for Android and Windows.
- [The historical push-v2 gateway contract](architecture/push-gateway-api.md)
  remains runnable protocol evidence, but is not the chosen Android product
  topology.
- [Adding a Nextcloud account](architecture/client-bootstrap-api.md) describes
  server normalization, Login Flow v2, capabilities, the runnable trust fixtures
  and the first pure Dart implementation.
- [The conversation list](architecture/conversation-list-api.md) describes room
  v4, the server cursor, the account-scoped merge and the runnable full/delta
  fixtures.
- [Chat messages](architecture/chat-messages-api.md) describe the history/future
  cursors, text send, reply, read/unread and the executable durable outbox.
- [Rich chat and threads](architecture/rich-chat-api.md) describe mentions,
  reactions, edit/delete, pin, reminders, schedule, the safe renderer and the
  account-scoped transactional state.
- [Attachment and voice message upload](architecture/attachment-upload-api.md)
  describes Talk OCS, WebDAV normal/chunk upload, safe resume and the chat
  confirmation.
- [Signaling preparation](architecture/signaling-api.md) describes internal OCS,
  the HPB WebSocket hello/resume/room, session epochs and real loopback tests
  without faked WebRTC media.
- [The dependency and asset audit](architecture/dependency-licenses.md)
  continuously records the origin, license and distribution terms of every
  dependency added.

A research claim must be bound to a specific SHA, version or real runtime test.
An architectural design must clearly distinguish an accepted decision, a
recommendation and a choice that is still open.
