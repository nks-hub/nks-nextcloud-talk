part of 'call_lifecycle_service_test.dart';

void _registerCallLifecycleStaleSessionTests() {
  test(
    'a pre-refresh response cannot overwrite the renewed session cookie',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      var activations = 0;
      final harness = await _CallHarness.create(
        onActiveRoom: (request, _) async {
          if (request.method == 'DELETE') return _ocsResponse(200, null);
          activations++;
          return _activeRoomResponse(
            'rooma123',
            'active-$activations',
            cookie: 'nc_session=cookie-$activations; Path=/',
          );
        },
        onCall: (request, index) async {
          if (request.method == 'GET' && index == 1) {
            started.complete();
            await release.future;
            return http.Response(
              _ocsBody(200, <Object?>[]),
              200,
              headers: {'set-cookie': 'nc_session=obsolete; Path=/'},
            );
          }
          return _ocsResponse(
            200,
            request.method == 'GET' ? <Object?>[] : <String, Object?>{},
          );
        },
      );
      addTearDown(harness.dispose);
      final chat = await _holdChatRoom(harness);
      final joined = await harness.service.join(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      final request = CallPeersRequest(
        context: CallRequestContext(
          authority: joined.authority,
          mutationSequence: 0,
        ),
      );
      final pending = harness.api.getCallPeers(
        peersRequest: request,
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      );
      final rejected = expectLater(
        pending,
        throwsA(
          isA<NextcloudApiException>().having(
            (e) => e.code,
            'code',
            NextcloudApiError.cancelled,
          ),
        ),
      );
      await started.future;
      await harness.api.refreshRoomSession(
        lease: chat.lease!,
        rejectedSessionId: joined.authority.nextcloudSessionId,
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      );
      release.complete();
      await rejected;
      await harness.api.getCallPeers(
        peersRequest: request,
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      );
      expect(
        harness.server.callRequests.last.headers['Cookie'],
        'nc_session=cookie-2',
      );
    },
  );

  test(
    'concurrent reports of the same missing session refresh only once',
    () async {
      var activations = 0;
      final harness = await _CallHarness.create(
        onActiveRoom: (request, _) async {
          if (request.method == 'DELETE') return _ocsResponse(200, null);
          return _activeRoomResponse('rooma123', 'active-${++activations}');
        },
      );
      addTearDown(harness.dispose);
      final chat = await _holdChatRoom(harness);
      final results = await Future.wait(
        List.generate(
          2,
          (_) => harness.api.refreshRoomSession(
            lease: chat.lease!,
            rejectedSessionId: ConversationSessionId.parse('active-1'),
            loginName: 'fixture-user',
            appPassword: 'fixture-password',
          ),
        ),
      );
      expect(activations, 2);
      for (final result in results) {
        expect(
          (result.response as ActiveRoomSessionSuccess).room.sessionId.value,
          'active-2',
        );
        expect(identical(result.lease, chat.lease), isTrue);
      }
      await harness.api.deactivateRoomSession(
        lease: chat.lease!,
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      );
      expect(harness.server.requestSequence, [
        'active POST',
        'active POST',
        'active DELETE',
      ]);
    },
  );

  test('a late 404 cannot refresh the lease of a different room', () async {
    final harness = await _CallHarness.create();
    addTearDown(harness.dispose);
    final old = await _holdChatRoom(harness);
    final current = await _holdChatRoom(harness, token: 'roomb123');
    final before = harness.server.requestSequence.toList();
    await expectLater(
      harness.api.refreshRoomSession(
        lease: old.lease!,
        rejectedSessionId: ConversationSessionId.parse('session-rooma123'),
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      ),
      throwsA(
        isA<NextcloudApiException>().having(
          (e) => e.code,
          'code',
          NextcloudApiError.cancelled,
        ),
      ),
    );
    expect(harness.server.requestSequence, before);
    await harness.api.deactivateRoomSession(
      lease: current.lease!,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    expect(
      harness.server.activeRoomRequests.last.url.path,
      contains('/roomb123/'),
    );
  });

  test(
    'account shutdown during rejected-session refresh prevents the retry',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      var activations = 0;
      final harness = await _CallHarness.create(
        onActiveRoom: (request, _) async {
          if (request.method == 'DELETE') return _ocsResponse(200, null);
          if (++activations == 2) {
            started.complete();
            await release.future;
          }
          return _activeRoomResponse('rooma123', 'active-$activations');
        },
        onCall: (_, _) async => _ocsResponse(404, <String, Object?>{}),
      );
      addTearDown(harness.dispose);
      final joined = harness.service.join(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      final rejected = expectLater(
        joined,
        _lifecycleFailure(CallLifecycleError.network),
      );
      await started.future;
      final shutdown = harness.api.shutdownAccountSession(
        accountId: 'account-a',
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      );
      release.complete();
      await rejected;
      await shutdown;
      expect(harness.server.callMethods, ['POST']);
      expect(harness.server.requestSequence.last, 'active DELETE');
    },
  );

  test(
    'a definitive missing call session renews the shared room once',
    () async {
      var activations = 0;
      final harness = await _CallHarness.create(
        onActiveRoom: (request, _) async {
          if (request.method == 'DELETE') return _ocsResponse(200, null);
          activations++;
          return _activeRoomResponse(
            'rooma123',
            'active-$activations',
            cookie: 'nc_session=cookie-$activations; Path=/; HttpOnly',
          );
        },
        onCall: (request, index) async {
          if (index == 0) return _ocsResponse(404, <String, Object?>{});
          expect(request.headers['Cookie'], 'nc_session=cookie-2');
          return _ocsResponse(200, <String, Object?>{});
        },
      );
      addTearDown(harness.dispose);
      final chat = await harness.api.activateRoomSession(
        activeRequest: ActiveRoomSessionRequest(
          accountId: AccountId.parse('account-a'),
          server: ServerBase.parse('https://cloud.example.invalid/nextcloud'),
          roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
        ),
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      );

      final joined = await harness.service.join(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      expect(joined.authority.nextcloudSessionId.value, 'active-2');
      expect(harness.server.requestSequence, [
        'active POST',
        'call POST',
        'active POST',
        'call POST',
      ]);
      await harness.service.leave(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      expect(harness.server.requestSequence.last, 'call DELETE');
      await harness.api.deactivateRoomSession(
        lease: chat.lease!,
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      );
      expect(harness.server.requestSequence.last, 'active DELETE');
      expect(
        harness.server.activeRoomRequests.where((r) => r.method == 'DELETE'),
        hasLength(1),
      );
    },
  );

  test(
    'a persistent call 404 does not create an unbounded retry loop',
    () async {
      final harness = await _CallHarness.create(
        onCall: (_, _) async => _ocsResponse(404, <String, Object?>{}),
      );
      addTearDown(harness.dispose);
      await expectLater(
        harness.service.join(accountId: 'account-a', roomToken: 'rooma123'),
        _lifecycleFailure(CallLifecycleError.roomMissing),
      );
      expect(harness.server.callMethods, ['POST', 'POST']);
      expect(harness.server.requestSequence, [
        'active POST',
        'call POST',
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
    },
  );
}

Future<ActiveRoomSessionActivation> _holdChatRoom(
  _CallHarness harness, {
  String token = 'rooma123',
}) => harness.api.activateRoomSession(
  activeRequest: ActiveRoomSessionRequest(
    accountId: AccountId.parse('account-a'),
    server: ServerBase.parse('https://cloud.example.invalid/nextcloud'),
    roomToken: ConversationToken.parse(token, path: r'$.roomToken'),
  ),
  loginName: 'fixture-user',
  appPassword: 'fixture-password',
);
