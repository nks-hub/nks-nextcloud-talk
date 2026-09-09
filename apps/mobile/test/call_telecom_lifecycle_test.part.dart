part of 'call_lifecycle_service_test.dart';

void _registerCallTelecomLifecycleTests() {
  test('a joined call is one call in the system, ended once', () async {
    final telecom = _RecordingTelecom();
    final fixture = await _ForegroundJoinFixture.create(
      _ForegroundCalls(),
      _CameraForegroundEngine(),
      holdSettings: true,
      telecom: telecom,
    );
    addTearDown(fixture.close);

    await fixture.controller.join();
    expect(telecom.outgoing, [_ForegroundJoinFixture.key.roomToken]);
    expect(telecom.open, {'telecom-1'});

    await fixture.controller.leave();
    expect(telecom.endedCalls, ['telecom-1']);
    expect(telecom.open, isEmpty);
  });

  test('a device without Telecom joins and leaves the same call', () async {
    // The fallback that must never be optional: nothing is registered, and
    // the call is exactly the call it was before Telecom existed.
    final telecom = _RecordingTelecom(refuse: true);
    final fixture = await _ForegroundJoinFixture.create(
      _ForegroundCalls(),
      _CameraForegroundEngine(),
      holdSettings: true,
      telecom: telecom,
    );
    addTearDown(fixture.close);

    await fixture.controller.join();
    expect(
      fixture.container
          .read(callJoinControllerProvider(_ForegroundJoinFixture.key))
          .phase,
      CallJoinPhase.joined,
    );
    expect(telecom.outgoing, hasLength(1));
    expect(telecom.open, isEmpty);

    await fixture.controller.leave();
    // Nothing was registered, so nothing is taken down: an end for a call the
    // system never had would be a platform round trip for no reason.
    expect(telecom.endedCalls, isEmpty);
    expect(
      fixture.container
          .read(callJoinControllerProvider(_ForegroundJoinFixture.key))
          .phase,
      CallJoinPhase.idle,
    );
  });

  test('a failing Telecom cannot fail the call it was told about', () async {
    final telecom = _RecordingTelecom(fail: true);
    final fixture = await _ForegroundJoinFixture.create(
      _ForegroundCalls(),
      _CameraForegroundEngine(),
      holdSettings: true,
      telecom: telecom,
    );
    addTearDown(fixture.close);

    await fixture.controller.join();
    expect(
      fixture.container
          .read(callJoinControllerProvider(_ForegroundJoinFixture.key))
          .phase,
      CallJoinPhase.joined,
    );
    await fixture.controller.leave();
  });

  test('the system hanging up leaves the call on the server', () async {
    final telecom = _RecordingTelecom();
    final fixture = await _ForegroundJoinFixture.create(
      _ForegroundCalls(),
      _CameraForegroundEngine(),
      holdSettings: true,
      telecom: telecom,
    );
    addTearDown(fixture.close);
    final binding = Provider<void>(
      (ref) => bindSystemCallActions(ref, telecom),
    );
    fixture.container.read(binding);

    await fixture.controller.join();
    telecom.hangUp();
    await pumpEventQueue();

    expect(
      fixture.container
          .read(callJoinControllerProvider(_ForegroundJoinFixture.key))
          .phase,
      CallJoinPhase.idle,
    );
    expect(fixture.rest.server.callMethods.where((m) => m != 'GET'), [
      'POST',
      'DELETE',
    ]);
  });

  test('a call abandoned by its media takes the system call with it', () async {
    final telecom = _RecordingTelecom();
    final fixture = await _ForegroundJoinFixture.create(
      _ForegroundCalls(),
      _DelayedMicrophone(() async {}),
      telecom: telecom,
    );
    addTearDown(fixture.close);

    await fixture.controller.join();
    await pumpEventQueue();

    // The microphone was refused, so whatever the system was told about this
    // call has been taken down again: a failed call leaves nothing behind.
    expect(telecom.open, isEmpty);
    expect(telecom.endedCalls, hasLength(telecom.outgoing.length));
  });
}

final class _RecordingTelecom implements CallTelecom {
  _RecordingTelecom({this.refuse = false, this.fail = false});

  final bool refuse;
  final bool fail;
  final outgoing = <String>[];
  final incoming = <String>[];
  final endedCalls = <String>[];
  final open = <String>{};
  final _ended = StreamController<CallTelecomCall?>.broadcast();
  CallTelecomCall? _last;
  int _ids = 0;

  /// The user pressed hang up in the system's own call UI, or on a headset.
  void hangUp() {
    final call = _last;
    _last = null;
    if (call != null) {
      open.remove(call.callId);
      _ended.add(call);
    }
  }

  @override
  Stream<CallTelecomCall> get answered => const Stream.empty();

  @override
  Stream<CallTelecomCall?> get ended => _ended.stream;

  @override
  Future<bool> supported() async => !refuse;

  @override
  Future<CallTelecomCall?> startOutgoing({
    required String accountId,
    required String roomToken,
  }) async {
    outgoing.add(roomToken);
    return _place(accountId, roomToken);
  }

  @override
  Future<CallTelecomCall?> reportIncoming({
    required String accountId,
    required String roomToken,
  }) async {
    incoming.add(roomToken);
    return _place(accountId, roomToken);
  }

  CallTelecomCall? _place(String accountId, String roomToken) {
    if (fail) {
      throw StateError('synthetic Telecom failure');
    }
    if (refuse) {
      return null;
    }
    final call = CallTelecomCall(
      accountId: accountId,
      roomToken: roomToken,
      callId: 'telecom-${++_ids}',
    );
    open.add(call.callId);
    _last = call;
    return call;
  }

  @override
  Future<void> endCall(String callId) async {
    endedCalls.add(callId);
    open.remove(callId);
    if (_last?.callId == callId) _last = null;
  }
}
