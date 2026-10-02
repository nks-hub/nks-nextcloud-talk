import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import 'attachment_service.dart';
import 'media/attachment_source_thumbnail.dart';

class PendingAttachmentBatch {
  PendingAttachmentBatch(this.key, this.jobs);

  final String key;
  final List<StoredAttachmentJob> jobs;

  int get completed => jobs.where((job) => job.phase == 'completed').length;
  int get total => jobs.where((job) => job.phase != 'cancelled').length;
  bool get hasFailure => jobs.any(attachmentJobNeedsAttention);
  bool get isSending => jobs.any(
    (job) =>
        !attachmentJobNeedsAttention(job) &&
        job.phase != 'completed' &&
        job.phase != 'cancelled',
  );
  bool get confirming => jobs
      .where((job) => job.phase != 'completed' && job.phase != 'cancelled')
      .every(
        (job) =>
            job.phase == 'awaitingConfirmation' || job.phase == 'finalizing',
      );

  Set<int> get confirmedMessageIds => {
    for (final job in jobs.where((job) => job.phase == 'completed'))
      ...(jsonDecode(job.messageIdsJson) as List).cast<int>(),
  };
}

List<PendingAttachmentBatch> pendingAttachmentBatches(
  List<StoredAttachmentJob> jobs, {
  required String serverUrl,
}) {
  final groups = <String, List<StoredAttachmentJob>>{};
  for (final job in jobs) {
    if (job.serverUrl != serverUrl) continue;
    final album = ChatPhotoAlbumReference.tryParse(job.referenceId);
    final key = album == null
        ? job.jobId
        : '${album.albumId}:${job.replyTo}:${job.threadId}';
    groups.putIfAbsent(key, () => []).add(job);
  }
  return [
    for (final entry in groups.entries)
      if (entry.value.any(
        (job) => job.phase != 'completed' && job.phase != 'cancelled',
      ))
        PendingAttachmentBatch(entry.key, entry.value),
  ];
}

bool attachmentJobNeedsAttention(StoredAttachmentJob job) =>
    job.phase == 'failed' ||
    job.phase == 'cleanupFailed' ||
    job.phase == 'retryable' && job.nextAttemptAtMillis == null ||
    job.phase == 'awaitingConfirmation' &&
        job.errorClass == attachmentConfirmationReconciliationRequired;

bool attachmentJobCanRetry(StoredAttachmentJob job) =>
    job.phase == 'retryable' ||
    job.phase == 'cleanupFailed' ||
    job.phase == 'awaitingConfirmation' &&
        job.errorClass == attachmentConfirmationReconciliationRequired;

bool attachmentJobCanCancel(StoredAttachmentJob job) =>
    !job.finalizationDispatched &&
    !const {
      'completed',
      'cancelled',
      'cancelling',
      'finalizing',
      'awaitingConfirmation',
    }.contains(job.phase);

PreparedAttachmentSource _source(StoredAttachmentJob job) =>
    PreparedAttachmentSource(
      handle: AttachmentSourceHandle.parse(job.sourceHandle),
      ownership: AttachmentSourceOwnership.values.byName(job.sourceOwnership),
      byteLength: job.sourceByteLength,
      sha256: AttachmentSha256.parse(job.sourceSha256),
      mimeType: job.sourceMimeType,
      displayName: job.sourceDisplayName,
    );

class PendingAttachmentBubble extends ConsumerStatefulWidget {
  const PendingAttachmentBubble({
    super.key,
    required this.batch,
    this.confirmedContent,
    this.highlighted = false,
  });

  final PendingAttachmentBatch batch;
  final Widget? confirmedContent;
  final bool highlighted;

  @override
  ConsumerState<PendingAttachmentBubble> createState() =>
      _PendingAttachmentBubbleState();
}

