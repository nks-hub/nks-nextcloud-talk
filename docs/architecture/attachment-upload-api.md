# Attachment and voice message upload contract

Date of the last update: 26 August 2026.

State: the OpenAPI, the synthetic OCS/WebDAV fixtures and the pure Dart request,
parser and durable runtime are all runnable. Flutter has the OCS/WebDAV
transport, an account-scoped Drift job store, restart-safe orchestration, a
durable file picker, image progress, retry/cancel, an authenticated image viewer,
the camera, a general file picker and the voice record/preview/submit flow. A
same-room reply for an image, a general file and a voice message has an automated
test and a build, not sender/recipient live evidence. The platform background
transfer and the complete lifecycle matrix remain open.

## Scope

The contract covers the two-phase Draft upload:

1. The Talk OCS probe creates or loads the private Draft folder.
2. A small file is uploaded with a single WebDAV `PUT`, a large one through chunk
   v1 `MKCOL` → `PROPFIND` → the missing `PUT` → `MOVE`.
3. The Talk OCS finalize moves the Draft file and creates the attachment message.
4. Only exactly one authoritative `file_shared` chat message with a matching
   account, server, room, `referenceId`, message type, file rich object and the
   expected reply/thread scope completes the local job.

The OpenAPI 3.1 for the two Talk OCS endpoints is in
[`contracts/attachment-upload/openapi.json`](../../contracts/attachment-upload/openapi.json).
The WebDAV methods and status codes are separate wire fixtures, because their
paths depend on the verified DAV user ID, the Draft path returned by the server
and a random upload session.

The classic Files share is not supported in this slice. It requires a separate
Nextcloud core contract and its own safe replay semantics.

## Verified baseline

The wire and capability behaviour is bound to:

- the Talk server `f2958bb25be6604240c58a3faf9a2033a30d20e5`;
- stable Talk `f9b9e9474e3621b47f74bf8890c4642cb49eed97`;
- Talk Android `5428960f9d1eca708df1b39a0831141dcbba4729`;
- Talk iOS `2d31eda5e2acbf3cef27aa289376942bdf0de25d`;
- the iOS upload dependency NextcloudKit 2.6.0
  `a7b1db0ee1394df9ede303a7430a916c1e283765`;
- Nextcloud core master `a0bf541f667e4d891e05a92254b167840066e1a0`;
- Nextcloud core stable34 `a599620e9b75dc3c919b39dabd82a4f98b543b74`.

The implementation uses its own types over the public wire contract and synthetic
data. No source code or asset of the official clients was adopted.

### iOS upstream audit

