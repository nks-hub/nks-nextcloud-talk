import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/attachment_upload_telemetry.dart';
import 'package:nextcloudtalk/features/chat/attachment_service.dart';
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
    final diagnostics = <AttachmentUploadDiagnostic>[];
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
      reportDiagnostic: diagnostics.add,
    );
    addTearDown(controller.dispose);

    await controller.startPrepared(_request);
    expect(controller.state.phase, ImageAttachmentUploadPhase.failed);
    expect(controller.state.failureCode, 'dispatch-failed');
    expect(controller.state.retryAllowed, isTrue);
    expect(
      diagnostics.where(
        (event) =>
            event.checkpoint == AttachmentUploadCheckpoint.admissionFailed,
      ),
      hasLength(1),
    );

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
    final diagnostics = <AttachmentUploadDiagnostic>[];
    final controller = ImageAttachmentUploadController(
      startUpload: (_) async => ImageAttachmentUploadSession(
        events: events.stream,
        cancel: () async {},
      ),
      reportDiagnostic: diagnostics.add,
    );
    addTearDown(controller.dispose);

    await controller.startPrepared(_request);
    await events.close();
    await pumpEventQueue();

    expect(controller.state.phase, ImageAttachmentUploadPhase.failed);
    expect(controller.state.failureCode, 'event-stream-ended');
    expect(controller.state.retryAllowed, isTrue);
    expect(
      diagnostics.where(
        (event) => event.checkpoint == AttachmentUploadCheckpoint.streamFailed,
      ),
      hasLength(1),
    );
  });

  test(
    'queued watchdog identifies admission and durable scheduler stalls',
    () async {
      final diagnostics = <AttachmentUploadDiagnostic>[];
      final timers = <_ManualTimer>[];
      final pendingSession = Completer<ImageAttachmentUploadSession>();
      final events = StreamController<ImageAttachmentUploadEvent>(sync: true);
      addTearDown(events.close);
      final controller = ImageAttachmentUploadController(
        startUpload: (_) => pendingSession.future,
        reportDiagnostic: diagnostics.add,
        queuedWatchdogTimeout: const Duration(seconds: 1),
        createWatchdogTimer: (delay, callback) {
          final timer = _ManualTimer(callback);
          timers.add(timer);
          return timer;
        },
      );
      addTearDown(controller.dispose);

      final starting = controller.startPrepared(_request);
      await pumpEventQueue();
      timers.last.fire();
      timers.last.fire();
      var stalled = diagnostics
          .where(
            (event) => event.checkpoint == AttachmentUploadCheckpoint.stalled,
          )
          .toList();
      expect(stalled, hasLength(1));
      expect(stalled.single.sessionBound, isFalse);
      expect(stalled.single.durablePhase, AttachmentUploadDurablePhase.none);

      pendingSession.complete(
        ImageAttachmentUploadSession(
          events: events.stream,
          cancel: () async {},
        ),
      );
      await starting;
      events.add(
        ImageAttachmentUploadEvent.queued(
          durablePhase: AttachmentJobPhase.localPrepared,
          attemptCount: 2,
          automaticRetryCount: 1,
          retryScheduled: true,
        ),
      );
      timers.last.fire();
      stalled = diagnostics
          .where(
            (event) => event.checkpoint == AttachmentUploadCheckpoint.stalled,
          )
          .toList();
      expect(stalled, hasLength(2));
      expect(stalled.last.sessionBound, isTrue);
      expect(stalled.last.source, AttachmentUploadSource.gallery);
      expect(
        stalled.last.durablePhase,
        AttachmentUploadDurablePhase.localPrepared,
      );
      expect(stalled.last.attemptCount, 2);
      expect(stalled.last.automaticRetryCount, 1);
      expect(stalled.last.retryScheduled, isTrue);

      events.add(
        ImageAttachmentUploadEvent.uploading(
          0.25,
          durablePhase: AttachmentJobPhase.uploading,
        ),
      );
      expect(timers.last.isActive, isFalse);
    },
  );

  // A refused upload has to say WHY it was refused.
  //
  // The first field report of this — a gallery pick that failed instantly on
  // a foldable — reached Sentry as `attachment.failure=dispatch` and stopped
  // there, because every cause was caught with `on Object` and reported as
  // one class. They are not one problem: a room the user may not write to, an
  // account whose server moved, a missing credential and an app that never
  // came back from the picker each need a different fix, and telemetry that
  // cannot tell them apart cannot start any of them.
  const admissionCauses = <AttachmentAdmissionError, AttachmentUploadFailure>{
    AttachmentAdmissionError.roomUnsupported:
        AttachmentUploadFailure.roomUnsupported,
    AttachmentAdmissionError.accountBinding:
        AttachmentUploadFailure.accountBinding,
    AttachmentAdmissionError.accountStale:
        AttachmentUploadFailure.accountBinding,
    AttachmentAdmissionError.credentialMissing:
        AttachmentUploadFailure.credential,
    AttachmentAdmissionError.rejected: AttachmentUploadFailure.admission,
    AttachmentAdmissionError.lifecycleTimeout:
        AttachmentUploadFailure.lifecycleTimeout,
    AttachmentAdmissionError.composerGone: AttachmentUploadFailure.composerGone,
  };

  test('every admission cause is mapped, so none can be added silently', () {
    expect(
      admissionCauses.keys.toSet(),
      AttachmentAdmissionError.values.toSet(),
    );
  });

  for (final entry in admissionCauses.entries) {
    test('a refusal for ${entry.key.name} is reported as itself', () async {
      final diagnostics = <AttachmentUploadDiagnostic>[];
      final controller = ImageAttachmentUploadController(
        startUpload: (_) async => throw AttachmentAdmissionException(entry.key),
        reportDiagnostic: diagnostics.add,
      );
      addTearDown(controller.dispose);

      await controller.startPrepared(_request);

      final failed = diagnostics.singleWhere(
        (event) =>
            event.checkpoint == AttachmentUploadCheckpoint.admissionFailed,
      );
      expect(failed.failure, entry.value);
      expect(
        attachmentUploadDiagnosticTags(failed)['attachment.failure'],
        entry.value.name,
      );
    });
  }

  test(
    'an unmapped cause stays dispatch instead of borrowing a class',
    () async {
      final diagnostics = <AttachmentUploadDiagnostic>[];
      final controller = ImageAttachmentUploadController(
        startUpload: (_) async => throw TimeoutException('something else'),
        reportDiagnostic: diagnostics.add,
      );
      addTearDown(controller.dispose);

      await controller.startPrepared(_request);

      expect(
        diagnostics
            .singleWhere(
              (event) =>
                  event.checkpoint ==
                  AttachmentUploadCheckpoint.admissionFailed,
            )
            .failure,
        AttachmentUploadFailure.dispatch,
      );
    },
  );
}

final class _ManualTimer implements Timer {
  _ManualTimer(this._callback);

  final void Function() _callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() {
    _active = false;
  }

  void fire() {
    if (!_active) {
      return;
    }
    _active = false;
    _callback();
  }
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
  diagnosticSource: AttachmentUploadSource.gallery,
);
