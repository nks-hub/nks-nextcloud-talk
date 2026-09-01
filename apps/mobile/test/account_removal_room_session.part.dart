part of 'account_removal_service_test.dart';

void _registerAccountRemovalRoomSessionTests({
  required AppDatabase Function() database,
  required AccountRepository Function() accounts,
  required MemoryCredentialVault Function() vault,
  required AccountRemovalService Function(
    HttpNextcloudApi api,
    AccountRemovalStarted onRemovalStarted,
  )
  buildService,
}) {
  test('removal tombstones a held room activation before revocation', () async {
    final scopedDatabase = database();
    final scopedAccounts = accounts();
    final scopedVault = vault();
    await _seedAccount(
      scopedDatabase,
      scopedAccounts,
      scopedVault,
      'account-a',
      _serverA,
    );
    await _seedAccount(
      scopedDatabase,
      scopedAccounts,
      scopedVault,
      'account-b',
      _serverB,
      talkFeatures: const <String>{'signaling-v3'},
    );
    final activeStarted = Completer<void>();
    final releaseActive = Completer<void>();
    final removalStarted = Completer<void>();
    final cookies = <String?>[];
    var activeDeletes = 0;
    var lateAccountARequests = 0;
    final roomA = _removalActiveRoom('rooma123', 'active-a');
    final roomB = _removalActiveRoom('roomb456', 'active-b');
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/participants/active')) {
          final accountA = request.url.host == Uri.parse(_serverA).host;
          if (request.method == 'DELETE') {
            if (accountA) {
              activeDeletes++;
              cookies.add(request.headers['Cookie']);
            }
            return http.Response(_okOcs(), 200);
          }
          if (accountA) {
            activeStarted.complete();
            await releaseActive.future;
          }
          return _removalActiveRoomResponse(
            accountA ? roomA : roomB,
            accountA ? 'session-a' : 'session-b',
          );
        }
        if (request.url.path.endsWith('/signaling/settings')) {
          if (request.url.host == Uri.parse(_serverA).host) {
            lateAccountARequests++;
          }
          cookies.add(request.headers['Cookie']);
          return http.Response(
            jsonEncode(<String, Object?>{
              'ocs': <String, Object?>{
                'meta': <String, Object?>{
                  'status': 'ok',
                  'statuscode': 200,
                  'message': 'OK',
                },
                'data': _removalExternalSettings(),
              },
            }),
            200,
          );
        }
        return http.Response(_okOcs(), 200);
      }),
    );
    addTearDown(api.close);
    final sockets = _RemovalSocketConnector();
    final coordinator = CallSignalingCoordinator(
      accounts: scopedAccounts,
      sessions: CallSessionRepository(scopedDatabase),
      credentials: scopedVault,
      api: api,
      socketConnector: sockets,
      refreshConversationSession: (_, _) async => null,
    );
    addTearDown(coordinator.dispose);
    final activationB = await api.activateRoomSession(
      activeRequest: _removalActiveRequest('account-b', _serverB, 'roomb456'),
      loginName: 'account-b-user',
      appPassword: 'fixture-password',
    );
    final laneB = await coordinator.start(
      accountId: 'account-b',
      roomToken: 'roomb456',
      nextcloudSessionId: 'active-b',
    );
    final socketB = await sockets.connected.future.timeout(
      const Duration(seconds: 5),
    );
    final activationA = api.activateRoomSession(
      activeRequest: _removalActiveRequest('account-a', _serverA, 'rooma123'),
      loginName: 'account-a-user',
      appPassword: 'fixture-password',
    );
    await activeStarted.future;
    final removal = buildService(api, (accountId) async {
      removalStarted.complete();
      await coordinator.shutdownAccount(accountId);
    }).removeAccount('account-a');
    await removalStarted.future;
    await Future<void>.delayed(Duration.zero);
    releaseActive.complete();

    await expectLater(
      activationA,
      throwsA(
        isA<NextcloudApiException>().having(
          (error) => error.code,
          'code',
          NextcloudApiError.cancelled,
        ),
      ),
    );
    await removal;
    await api.getSignalingSettings(
      settingsRequest: _removalSettingsRequest(
        'account-b',
        _serverB,
        'roomb456',
      ),
      loginName: 'account-b-user',
      appPassword: 'fixture-password',
    );
    await expectLater(
      coordinator.start(
        accountId: 'account-a',
        roomToken: 'rooma123',
        nextcloudSessionId: 'late-session-a',
      ),
      throwsA(
        isA<CallSignalingStartException>().having(
          (error) => error.code,
          'code',
          CallSignalingStartError.suspended,
        ),
      ),
    );

    expect(activeDeletes, 1);
    expect(cookies, contains('nc_session=session-a'));
    expect(cookies.last, 'nc_session=session-b');
    expect(lateAccountARequests, 0);
    expect(await scopedAccounts.getAccount('account-a'), isNull);
    expect(await scopedAccounts.getAccount('account-b'), isNotNull);
    expect(activationB.lease, isNotNull);
    expect(sockets.connectCount, 1);
    expect(socketB.closed, isFalse);
    expect(laneB.key.accountId, 'account-b');
    final storedSessions = await scopedDatabase
        .select(scopedDatabase.callSessions)
        .get();
    expect(storedSessions, hasLength(1));
    expect(storedSessions.single.accountId, 'account-b');
  });
}