class _PendingAttachmentBubbleState
    extends ConsumerState<PendingAttachmentBubble> {
  bool _busy = false;
  bool _actionFailed = false;

  Future<void> _act({required bool retry, StoredAttachmentJob? only}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _actionFailed = false;
    });
    try {
      final service = await ref.read(attachmentServiceProvider.future);
      final operations = <Future<void>>[];
      for (final job in only == null ? widget.batch.jobs : [only]) {
        final account = AccountId.parse(job.accountId);
        final id = AttachmentJobId.parse(job.jobId);
        if (retry && attachmentJobCanRetry(job)) {
          operations.add(service.retry(accountId: account, jobId: id));
        } else if (!retry && attachmentJobCanCancel(job)) {
          operations.add(
            job.phase == 'failed'
                ? service.discardFailed(accountId: account, jobId: id)
                : service.cancel(accountId: account, jobId: id),
          );
        }
      }
      if (retry) {
        // Retry returns after the room drains; cancellation must stay usable.
        unawaited(
          Future.wait(operations).then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) {
              if (mounted) setState(() => _actionFailed = true);
            },
          ),
        );
      } else {
        await Future.wait(operations);
      }
    } on Object {
      // A concurrent finalization may revoke cancellation after the tap.
      if (mounted) setState(() => _actionFailed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final batch = widget.batch;
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final jobs = batch.jobs.where((job) => job.phase != 'cancelled').toList();
    final previews = jobs
        .where((job) => job.phase != 'completed')
        .take(4)
        .toList();
    final sourceStore = ref.watch(attachmentSourceProvider).asData?.value;
    final title = jobs.length == 1
        ? jobs.first.sourceDisplayName
        : strings.attachmentBatchTitle(batch.total);
    final status = batch.hasFailure
        ? strings.imageUploadFailed
        : batch.confirming
        ? strings.confirmingAttachment
        : strings.attachmentBatchSending;
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: Container(
        key: ValueKey('pending-attachment-${batch.key}'),
        constraints: const BoxConstraints(maxWidth: 360),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(18),
          border: widget.highlighted
              ? Border.all(color: scheme.primary, width: 2)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  jobs.every((job) => job.sourceMimeType.startsWith('image/'))
                      ? Icons.photo_library_outlined
                      : Icons.attach_file_rounded,
                  color: scheme.onPrimaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (batch.isSending)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (widget.confirmedContent != null) ...[
              widget.confirmedContent!,
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                for (final job in previews) ...[
                  Expanded(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (!job.sourceReleased && sourceStore != null)
                            AttachmentSourceThumbnail(
                              source: _source(job),
                              store: sourceStore,
                            )
                          else
                            Center(
                              child: Icon(
                                job.phase == 'completed'
                                    ? Icons.check_circle_outline
                                    : Icons.image_outlined,
                                color: scheme.onPrimaryContainer,
                              ),
                            ),
                          if (attachmentJobNeedsAttention(job))
                            Align(
                              alignment: Alignment.bottomRight,
                              child: Icon(
                                Icons.error_outline,
                                color: scheme.error,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (job != previews.last) const SizedBox(width: 4),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Semantics(
              liveRegion: true,
              child: Text(
                strings.attachmentBatchProgress(batch.completed, batch.total),
                style: TextStyle(color: scheme.onPrimaryContainer),
              ),
            ),
            Text(
              status,
              style: TextStyle(
                color: batch.hasFailure
                    ? scheme.error
                    : scheme.onPrimaryContainer,
              ),
            ),
            if (_actionFailed)
              Text(
                strings.attachmentActionFailed,
                style: TextStyle(color: scheme.error),
              ),
            Material(
              type: MaterialType.transparency,
              child: ExpansionTile(
                key: const Key('pending-attachment-details'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Text(
                  strings.attachmentBatchDetails,
                  style: TextStyle(color: scheme.onPrimaryContainer),
                ),
                children: [
                  for (final job in jobs)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        job.sourceDisplayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(_jobStatus(strings, job)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (attachmentJobCanRetry(job))
                            IconButton(
                              key: ValueKey('retry-attachment-${job.jobId}'),
                              tooltip: strings.retry,
                              onPressed: _busy
                                  ? null
                                  : () =>
                                        unawaited(_act(retry: true, only: job)),
                              icon: const Icon(Icons.refresh_rounded),
                            ),
                          if (attachmentJobCanCancel(job))
                            IconButton(
                              key: ValueKey('cancel-attachment-${job.jobId}'),
                              tooltip: strings.cancel,
                              onPressed: _busy
                                  ? null
                                  : () => unawaited(
                                      _act(retry: false, only: job),
                                    ),
                              icon: const Icon(Icons.close_rounded),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                if (jobs.any(attachmentJobCanRetry))
                  TextButton.icon(
                    key: const Key('retry-pending-attachments'),
                    onPressed: _busy
                        ? null
                        : () => unawaited(_act(retry: true)),
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(strings.retry),
                  ),
                if (jobs.any(attachmentJobCanCancel))
                  TextButton(
                    key: const Key('cancel-pending-attachments'),
                    onPressed: _busy
                        ? null
                        : () => unawaited(_act(retry: false)),
                    child: Text(strings.cancel),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _jobStatus(AppLocalizations strings, StoredAttachmentJob job) {
  if (attachmentJobNeedsAttention(job)) {
    return switch (job.errorClass) {
      'dav-quota-exceeded' ||
      'draft-quota-exceeded' => strings.imageUploadFailedQuota,
      'dav-permission-denied' => strings.imageUploadFailedPermission,
      _ => strings.imageUploadFailed,
    };
  }
  return switch (job.phase) {
    'completed' => strings.imageSent,
    'awaitingConfirmation' || 'finalizing' => strings.confirmingAttachment,
    'cancelling' => strings.cancellingUpload,
    'localPrepared' || 'retryable' => strings.imageUploadQueued,
    _ => strings.attachmentBatchSending,
  };
}
