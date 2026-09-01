import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

enum AttachmentUploadCheckpoint {
  pickerPresented,
  pickerReturned,
  pickerCancelled,
  pickerFailed,
  prefixRead,
  durableCopyStarted,
  durableCopyCompleted,
  durableCopyFailed,
  admissionStarted,
  admissionCompleted,
  admissionFailed,
  durableProgress,
  durableFailed,
  streamFailed,
  stalled,
  completed,
  cancelled,
}

enum AttachmentUploadSource { unknown, gallery, camera, file, image, contact }

enum AttachmentUploadUiPhase {
  none,
  preparing,
  queued,
  uploading,
  awaitingConfirmation,
  cancelling,
  completed,
  failed,
  cancelled,
}

enum AttachmentUploadDurablePhase {
  none,
  localPrepared,
  probing,
  draftResolved,
  uploading,
  uploaded,
  finalizing,
  awaitingConfirmation,
  retryable,
  cleanupFailed,
  cancelling,
  completed,
  failed,
  cancelled,
}

enum AttachmentUploadFailure {
  none,
  permission,
  unavailable,
  invalidSelection,
  sourceRead,
  sourceCopy,
  admission,
  dispatch,
  stream,
  durable,
  confirmation,
  unknown,
}

enum AttachmentUploadProgressBucket { none, zero, partial, complete }

final class AttachmentUploadDiagnostic {
  const AttachmentUploadDiagnostic({
    required this.checkpoint,
    this.source = AttachmentUploadSource.unknown,
    this.uiPhase = AttachmentUploadUiPhase.none,
    this.durablePhase = AttachmentUploadDurablePhase.none,
    this.resumePhase = AttachmentUploadDurablePhase.none,
    this.failure = AttachmentUploadFailure.none,
    this.progress = AttachmentUploadProgressBucket.none,
    this.sessionBound = false,
    this.retryScheduled = false,
    this.attemptCount = 0,
    this.automaticRetryCount = 0,
    this.elapsed = Duration.zero,
  });

  final AttachmentUploadCheckpoint checkpoint;
  final AttachmentUploadSource source;
  final AttachmentUploadUiPhase uiPhase;
  final AttachmentUploadDurablePhase durablePhase;
  final AttachmentUploadDurablePhase resumePhase;
  final AttachmentUploadFailure failure;
  final AttachmentUploadProgressBucket progress;
  final bool sessionBound;
  final bool retryScheduled;
  final int attemptCount;
  final int automaticRetryCount;
  final Duration elapsed;

  bool get capturesEvent => switch (checkpoint) {
    AttachmentUploadCheckpoint.pickerFailed ||
    AttachmentUploadCheckpoint.durableCopyFailed ||
    AttachmentUploadCheckpoint.admissionFailed ||
    AttachmentUploadCheckpoint.durableFailed ||
    AttachmentUploadCheckpoint.streamFailed ||
    AttachmentUploadCheckpoint.stalled => true,
    _ => false,
  };
}

typedef ReportAttachmentUploadDiagnostic =
    void Function(AttachmentUploadDiagnostic diagnostic);

void reportAttachmentUploadDiagnostic(AttachmentUploadDiagnostic diagnostic) {
  if (!Sentry.isEnabled) {
    return;
  }
  final tags = attachmentUploadDiagnosticTags(diagnostic);
  unawaited(
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: 'attachment-upload-${diagnostic.checkpoint.name}',
        category: 'attachment.upload',
        level: diagnostic.capturesEvent
            ? SentryLevel.warning
            : SentryLevel.info,
        data: <String, Object?>{...tags},
      ),
    ),
  );
  if (!diagnostic.capturesEvent) {
    return;
  }
  unawaited(
    Sentry.captureEvent(
      buildAttachmentUploadSentryEvent(diagnostic),
      withScope: (scope) async {
        await scope.clear();
      },
    ),
  );
}

@visibleForTesting
SentryEvent buildAttachmentUploadSentryEvent(
  AttachmentUploadDiagnostic diagnostic,
) {
  final tags = attachmentUploadDiagnosticTags(diagnostic);
  return SentryEvent(
    message: SentryMessage('attachment-upload-${diagnostic.checkpoint.name}'),
    logger: 'attachment.upload',
    level: SentryLevel.warning,
    tags: tags,
    fingerprint: <String>[
      'attachment-upload',
      diagnostic.checkpoint.name,
      diagnostic.uiPhase.name,
      diagnostic.durablePhase.name,
      diagnostic.resumePhase.name,
      diagnostic.failure.name,
    ],
    breadcrumbs: const <Breadcrumb>[],
    request: null,
    user: null,
  );
}

@visibleForTesting
Map<String, String> attachmentUploadDiagnosticTags(
  AttachmentUploadDiagnostic diagnostic,
) => <String, String>{
  'attachment.checkpoint': diagnostic.checkpoint.name,
  'attachment.source': diagnostic.source.name,
  'attachment.ui_phase': diagnostic.uiPhase.name,
  'attachment.durable_phase': diagnostic.durablePhase.name,
  'attachment.resume_phase': diagnostic.resumePhase.name,
  'attachment.failure': diagnostic.failure.name,
  'attachment.progress': diagnostic.progress.name,
  'attachment.session_bound': diagnostic.sessionBound.toString(),
  'attachment.retry_scheduled': diagnostic.retryScheduled.toString(),
  'attachment.attempts': _countBucket(diagnostic.attemptCount),
  'attachment.automatic_retries': _countBucket(diagnostic.automaticRetryCount),
  'attachment.elapsed': _elapsedBucket(diagnostic.elapsed),
  'attachment.lifecycle': _lifecycleName(),
  'attachment.platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
};

String _lifecycleName() {
  try {
    return WidgetsBinding.instance.lifecycleState?.name ?? 'unknown';
  } on FlutterError {
    return 'unknown';
  }
}

String _countBucket(int value) => switch (value) {
  <= 0 => '0',
  1 => '1',
  2 => '2',
  3 => '3',
  _ => '4+',
};

String _elapsedBucket(Duration elapsed) => switch (elapsed) {
  < const Duration(seconds: 10) => '<10s',
  < const Duration(seconds: 30) => '10-30s',
  < const Duration(minutes: 1) => '30-60s',
  < const Duration(minutes: 2) => '1-2m',
  _ => '2m+',
};