At the verified SHA, Talk iOS binds NextcloudKit as
[the exact version 2.6.0](https://github.com/nextcloud/talk-ios/blob/2d31eda5e2acbf3cef27aa289376942bdf0de25d/NextcloudTalk.xcodeproj/project.pbxproj#L3440-L3447).
Its `ChatFileUploader`
[hands every file to `NextcloudKit.shared.upload`](https://github.com/nextcloud/talk-ios/blob/2d31eda5e2acbf3cef27aa289376942bdf0de25d/NextcloudTalk/Chat/Chat%20upload/ChatFileUploader.swift#L149-L160).
At the exact commit of tag 2.6.0, NextcloudKit builds
[a single Alamofire upload with the method `PUT`](https://github.com/nextcloud/NextcloudKit/blob/a7b1db0ee1394df9ede303a7430a916c1e283765/NextcloudKit/NextcloudKit.swift#L343-L421).
The library does contain a helper method
[`chunkedFile`](https://github.com/nextcloud/NextcloudKit/blob/a7b1db0ee1394df9ede303a7430a916c1e283765/NextcloudKit/NKCommon.swift#L375-L444),
but it only splits a local file and the Talk uploader never calls it; it creates
no DAV upload session and no `MKCOL`, `PROPFIND` or final `MOVE`.

The official iOS client is therefore not a source of chunk wire parity. Our own
client uses the platform-neutral server contract in `fixtures/dav.cases.json`,
which independently proves both the ordinary `PUT` and the chunk v1 flow. iOS and
Android use the same Dart transport on top of it; the platform picker only
changes the durable local source.

## Capability and command boundary

The profile is created only from an authenticated capability snapshot. A Draft
upload requires `attachments.allowed`, `attachments.conversation-subfolders` and
`chat-reference-id`. The room must be non-federated and the account must
currently have write permission.

Further metadata are only enabled with the exact feature:

| Feature | Required feature |
| --- | --- |
| Caption | `media-caption` |
| Voice | `voice-message-sharing`; `audio/mpeg` or `audio/wav` |
| Same-room reply | `chat-replies` |
| Thread metadata | `threads` |
| Silent send | `silent-send` |

`replyTo` and `threadId` are mutually exclusive. A same-room root reply uses only
`replyTo`; a named thread uses only `threadId` and its canonical root. A
combination of both values is rejected already in the model, the request builder
and the fixture validator.

The server version number is not a fallback. Every command is fail-closed bound
to the `accountId`, the canonical server, the capability generation, the room
permission and the revision of the attachment replay contract. A change of the
account, the origin, the generation or the revision invalidates the old
authority.

## The durable source and metadata

A job accepts only an app-owned copy or a persistable URI grant. It stores an
opaque source handle, the size, the SHA-256, the MIME type and a safe display
name; it stores neither the raw bytes nor the temporary picker path into
diagnostics.

Before every upload or resume the platform transport must reopen the source and
supply the current size and SHA-256. A mismatch ends the job as a source
mismatch, so that different content is not sent under the original `referenceId`.

An ordinary attachment expects `messageType=comment`, voice exactly
`messageType=voice-message`. The value is derived from the immutable metadata of
the job and the finalize builder cannot overwrite it with a separate parameter.

Before the first asynchronous step, the composer snapshots the account, the room
and the metadata of the image or the file; the voice context is snapshotted when
Send is pressed. The durable admission therefore does not pick up a newer reply
selected during the picker, while loading the bytes or while sending. The reply
banner may be removed only after a successful durable admission and only if it
still points at the parent just accepted.

## The Talk OCS wire

Both the probe and the finalize use `format=json`, `OCS-APIRequest: true`, an
explicit `allowUpdate: false` and a stable `User-Agent`. The rename from the
probe is only advisory; the finalize sends the original name again and takes the
authoritative rename only from its response.

The finalize is not atomic. The server first moves the Draft file and only then
creates the chat message. A successful HTTP/OCS result therefore only means an
accepted finalization and leads into `awaitingConfirmation`. The same applies to
a 5xx, an OCS mismatch, a lost response, a possibly sent body and a restart in
the `finalizing` phase. None of these branches may trigger a blind repeat of the
finalize POST.

The documented 400, 404, 422, 501 and 507 are deterministic rejections before a
successful completion. HTTP 401 suspends only the target account lane and the job
preserves its resume point.

## The WebDAV wire and the XML parser

The Draft path returned by the server is accepted only as a safe relative path.
An absolute URI, a query, a fragment, a backslash, an empty segment, `.` and `..`
are rejected; the segments are percent-encoded again before the URI is built. A
redirect is not allowed and the `Destination` of a `MOVE` must have the same
scheme, host and port.

The chunk session is a random UUID, not a hash of the file. A chunk name is a
sixteen-digit inclusive byte range. Chunk v1 sends neither an HTTP `Range` nor a
`Content-Range`; the range is only in the name. A `MOVE` always sends the exact
`OC-Total-Length`.

The resume accepts only sorted, non-overlapping chunks of the correct length, and
the client verifies contiguity before assembling. The XML parser accepts UTF-8
only, rejects DTDs and entities before parsing and continuously enforces byte,
depth and node limits.

## The Flutter HTTP transport

`apps/mobile/lib/network/attachment_transport.dart` performs the real OCS and
WebDAV request wire through `package:http`. Before sending, every request
verifies that the account and the canonical origin match the authorization, adds
credentials only to the verified same origin and rejects a redirect. The response
body and the connect and idle phases have a fixed limit, and an exception carries
only a typed code, the step and the stage, without sensitive values.

The transport opens the app-owned source as a lease, verifies the exact length
and SHA-256 once and uses the same immutable snapshot for both the normal and the
chunk PUT. The range API must perform an efficient seek to the offset and emit at
most the requested length; a late chunk therefore must not read linearly again
and discard the preceding bytes. The upload checks the exact byte count and
classifies both a premature end and extra bytes as a change of the source.

A caller cancel, an idle/connect timeout and `close()` use a shared detachable
abort signal. A source opening that completes late must not be added among the
verified leases and its lease is closed. The cleanup has one bounded budget, but
a failure to cancel the iterator must not skip closing the request sink or the
other steps. The tests use a deterministic HTTP client and sources; they do not
prove a real socket, a ContentProvider/NSFileCoordinator or a Nextcloud server.

## Flutter orchestration and UI

`AttachmentRepository` stores the account, the room, the immutable source
metadata, the capability profile and the exact durable phase in Drift.
`AttachmentService` resumes jobs in progress, preserves the room
FIFO/single-flight, separates a safely retryable upload from an ambiguous
finalize and confirms completion only with an authoritative chat message. The
credential is read only at the specific account-scoped request and only a
reference to the account stays in the database.

The confirmation join in Drift is limited to the same account, server, room and
`referenceId`. The cached payload is decoded again and must match the indexed
message ID, the room, the reference, the system message and the message type. The
runtime additionally requires a positive message ID, an empty system message, a
file rich object and the exact `messageType`; a reply job must have a matching
parent, a named-thread job a matching parent as well as a `threadId` equal to the
canonical root. Zero matches stays pending and several matches is ambiguous.

An ordinary reply may accept a compact deleted parent only with an exact
`parent.id == replyTo`, `parentRoomToken == null`, `parentThreadId == null` and a
positive outer `threadId`. The same invariant applies after an ambiguous finalize
as well as during restart reconciliation. The client never repeats the finalize
POST; exactly one authoritative match completes the job and its durable source is
released exactly once.

`ChatMediaComposer` uses `file_selector` for the gallery and a general file and
`image_picker` for the camera, creates an app-owned copy and, after the durable
admission, hands over its ownership to the attachment service. The status panel
distinguishes preparation, upload, waiting for a confirmation, completion, retry,
cancel and an error; a short confirmation cleans itself up after a success. The
message renderer loads images with authentication from the same account origin
and a tap opens a separate viewer, not a new upload dialog.

Commit `658bd5f` adds a desktop drop as another entry point to the same
orchestration. The scope of an open compact or expanded conversation accepts
exactly one ordinary file. A directory, several files and an oversized file end
before the durable admission; a macOS security-scoped resource is released in
both the success and the error branch. An accepted file is immediately copied
into app-owned storage and then uses the same `ChatMediaComposer` and
`AttachmentService` flow unchanged. No new upload transport is created.

The voice branch uses `record` and `audioplayers`. It verifies the capability and
the microphone permission, keeps the recording as a durable app-owned source,
offers a local preview and sends it through the same attachment orchestration
with `voice-message` metadata. Automated tests cover a denied permission,
recording, the preview, cancel, retry, the durable admission and cleanup. This is
not yet live evidence of the microphone, playback and server delivery on a target
device.

## State, retry and cleanup

The durable phases are `localPrepared`, `probing`, `draftResolved`, `uploading`,
`uploaded`, `finalizing`, `awaitingConfirmation`, `completed`, `retryable`,
`failed`, `cancelling`, `cancelled` and `cleanupFailed`.

- The probe and a stable private upload can be safely resumed before
  finalization.
- After the upload and a share error the bytes are not uploaded again.
- Every restart resumes a specific resume point; it does not blindly start the
  job from the beginning.
- Within one room, FIFO and single-flight apply to the finalization. Other rooms
  and accounts do not block each other.
- A cancel before the finalize deletes only the chunk session and the Draft temp
  file owned by the job. Once the finalize has started, the client must no longer
  claim it cancelled the message, nor delete a possibly final file.
- Zero confirming messages is not proof that nothing happened. Several matches
  stays explicitly ambiguous; a single match completes the job.

A pure Dart change returns a single-use candidate plan bound to the identity of
the source snapshot. The Flutter `AttachmentRepository` commits it atomically into
Drift, or discards it entirely.

## Security and diagnostics

A request carries the account, the request ID, the server, the room, the job ID,
the capability generation and the contract revision. The response preserves the
exact original request; a merge context is not supplied on the side. JSON, XML,
maps and lists are bounded and immutable.

Neither `toString()` nor a protocol exception may contain the account ID, the DAV
user ID, the room token, a filename, the Draft path, the source handle, the
reference ID, a checksum, a caption, the message text or the XML content.

### A received contact as a vCard attachment

Talk Android `5428960` exports the selected system contact into a `.vcf` file and
sends it with the same upload as any other file attachment. It is not a separate
rich object wire type. `9d6b0fe` therefore extends only the reception of a
general attachment, not the transport or the address book permissions.

The contact card is used for the strong MIME types `text/vcard`, `text/x-vcard`
and `text/directory`. The fallback for `application/octet-stream` or
`binary/octet-stream` requires `.vcf` on the last segment of an already validated
`DavRelativePath`; the displayed name must not falsify the type. An unpermitted
MIME stays a general file even with a `.vcf` path. Without a valid account-bound
DAV path no open action is rendered.

Opening reuses, unchanged, the existing authenticated download, the content type
check, an app-owned temporary file and the platform opener. The card has a
separate button semantics node with a tap action, a 48dp minimum and bounded text
at 200%.

The live test on iOS 18.6 performed a WebDAV PUT of a generic vCard, a Files
share `shareType=10`, reception in a second account, the render, an authenticated
download and the native contact preview. The light/dark/accessibility-large
layout did not overflow; the contrast is 6.4986:1 and 11.6343:1. Both the message
and the file were deleted and the follow-up check returned 0 messages and 0
files.

### Sending a contact from the address book

`f743c45` added a separate platform producer boundary for Android and iOS. The
foreground picker does not read the whole address book and needs no
`READ_CONTACTS`; the user selects exactly one card. The native layer builds a
vCard 3.0 with FN, removes PHOTO, rejects multiple cards and limits the output to
2 MiB. Flutter stores an app-owned copy and hands it to the existing file
attachment admission with the MIME type `text/vcard`.

The scope of the account, the room, the ordinary/named thread, the capability and
the credential is snapshotted before the picker opens and re-verified on return.
A cancel creates neither a job nor an error; permission, unavailable, invalid and
oversized have separate localized states. iOS 18.6 build 33 selected a system
contact live, completed message 78167, rendered an accessible contact card and
after deletion confirmed `comment_deleted`. The DAV check after the cleanup found
no fresh vCard.

## Runnable verification

```powershell
rtk proxy python contracts\attachment-upload\validate_contract.py
rtk proxy python contracts\attachment-upload\test_validate_contract.py
rtk C:\work\sources\flutter-sdk\flutter\bin\dart.bat analyze --fatal-infos
rtk C:\work\sources\flutter-sdk\flutter\bin\dart.bat test
rtk C:\work\sources\flutter-sdk\flutter\bin\flutter.bat test `
  test\attachment_transport_test.dart `
  test\attachment_repository_test.dart `
  test\attachment_service_test.dart `
  test\attachment_submission_test.dart `
  test\image_attachment_upload_controller_test.dart `
  test\image_attachment_upload_panel_test.dart `
  test\authenticated_image_viewer_test.dart `
  test\chat_composer_voice_test.dart `
  test\chat_media_composer_test.dart `
  test\chat_composer_integration_test.dart `
  test\chat_attachment_context_test.dart
```

The contract contains 12 OCS fixtures, 15 capability cases, 20 wire cases, 7 DAV
plans with 11 state outcomes, 3 XML fixtures and 25 state scenarios. The Python
validator has 18 unit tests. On 26 August 2026 the current combined pure Dart
attachment suite of contract, DAV, runtime, security and release AOT passed
58/58. The current count for the whole of `talk_protocol` is tracked in the
requirements matrix, so that a historical sum from an earlier attachment
milestone does not linger here.

A fresh scoped run on the current HEAD passed 22/22 in
`attachment_runtime_test.dart` and 27/27 in `attachment_service_test.dart`. A
deleted ordinary-reply parent is also covered after a catch-up/restart, including
a single release of the durable source.

The original Flutter `attachment_transport_test.dart` milestone passed 25/25 on
24 August 2026. On 25 August the combined targeted suite of the transport, the
repository, the service, the submission, the image controller/panel/viewer and
the voice controller passed 91/91. The current full count and the APK hash are
tracked in the [development status](development-status-2026-08-25.md), so that a
historical transport milestone is not mixed with later slices here.

The scope binding is documented by commits `d518694`, `4b4e61b` and `cd22bdb`.
The repository recovery test preserves separate reply and named-thread scopes;
the runtime tests reject a wrong parent or thread root. An integration widget test
carries a media reply from the production pane through the durable enqueue all
the way to the finalize with `replyTo=109` and without a `threadId`; the focused
media/composer suite passed 49/49. This evidence is automated and build-level,
not a live run against a server.

## What the evidence does not cover

The automated tests use a deterministic HTTP client and test platform backends.
They do not prove a current live upload into Nextcloud, a real microphone and
playback, a process loss during every durable phase, or two accounts on two
servers. In particular, a combined live Nextcloud + process-death pass for the
ambiguous finalize and the deleted-parent confirmation is missing; the automated
restart tests do not replace it. `chatujmePixel` therefore still has to pass a
small as well as a chunked file, an image, a name collision, permissions and the
quota, a restart between every two phases, cancel/cleanup and the whole voice
lifecycle including the media reply sender/recipient flow. The camera and general
files have automated coverage, but no current live evidence. A real background
transfer, a background recorder and performance will additionally be proven on a
physical Android device.
