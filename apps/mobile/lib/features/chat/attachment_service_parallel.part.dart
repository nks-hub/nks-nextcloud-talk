part of 'attachment_service.dart';

Future<void> _runParallelAttachmentRoom(
  _AttachmentServiceRuntime service,
  _AttachmentRoomKey roomKey,
) async {
  const maxConcurrentTransfers = 3;
  final steps = service._steps;
  final running = <AttachmentPersistenceKey, Future<void>>{};
  final blocked = <AttachmentPersistenceKey>{};
  final stopped = <AttachmentPersistenceKey>{};
  var changed = Completer<void>();
  (Object, StackTrace)? failure;

  bool canRun() =>
      !service._closed &&
      !service._suspendedAccounts.contains(roomKey.accountId) &&
      failure == null;

  void wake() {
    if (!changed.isCompleted) changed.complete();
  }

  void reschedule() {
    blocked.clear();
    stopped.clear();
    wake();
  }

  void completeStep(AttachmentPersistenceKey key) {
    running.remove(key);
    steps.complete(key);
    wake();
  }

  service._roomWakeups[roomKey] = reschedule;
  try {
    while (canRun()) {
      changed = Completer<void>();
      while (canRun() && running.length < maxConcurrentTransfers) {
        final selection = await service._stateMutex.protect(
          () async => service._selectNextJob(roomKey, {
            ...running.keys,
            ...blocked,
            ...stopped,
          }),
        );
        if (!canRun()) break;
        if (selection == null) {
          steps.withdraw(roomKey);
          break;
        }
        final key = selection.key;
        final step = steps.tryStart(
          selection,
          wake,
          () => service
              ._executeOneStep(selection)
              .then(
                (outcome) {
                  // Anything but a clean step re-reads the account next time.
                  if (outcome != _AttachmentStepOutcome.progressed) {
                    service._heldAuthorizations.remove(key);
                  }
                  switch (outcome) {
                    case _AttachmentStepOutcome.progressed:
                      blocked.clear();
                    case _AttachmentStepOutcome.blocked:
                      blocked.add(key);
                    case _AttachmentStepOutcome.stopped:
                      stopped.add(key);
                      blocked.clear();
                  }
                  completeStep(key);
                },
                onError: (Object error, StackTrace stack) {
                  // Drain sibling requests before propagating a scheduler failure.
                  failure ??= (error, stack);
                  service._heldAuthorizations.remove(key);
                  completeStep(key);
                },
              ),
        );
        if (step == null) break;
        running[key] = step;
      }
      if (!canRun()) break;
      if (running.isEmpty && !steps.isWaiting(roomKey)) {
        if (changed.isCompleted) continue;
        await service._beforeRoomIdle?.call();
        break;
      }
      await changed.future;
    }
  } finally {
    steps.withdraw(roomKey);
    // No credential outlives the run that read it.
    service._heldAuthorizations.removeWhere(
      (key, _) => key.accountId == roomKey.accountId.value,
    );
    service._roomWakeups.remove(roomKey);
    await Future.wait(running.values.toList());
  }
  if (failure case (final error, final stack)) {
    Error.throwWithStackTrace(error, stack);
  }
}

final class _AttachmentStepQueue {
  // One room can use three slots, leaving one for another room.
  static const _capacity = 4;
  final _running = <AttachmentPersistenceKey, Future<void>>{};
  final _waiting = <_AttachmentRoomKey, void Function()>{};

  Future<void>? tryStart(
    _SelectedAttachmentJob selection,
    void Function() wake,
    Future<void> Function() run,
  ) {
    final room = selection.roomKey;
    final first = _waiting.keys.firstOrNull;
    if (_running.length >= _capacity || (first != null && first != room)) {
      _waiting[room] = wake;
      return null;
    }
    _waiting.remove(room);
    // A slot owns the job even before its HTTP request is persisted.
    final step = _running[selection.key] = run();
    _wakeNext();
    return step;
  }

  Future<void>? running(AttachmentPersistenceKey key) => _running[key];

  void complete(AttachmentPersistenceKey key) {
    _running.remove(key);
    _wakeNext();
  }

  bool isWaiting(_AttachmentRoomKey room) => _waiting.containsKey(room);

  void withdraw(_AttachmentRoomKey room) {
    if (_waiting.remove(room) != null) _wakeNext();
  }

  void cancelWaiters([AccountId? accountId]) {
    _waiting.removeWhere((room, wake) {
      if (accountId != null && room.accountId != accountId) return false;
      wake();
      return true;
    });
    _wakeNext();
  }

  void _wakeNext() {
    if (_running.length < _capacity) _waiting.values.firstOrNull?.call();
  }
}

Future<void> _releaseVerifiedAttachmentSources(
  _AttachmentServiceRuntime service,
) async {
  final sources = service._verifiedSources.values.toList(growable: false);
  var nextSource = 0;

  Future<void> releaseNext() async {
    while (nextSource < sources.length) {
      final source = sources[nextSource++];
      try {
        await service._transport.releaseSource(source);
      } on AttachmentTransportException {
        // The durable source itself remains owned by the persisted job.
      }
    }
  }

  final workerCount = sources.length < _sourceReleaseConcurrency
      ? sources.length
      : _sourceReleaseConcurrency;
  await Future.wait(List.generate(workerCount, (_) => releaseNext()));
  service._verifiedSources.clear();
}
