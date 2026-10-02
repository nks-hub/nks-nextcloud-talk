part of 'attachment_service.dart';

Future<void> _runParallelAttachmentRoom(
  _AttachmentServiceRuntime service,
  _AttachmentRoomKey roomKey,
) async {
  const maxConcurrentTransfers = 3;
  final running = <AttachmentPersistenceKey, Future<void>>{};
  final blocked = <AttachmentPersistenceKey>{};
  final stopped = <AttachmentPersistenceKey>{};
  var changed = Completer<void>();
  (Object, StackTrace)? failure;

  void wake() {
    if (!changed.isCompleted) changed.complete();
  }

  void reschedule() {
    blocked.clear();
    stopped.clear();
    wake();
  }

  service._roomWakeups[roomKey] = reschedule;
  try {
    while (!service._closed && failure == null) {
      changed = Completer<void>();
      while (!service._closed &&
          failure == null &&
          running.length < maxConcurrentTransfers) {
        final selection = await service._stateMutex.protect(
          () async => service._selectNextJob(roomKey, {
            ...running.keys,
            ...blocked,
            ...stopped,
          }),
        );
        if (selection == null) break;
        final key = selection.key;
        // A slot owns the job even before its HTTP request is persisted.
        running[key] = service
            ._executeOneStep(selection)
            .then(
              (outcome) {
                running.remove(key);
                service._jobRuns.remove(key);
                switch (outcome) {
                  case _AttachmentStepOutcome.progressed:
                    blocked.clear();
                  case _AttachmentStepOutcome.blocked:
                    blocked.add(key);
                  case _AttachmentStepOutcome.stopped:
                    stopped.add(key);
                    blocked.clear();
                }
                wake();
              },
              onError: (Object error, StackTrace stack) {
                // Drain sibling requests before propagating a scheduler failure.
                failure ??= (error, stack);
                running.remove(key);
                service._jobRuns.remove(key);
                wake();
              },
            );
        service._jobRuns[key] = running[key]!;
      }
      if (failure != null) break;
      if (running.isEmpty) {
        if (changed.isCompleted) continue;
        await service._beforeRoomIdle?.call();
        break;
      }
      await changed.future;
    }
  } finally {
    service._roomWakeups.remove(roomKey);
    await Future.wait(running.values.toList());
  }
  if (failure case (final error, final stack)) {
    Error.throwWithStackTrace(error, stack);
  }
}