Map<String, Object?> _removalActiveRoom(String token, String sessionId) {
  final fixture =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = fixture['ocs']! as Map<String, Object?>;
  final room = Map<String, Object?>.from(
    (ocs['data']! as List<Object?>).first! as Map<String, Object?>,
  );
  final lastMessage = Map<String, Object?>.from(
    room['lastMessage']! as Map<String, Object?>,
  )..['token'] = token;
  return room
    ..['token'] = token
    ..['sessionId'] = sessionId
    ..['lastMessage'] = lastMessage;
}

http.Response _removalActiveRoomResponse(
  Map<String, Object?> room,
  String session,
) => http.Response(
  jsonEncode(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': room,
    },
  }),
  200,
  headers: <String, String>{
    'content-type': 'application/json',
    'set-cookie': 'nc_session=$session; Path=/',
  },
);

ActiveRoomSessionRequest _removalActiveRequest(
  String accountId,
  String server,
  String token,
) => ActiveRoomSessionRequest(
  accountId: AccountId.parse(accountId),
  server: ServerBase.parse(server),
  roomToken: ConversationToken.parse(token, path: r'$.roomToken'),
);

SignalingSettingsRequest _removalSettingsRequest(
  String accountId,
  String server,
  String token,
) => SignalingSettingsRequest(
  context: SignalingRequestContext(
    accountId: AccountId.parse(accountId),
    requestId: SignalingRequestId.parse('request-$accountId'),
    server: ServerBase.parse(server),
    roomToken: ConversationToken.parse(token, path: r'$.roomToken'),
    credentialGeneration: 1,
    capabilityGeneration: 1,
    settingsRevision: 'revision-$accountId',
    connectionEpoch: 1,
    roomEpoch: 1,
  ),
);

Map<String, Object?> _removalExternalSettings() => <String, Object?>{
  'signalingMode': 'external',
  'userId': 'fixture-user',
  'hideWarning': true,
  'server': 'https://hpb.example.invalid/signaling',
  'federation': null,
  'stunservers': <Object?>[],
  'turnservers': <Object?>[],
  'sipDialinInfo': '',
  'helloAuthParams': <String, Object?>{
    '1.0': <String, Object?>{
      'userid': 'fixture-user',
      'ticket': 'synthetic-ticket',
    },
    '2.0': <String, Object?>{'token': 'synthetic-token'},
  },
};

final class _RemovalSocketConnector implements HpbSocketConnector {
  final Completer<_RemovalSocket> connected = Completer<_RemovalSocket>();
  int connectCount = 0;

  @override
  Future<HpbSocketConnection> connect(HpbEndpoint endpoint) async {
    connectCount++;
    final socket = _RemovalSocket();
    if (!connected.isCompleted) connected.complete(socket);
    return socket;
  }
}

final class _RemovalSocket implements HpbSocketConnection {
  final StreamController<String> _frames = StreamController<String>();
  bool closed = false;

  @override
  Stream<String> get frames => _frames.stream;

  @override
  Future<void> send(String frame) async {}

  @override
  Future<void> close(HpbCloseReason reason) async {
    closed = true;
    await _frames.close();
  }
}
