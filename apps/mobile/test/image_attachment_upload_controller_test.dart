import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/media/image_attachment_upload_controller.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  test(
    'reports real upload progress and confirmation before completion',
    () async {
      final events = StreamController<ImageAttachmentUploadEvent>(sync: true);
      addTearDown(events.close);
      final controller = ImageAttachmentUploadController(
        startUpload: (_) async => ImageAttachmentUploadSession(
          events: events.stream,
          cancel: () async {},
        ),
      );
      addTearDown(controller.dispose);

      await controller.startPrepared(_request);
      expect(controller.state.phase, ImageAttachmentUploadPhase.queued);

      events.add(ImageAttachmentUploadEvent.uploading(0.4));
      expect(controller.state.phase, ImageAttachmentUploadPhase.uploading);
      expect(controller.state.progress, 0.4);

      events.add(ImageAttachmentUploadEvent.awaitingConfirmation());
      expect(
        controller.state.phase,
        ImageAttachmentUploadPhase.awaitingConfirmation,
      );

      events.add(ImageAttachmentUploadEvent.completed());
      expect(controller.state.phase, ImageAttachmentUploadPhase.completed);
      expect(controller.state.progress, 1);
    },
  );

  test('cancels a session returned after cancellation was requested', () async {
    final pendingSession = Completer<ImageAttachmentUploadSession>();
    var cancellationCount = 0;
    final controller = ImageAttachmentUploadController(
      startUpload: (_) => pendingSession.future,
    );
    addTearDown(controller.dispose);

    final starting = controller.startPrepared(_request);
    await pumpEventQueue();
    expect(controller.state.phase, ImageAttachmentUploadPhase.queued);

    await controller.cancel();
    expect(controller.state.phase, ImageAttachmentUploadPhase.cancelling);

    pendingSession.complete(
      ImageAttachmentUploadSession(
        events: const Stream<ImageAttachmentUploadEvent>.empty(),
        cancel: () async {
          cancellationCount++;
        },
      ),
    );
    await starting;

    expect(cancellationCount, 1);
    expect(controller.state.phase, ImageAttachmentUploadPhase.cancelled);
  });

  test('retries a dispatch failure with the exact prepared request', () async {
    final events = StreamController<ImageAttachmentUploadEvent>(sync: true);
    addTearDown(events.close);
    final requests = <ImageAttachmentUploadRequest>[];
    final controller = ImageAttachmentUploadController(
      startUpload: (request) async {
        requests.add(request);
        if (requests.length == 1) {
          throw StateError('Synthetic dispatch failure.');
        }
        return ImageAttachmentUploadSession(
          events: events.stream,
          cancel: () async {},
        );
      },
    );
    addTearDown(controller.dispose);

    await controller.startPrepared(_request);
    expect(controller.state.phase, ImageAttachmentUploadPhase.failed);
    expect(controller.state.failureCode, 'dispatch-failed');
    expect(controller.state.retryAllowed, isTrue);

    await controller.retry();
    expect(requests, <ImageAttachmentUploadRequest>[_request, _request]);
    expect(controller.state.phase, ImageAttachmentUploadPhase.queued);

    events.add(ImageAttachmentUploadEvent.uploading(1));
    events.add(ImageAttachmentUploadEvent.awaitingConfirmation());
    events.add(ImageAttachmentUploadEvent.completed());
    expect(controller.state.phase, ImageAttachmentUploadPhase.completed);
  });

  test(
    'does not cancel a durable session that arrives after disposal',
    () async {
      final pendingSession = Completer<ImageAttachmentUploadSession>();
      var cancellationCount = 0;
      final controller = ImageAttachmentUploadController(
        startUpload: (_) => pendingSession.future,
      );

      final starting = controller.startPrepared(_request);
      await pumpEventQueue();
      controller.dispose();
      pendingSession.complete(
        ImageAttachmentUploadSession(
          events: const Stream<ImageAttachmentUploadEvent>.empty(),
          cancel: () async {
            cancellationCount++;
          },
        ),
      );
      await starting;

      expect(cancellationCount, 0);
    },
  );

  test(
    'disposal detaches an active durable upload without cancelling it',
    () async {
      final events = StreamController<ImageAttachmentUploadEvent>(sync: true);
      addTearDown(events.close);
      var cancellationCount = 0;
      final controller = ImageAttachmentUploadController(
        startUpload: (_) async => ImageAttachmentUploadSession(
          events: events.stream,
          cancel: () async {
            cancellationCount++;
          },
        ),
      );

      await controller.startPrepared(_request);
      events.add(ImageAttachmentUploadEvent.uploading(0.4));
      controller.dispose();
      await pumpEventQueue();

      expect(cancellationCount, 0);
    },
  );

  test('maps an unfinished event stream to a retryable failure', () async {
    final events = StreamController<ImageAttachmentUploadEvent>(sync: true);
    final controller = ImageAttachmentUploadController(
      startUpload: (_) async => ImageAttachmentUploadSession(
        events: events.stream,
        cancel: () async {},
      ),
    );
    addTearDown(controller.dispose);

    await controller.startPrepared(_request);
    await events.close();
    await pumpEventQueue();

    expect(controller.state.phase, ImageAttachmentUploadPhase.failed);
    expect(controller.state.failureCode, 'event-stream-ended');
    expect(controller.state.retryAllowed, isTrue);
  });
}

final ImageAttachmentUploadRequest _request = ImageAttachmentUploadRequest(
  accountId: AccountId.parse('account-a'),
  server: ServerBase.parse('https://cloud.example.invalid'),
  roomToken: ConversationToken.parse(
    'rooma123',
    path: r'$.roomToken',
    code: TalkProtocolErrorCode.invalidAttachmentModel,
  ),
  source: PreparedAttachmentSource(
    handle: AttachmentSourceHandle.parse('app-owned-image-1'),
    ownership: AttachmentSourceOwnership.appOwnedCopy,
    byteLength: 1024,
    sha256: AttachmentSha256.parse(
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    ),
    mimeType: 'image/jpeg',
    displayName: 'photo.jpg',
  ),
  metadata: AttachmentMetadata(
    kind: AttachmentMessageKind.file,
    replyTo: null,
    threadId: null,
    threadTitle: null,
    silent: false,
  ),
);
