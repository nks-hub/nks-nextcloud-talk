part of 'call_signaling_session_test.dart';

void _registerCallSignalingDisposalTests({
  required AccountRepository Function() accounts,
  required CallSessionRepository Function() sessions,
  required MemoryCredentialVault Function() credentials,
}) {
  for (final failFirstBatch in [false, true]) {
    test(
      failFirstBatch
          ? 'dispose drains the remaining signaling lanes after four failures'
          : 'dispose shuts down signaling lanes with bounded concurrency',
      () async {
        const roomTokens = [
          'rooma123',
          'roomb456',
          'roomc789',
          'roomd012',
          'roome345',
          'roomf678',
        ];
        final closeGate = Completer<void>();
        final sockets = _GatedCloseSocketConnector(closeGate.future);
        final api = HttpNextcloudApi(client: _ExternalSettingsClient());
        final coordinator = CallSignalingCoordinator(
          accounts: accounts(),
          sessions: sessions(),
          credentials: credentials(),
          api: api,
          socketConnector: sockets,
          refreshConversationSession: (_, _) async =>
              ConversationSessionId.parse('refreshed-session'),
        );
        Future<Object?>? disposing;
        addTearDown(() async {
          if (!closeGate.isCompleted) closeGate.complete();
          await (disposing ??= coordinator.dispose());
          api.close();
        });

        final closedUpdates = <int>{};
        for (final (index, roomToken) in roomTokens.indexed) {
          final accountId = 'account-$index';
          await _insertAccount(accounts(), credentials(), accountId: accountId);
          final session = await coordinator.start(
            accountId: accountId,
            roomToken: roomToken,
            nextcloudSessionId: 'session-$index',
          );
          await _waitFor(
            session,
            (update) =>
                update.phase == SignalingAccountPhase.hpbAwaitingWelcome,
          );
          final subscription = session.updates.listen(
            (_) {},
            onDone: () => closedUpdates.add(index),
          );
          addTearDown(subscription.cancel);
        }
        expect(sockets.connections, hasLength(6));

        final closeFailure = StateError('socket close rejected');
        if (failFirstBatch) {
          for (final socket in sockets.connections.take(4)) {
            socket.closeFailure = closeFailure;
          }
        }
        disposing = coordinator.dispose().then<Object?>(
          (_) => null,
          onError: (Object error, StackTrace _) => error,
        );
        for (var turn = 0; turn < 50 && sockets.closeStarts < 4; turn++) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(sockets.closeStarts, 4);
        expect(sockets.closeFinishes, 0);

        closeGate.complete();
        expect(await disposing, failFirstBatch ? same(closeFailure) : isNull);
        expect(
          (
            attempted: sockets.closeStarts,
            succeeded: sockets.closeFinishes,
            updateStreams: closedUpdates.length,
          ),
          (attempted: 6, succeeded: failFirstBatch ? 2 : 6, updateStreams: 6),
        );
      },
    );
  }

  test(
    'release keeps the cancellation error and frees the signaling lane',
    () async {
      await _insertAccount(accounts(), credentials(), accountId: 'account-a');
      final sockets = _GatedCloseSocketConnector(Future<void>.value());
      final api = HttpNextcloudApi(client: _ExternalSettingsClient());
      final coordinator = CallSignalingCoordinator(
        accounts: accounts(),
        sessions: sessions(),
        credentials: credentials(),
        api: api,
        socketConnector: sockets,
        refreshConversationSession: (_, _) async =>
            ConversationSessionId.parse('refreshed-session'),
      );
      addTearDown(() async {
        try {
          await coordinator.dispose();
        } finally {
          api.close();
        }
      });

      final original = await coordinator.start(
        accountId: 'account-a',
        roomToken: 'rooma123',
        nextcloudSessionId: 'session-original',
      );
      await _waitFor(
        original,
        (update) => update.phase == SignalingAccountPhase.hpbAwaitingWelcome,
      );
      var updatesClosed = false;
      final subscription = original.updates.listen(
        (_) {},
        onDone: () => updatesClosed = true,
      );
      addTearDown(subscription.cancel);
      final failure = StateError('frame subscription cancel rejected');
      final failureStack = StackTrace.fromString('original frame cancellation');
      sockets.connections.single
        ..cancelFailure = (failure, failureStack)
        ..closeFailure = StateError('socket close rejected after cancellation');

      final outcome = await original
          .release()
          .then<({Object error, StackTrace stack})?>(
            (_) => null,
            onError: (Object error, StackTrace stack) =>
                (error: error, stack: stack),
          );
      expect(outcome?.error, same(failure));
      expect(outcome?.stack.toString(), failureStack.toString());
      expect(
        (socketClose: sockets.closeStarts, updatesClosed: updatesClosed),
        (socketClose: 1, updatesClosed: true),
      );
      expect(
        await sessions().recover(accountId: 'account-a', roomToken: 'rooma123'),
        isNull,
      );

      final replacement = await coordinator.start(
        accountId: 'account-a',
        roomToken: 'rooma123',
        nextcloudSessionId: 'session-replacement',
      );
      expect(identical(original, replacement), isFalse);
      await _waitFor(
        replacement,
        (update) => update.phase == SignalingAccountPhase.hpbAwaitingWelcome,
      );
      expect(sockets.connections, hasLength(2));
    },
  );
}

final class _GatedCloseSocketConnector implements HpbSocketConnector {
  _GatedCloseSocketConnector(this.closeGate);

  final Future<void> closeGate;
  final List<_GatedCloseSocket> connections = [];
  int closeStarts = 0;
  int closeFinishes = 0;

  @override
  Future<HpbSocketConnection> connect(HpbEndpoint endpoint) async {
    final connection = _GatedCloseSocket(this);
    connections.add(connection);
    return connection;
  }
}

final class _GatedCloseSocket implements HpbSocketConnection {
  _GatedCloseSocket(this.owner) {
    _frames.onCancel = () async {
      if (cancelFailure case (final error, final stack)) {
        Error.throwWithStackTrace(error, stack);
      }
    };
  }

  final _GatedCloseSocketConnector owner;
  final StreamController<String> _frames = StreamController();
  (Object, StackTrace)? cancelFailure;
  Object? closeFailure;

  @override
  Stream<String> get frames => _frames.stream;

  @override
  Future<void> send(String frame) async {}

  @override
  Future<void> close(HpbCloseReason reason) async {
    owner.closeStarts++;
    await owner.closeGate;
    await _frames.close();
    if (closeFailure case final error?) throw error;
    owner.closeFinishes++;
  }
}
