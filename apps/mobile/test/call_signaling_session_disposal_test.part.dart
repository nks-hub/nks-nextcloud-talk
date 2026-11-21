part of 'call_signaling_session_test.dart';

void _registerCallSignalingDisposalTests({
  required AccountRepository Function() accounts,
  required CallSessionRepository Function() sessions,
  required MemoryCredentialVault Function() credentials,
}) {
  test('dispose shuts down signaling lanes with bounded concurrency', () async {
    const accountIds = [
      'account-a',
      'account-b',
      'account-c',
      'account-d',
      'account-e',
      'account-f',
    ];
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
    Future<void>? disposing;
    addTearDown(() async {
      if (!closeGate.isCompleted) closeGate.complete();
      await (disposing ??= coordinator.dispose());
      api.close();
    });

    for (var index = 0; index < accountIds.length; index++) {
      await _insertAccount(
        accounts(),
        credentials(),
        accountId: accountIds[index],
      );
      final session = await coordinator.start(
        accountId: accountIds[index],
        roomToken: roomTokens[index],
        nextcloudSessionId: 'session-$index',
      );
      await _waitFor(
        session,
        (update) => update.phase == SignalingAccountPhase.hpbAwaitingWelcome,
      );
    }
    expect(sockets.connections, hasLength(6));

    disposing = coordinator.dispose();
    for (var turn = 0; turn < 50 && sockets.closeStarts < 4; turn++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(sockets.closeStarts, 4);
    expect(sockets.closeFinishes, 0);

    closeGate.complete();
    await disposing;
    expect(sockets.closeStarts, 6);
    expect(sockets.closeFinishes, 6);
  });
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
  _GatedCloseSocket(this.owner);

  final _GatedCloseSocketConnector owner;
  final StreamController<String> _frames = StreamController.broadcast();

  @override
  Stream<String> get frames => _frames.stream;

  @override
  Future<void> send(String frame) async {}

  @override
  Future<void> close(HpbCloseReason reason) async {
    owner.closeStarts++;
    await owner.closeGate;
    owner.closeFinishes++;
    await _frames.close();
  }
}
