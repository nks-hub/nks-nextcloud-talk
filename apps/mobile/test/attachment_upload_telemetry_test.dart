import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/attachment_upload_telemetry.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('stalled upload event contains only allowlisted diagnostics', () {
    const diagnostic = AttachmentUploadDiagnostic(
      checkpoint: AttachmentUploadCheckpoint.stalled,
      source: AttachmentUploadSource.gallery,
      uiPhase: AttachmentUploadUiPhase.queued,
      durablePhase: AttachmentUploadDurablePhase.localPrepared,
      resumePhase: AttachmentUploadDurablePhase.uploading,
      failure: AttachmentUploadFailure.unknown,
      progress: AttachmentUploadProgressBucket.zero,
      sessionBound: true,
      retryScheduled: true,
      attemptCount: 7,
      automaticRetryCount: 5,
      credentialRetryCount: 2,
      elapsed: Duration(minutes: 3),
      retryDelay: Duration(seconds: 10),
    );

    final event = buildAttachmentUploadSentryEvent(diagnostic);
    expect(event.request, isNull);
    expect(event.user, isNull);
    expect(event.breadcrumbs, isEmpty);
    expect(event.message?.formatted, 'attachment-upload-stalled');
    final tags = Map<String, String>.of(event.tags!);
    expect(
      tags.remove('attachment.lifecycle'),
      isIn(<String>[
        'unknown',
        'resumed',
        'inactive',
        'hidden',
        'paused',
        'detached',
      ]),
    );
    expect(tags.remove('attachment.platform'), isNotEmpty);
    expect(tags, <String, String>{
      'attachment.checkpoint': 'stalled',
      'attachment.source': 'gallery',
      'attachment.ui_phase': 'queued',
      'attachment.durable_phase': 'localPrepared',
      'attachment.resume_phase': 'uploading',
      'attachment.failure': 'unknown',
      'attachment.progress': 'zero',
      'attachment.session_bound': 'true',
      'attachment.retry_scheduled': 'true',
      'attachment.attempts': '4+',
      'attachment.automatic_retries': '4+',
      'attachment.credential_retries': '2',
      'attachment.elapsed': '2m+',
      'attachment.retry_delay': '10-30s',
    });
    expect(event.exceptions, isNull);
  });

  test(
    'disabled Sentry drops upload diagnostics before creating work',
    () async {
      expect(Sentry.isEnabled, isFalse);
      final previous = Sentry.lastEventId;

      reportAttachmentUploadDiagnostic(
        const AttachmentUploadDiagnostic(
          checkpoint: AttachmentUploadCheckpoint.stalled,
          source: AttachmentUploadSource.gallery,
          uiPhase: AttachmentUploadUiPhase.queued,
        ),
      );
      await pumpEventQueue();

      expect(Sentry.lastEventId, previous);
    },
  );
}
