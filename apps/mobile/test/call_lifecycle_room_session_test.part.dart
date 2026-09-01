part of 'call_lifecycle_service_test.dart';

void _registerCallLifecycleRoomSessionTests() {
  test(
    'join activates session zero and sends its cookie before call POST',
    () async {
      final harness = await _CallHarness.create(
        refresh: (_, _) async => ConversationSessionId.parse('0'),
      );
      addTearDown(harness.dispose);
      await harness.seedRoom(token: 'rooma123', sessionId: '0');

      final joined = await harness.service.join(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );

      expect(joined.authority.nextcloudSessionId.value, 'session-rooma123');
      expect(harness.server.requestSequence, <String>[
        'active POST',
        'call POST',
      ]);
      expect(
        harness.server.callRequests.single.headers['Cookie'],
        'nc_session=call-session',
      );
    },
  );

  test('leave releases the call-owned room session', () async {
    final harness = await _CallHarness.create();
    addTearDown(harness.dispose);
    await harness.service.join(accountId: 'account-a', roomToken: 'rooma123');

    await harness.service.leave(accountId: 'account-a', roomToken: 'rooma123');

    expect(harness.server.requestSequence, <String>[
      'active POST',
      'call POST',
      'call DELETE',
      'active DELETE',
    ]);
  });

  test('call 401 purges state and releases the active session', () async {
    final harness = await _CallHarness.create(
      onCall: (_, _) async => _ocsResponse(401, <String, Object?>{}),
    );
    addTearDown(harness.dispose);

    await expectLater(
      harness.service.join(accountId: 'account-a', roomToken: 'rooma123'),
      _lifecycleFailure(CallLifecycleError.reauthenticationRequired),
    );

    expect(harness.server.requestSequence, <String>[
      'active POST',
      'call POST',
      'active DELETE',
    ]);
    expect(
      await harness.database
          .select(harness.database.callLifecycleSessions)
          .get(),
      isEmpty,
    );
  });

  test(
    'invalid activation is bounded by DELETE and never reaches call REST',
    () async {
      final harness = await _CallHarness.create(
        onActiveRoom: (request, _) async => request.method == 'POST'
            ? http.Response(
                '{"ocs":{"meta":{"status":"ok","statuscode":200},'
                '"data":{"sessionId":"broken"}}}',
                200,
                headers: const <String, String>{
                  'set-cookie': 'nc_session=broken; Path=/',
                },
              )
            : _ocsResponse(200, null),
      );
      addTearDown(harness.dispose);

      await expectLater(
        harness.service.join(accountId: 'account-a', roomToken: 'rooma123'),
        _lifecycleFailure(CallLifecycleError.invalidResponse),
      );

      expect(harness.server.requestSequence, <String>[
        'active POST',
        'active DELETE',
      ]);
      expect(harness.server.callRequests, isEmpty);
    },
  );

  test('invalid call GET releases the active room session', () async {
    final harness = await _CallHarness.create(
      onCall: (_, _) async => _ocsResponse(200, <String, Object?>{}),
    );
    addTearDown(harness.dispose);

    await expectLater(
      harness.service.status(accountId: 'account-a', roomToken: 'rooma123'),
      _lifecycleFailure(CallLifecycleError.invalidResponse),
    );

    expect(harness.server.requestSequence, <String>[
      'active POST',
      'call GET',
      'active DELETE',
    ]);
  });

  test('call session cookies remain isolated across accounts', () async {
    final callCookies = <String, String?>{};
    final accountA =
        'Basic ${base64Encode(utf8.encode('fixture-user:fixture-password'))}';
    final harness = await _CallHarness.create(
      onActiveRoom: (request, _) async {
        if (request.method == 'DELETE') return _ocsResponse(200, null);
        final account = request.headers['Authorization'] == accountA
            ? 'a'
            : 'b';
        final token = request
            .url
            .pathSegments[request.url.pathSegments.indexOf('room') + 1];
        return _activeRoomResponse(
          token,
          'session-$token',
          cookie: 'nc_session=session-$account; Path=/; HttpOnly',
        );
      },
      onCall: (request, _) async {
        final account = request.headers['Authorization'] == accountA
            ? 'a'
            : 'b';
        callCookies[account] = request.headers['Cookie'];
        return _ocsResponse(200, <String, Object?>{});
      },
    );
    addTearDown(harness.dispose);
    await harness.accounts.upsertAccount(
      accountId: 'account-b',
      serverUrl: 'https://cloud.example.invalid/nextcloud',
      loginName: 'fixture-user-b',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 8, 26),
    );
    harness.credentials.values['account-b'] = 'fixture-password-b';
    await harness.seedRoom(token: 'roomb123', accountId: 'account-b');

    await Future.wait(<Future<CallLifecycleState>>[
      harness.service.join(accountId: 'account-a', roomToken: 'rooma123'),
      harness.service.join(accountId: 'account-b', roomToken: 'roomb123'),
    ]);

    expect(callCookies['a'], 'nc_session=session-a');
    expect(callCookies['b'], 'nc_session=session-b');
  });

  test(
    'ambiguous session-zero join recovers by GET without another POST',
    () async {
      final harness = await _CallHarness.create(
        refresh: (_, _) async => ConversationSessionId.parse('0'),
        onCall: (request, index) async {
          if (index == 0) {
            throw http.ClientException('synthetic disconnect');
          }
          expect(request.method, 'GET');
          return _ocsResponse(200, <Object?>[
            _peer(token: 'rooma123', sessionId: 'session-rooma123'),
          ]);
        },
      );
      addTearDown(harness.dispose);
      await harness.seedRoom(token: 'rooma123', sessionId: '0');

      await expectLater(
        harness.service.join(accountId: 'account-a', roomToken: 'rooma123'),
        _lifecycleFailure(CallLifecycleError.uncertain),
      );
      final recovered = await harness.service.join(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );

      expect(recovered.phase, CallLifecyclePhase.joined);
      expect(harness.server.callMethods, <String>['POST', 'GET']);
    },
  );

  test('changed activation keeps an ambiguous join guarded', () async {
    var activation = 0;
    final harness = await _CallHarness.create(
      refresh: (_, _) async => ConversationSessionId.parse('0'),
      onActiveRoom: (request, _) async {
        if (request.method == 'DELETE') return _ocsResponse(200, null);
        activation++;
        return _activeRoomResponse('rooma123', 'active-$activation');
      },
      onCall: (_, _) async =>
          throw http.ClientException('synthetic disconnect'),
    );
    addTearDown(harness.dispose);
    await harness.seedRoom(token: 'rooma123', sessionId: '0');

    await expectLater(
      harness.service.join(accountId: 'account-a', roomToken: 'rooma123'),
      _lifecycleFailure(CallLifecycleError.uncertain),
    );
    await expectLater(
      harness.service.join(accountId: 'account-a', roomToken: 'rooma123'),
      _lifecycleFailure(CallLifecycleError.uncertain),
    );

    expect(harness.server.callMethods, <String>['POST']);
    final guarded = await harness.database
        .select(harness.database.callLifecycleSessions)
        .getSingle();
    expect(guarded.phase, CallLifecyclePhase.uncertainJoin.name);
    expect(guarded.nextcloudSessionId, 'active-1');
  });

  test('room preflight failure keeps another room session active', () async {
    final harness = await _CallHarness.create(
      onCall: (request, _) async => request.method == 'GET'
          ? _ocsResponse(200, <Object?>[
              _peer(token: 'rooma123', sessionId: 'session-rooma123'),
            ])
          : _ocsResponse(200, <String, Object?>{}),
    );
    addTearDown(harness.dispose);
    await harness.seedRoom(token: 'roomb123', permissions: 0);
    await harness.service.join(accountId: 'account-a', roomToken: 'rooma123');

    await expectLater(
      harness.service.join(accountId: 'account-a', roomToken: 'roomb123'),
      _lifecycleFailure(CallLifecycleError.forbidden),
    );
    await harness.service.status(accountId: 'account-a', roomToken: 'rooma123');

    expect(harness.server.requestSequence, <String>[
      'active POST',
      'call POST',
      'call GET',
    ]);
    expect(
      harness.server.callRequests.last.headers['Cookie'],
      'nc_session=call-session',
    );
  });

  test('account removal cancels activation before call REST', () async {
    final activeStarted = Completer<void>();
    final releaseActive = Completer<void>();
    final harness = await _CallHarness.create(
      onActiveRoom: (request, _) async {
        if (request.method == 'DELETE') return _ocsResponse(200, null);
        activeStarted.complete();
        await releaseActive.future;
        return _activeRoomResponse('rooma123', 'session-rooma123');
      },
    );
    addTearDown(harness.dispose);

    final joining = harness.service.join(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    await activeStarted.future;
    final removal = harness.api.shutdownAccountSession(
      accountId: 'account-a',
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    releaseActive.complete();

    await expectLater(joining, _lifecycleFailure(CallLifecycleError.network));
    await removal;
    expect(harness.server.callRequests, isEmpty);
    expect(harness.server.requestSequence, <String>[
      'active POST',
      'active DELETE',
    ]);
  });

  test('account removal invalidates an in-flight call POST', () async {
    final callStarted = Completer<void>();
    final releaseCall = Completer<void>();
    final harness = await _CallHarness.create(
      onCall: (_, _) async {
        callStarted.complete();
        await releaseCall.future;
        return _ocsResponse(200, <String, Object?>{});
      },
    );
    addTearDown(harness.dispose);

    final joining = harness.service.join(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    await callStarted.future;
    final removal = harness.api.shutdownAccountSession(
      accountId: 'account-a',
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    releaseCall.complete();

    await expectLater(joining, _lifecycleFailure(CallLifecycleError.uncertain));
    await removal;
    expect(harness.server.requestSequence, <String>[
      'active POST',
      'call POST',
      'active DELETE',
    ]);
    expect(harness.server.callMethods, <String>['POST']);
  });

  test('dispose releases the held session once', () async {
    final harness = await _CallHarness.create();
    await harness.service.join(accountId: 'account-a', roomToken: 'rooma123');

    await harness.service.dispose();
    await harness.service.dispose();

    expect(harness.server.requestSequence, <String>[
      'active POST',
      'call POST',
      'active DELETE',
    ]);
    await harness.dispose();
  });
}
