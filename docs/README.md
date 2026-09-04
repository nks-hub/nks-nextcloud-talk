# Documentation

The documentation is split by how well established the knowledge is:

- [The complete TODO](TODO.md) is a continuously maintained list of every open
  item across requirements, the priority queue and the backlog.
- [Research](research/README.md) holds verified upstream and runtime facts.
- [Architecture](architecture/README.md) holds the system design, requirements,
  synchronization invariants and delivery gates.
- [Designs](plans/README.md) work out the recommended or accepted operational
  flows and their boundaries.
- [The completion audit](architecture/completion-audit.md) separates the runnable
  Flutter foundation from the still unfinished product parity.
- [Development status as of 25 August 2026](architecture/development-status-2026-08-25.md)
  is the current feature matrix, Android how-to, push topology and priority
  queue. The snapshot separates 354 passing Flutter tests and one
  credential-gated skip, 569/569 `talk_protocol` tests, Android push unit 16/16
  and emulator connected 15/15, real live evidence and slices not verified yet.
- [The Flutter application foundation](architecture/flutter-foundation.md)
  describes the implemented login, secure storage, Drift, adaptive layout and the
  runtime evidence for Android and Windows.
- [Push and FCM](research/push-fcm.md) describes direct Android Notifications Web
  Push without an own gateway and the separate APNs/PushKit boundary for iOS.
- [Giphy integration](research/giphy-integration.md) describes server-side
  search/trending, the hidden Talk wire reference and the real inline animated
  GIF. The wire URL must not be shown as a message and is not an attachment; the
  only visible external link is the GIPHY attribution in the picker.
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
- [The original Flutter client](plans/2026-08-22-original-flutter-client-design.md)
  delimits the Talk-inspired look, the improvements and the clean-room boundary.
- [The dependency and asset audit](architecture/dependency-licenses.md)
  continuously records the origin, license and distribution terms of every
  dependency added.

A research claim must be bound to a specific SHA, version or real runtime test.
An architectural design must clearly distinguish an accepted decision, a
recommendation and a choice that is still open.
