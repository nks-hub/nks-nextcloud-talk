part of 'chat_typing_indicator_test.dart';

/// The wiring between a live HPB socket and the chat database.
///
/// The merge is proven over fixtures elsewhere and the wire shape was
/// measured against a real backend, but neither exercises the part written
/// for this feature: that the room's signalling session is shared rather than
/// re-activated, that trust is established only after the room is confirmed,
/// and that a relayed frame arriving on that session reaches the chat
/// repository. This drives real HPB frames through the real coordinator,
/// provider and service, and asserts the message lands in the database.
void _registerRelayProviderLifecycleTests() {
  test('a relayed frame on the live session reaches the chat database', () async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    final chat = ChatRepository(database);
    final credentials = MemoryCredentialVault();
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {'signaling-v3', 'typing-privacy', 'chat-v2'},
      createdAt: DateTime.utc(2026, 9, 1),
    );
    await chat.recordCapabilities(
      accountId: 'account-a',
      talkFeatures: const {'signaling-v3', 'typing-privacy', 'chat-v2'},
      observedAt: DateTime.utc(2026, 9, 1),
    );
    credentials.values['account-a'] = 'fixture-password';
    await _insertRelayConversation(database);

    final client = _RelayLifecycleClient();
    final api = HttpNextcloudApi(client: client);
    addTearDown(api.close);
    final sockets = _ActiveTypingSockets();
    final coordinator = CallSignalingCoordinator(
      accounts: accounts,
      sessions: CallSessionRepository(database),
      credentials: credentials,
      api: api,
      socketConnector: sockets,
      refreshConversationSession: (_, _) async =>
          ConversationSessionId.parse('active-session'),
    );
    addTearDown(coordinator.dispose);
    final container = ProviderContainer(
      overrides: <Override>[
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(credentials),
        nextcloudApiProvider.overrideWithValue(api),
        callSignalingCoordinatorProvider.overrideWithValue(coordinator),
      ],
    );
    addTearDown(container.dispose);

    const key = (accountId: 'account-a', roomToken: 'rooma123');
    final subscription = container.listen(
      chatRelayProvider(key),
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    // Surfaces a provider failure here instead of as a silent timeout later.
    await container.read(chatRelayProvider(key).future);

    // The HPB handshake, frame for frame. `chat-relay` in the welcome is what
    // opens the gate: without it the update never reports the relay active
    // and the room keeps polling.
    final socket = await sockets.connected.future.timeout(
      const Duration(seconds: 5),
    );
    socket.add(_relayWelcome());
    final hello = jsonDecode(await socket.sent(0)) as Map<String, Object?>;
    expect(
      (hello['hello']! as Map<String, Object?>)['features'],
      contains('chat-relay'),
    );
    await _flushAsync();
    socket.add(_activeHello(hello['id']! as String));
    final room = jsonDecode(await socket.sent(1)) as Map<String, Object?>;
    await _flushAsync();
    socket.add(_activeRoom(room['id']! as String));

    // Trust is earned by the catch-up that follows the room being confirmed,
    // so the relayed message is only merged once that has run.
    await _settleRelay(client);
    socket.add(_relayComment(111));

    final ids = await _relayMessageIds(chat, timeoutMessage: 111);
    expect(ids, contains(111));
    // Exactly one row: the relay is an inlet to the same merge, not a second
    // writer racing the fetch that established trust.
    expect(ids.where((id) => id == 111), hasLength(1));
    // The room was activated once. A second activation would have taken the
    // typing indicator's session id away and killed this very socket.
    expect(
      client.paths.where((path) => path.endsWith('/participants/active')),
      hasLength(1),
    );
  });
}

Future<void> _insertRelayConversation(AppDatabase database) async {
  final roomJson = _activeRoomJson();
  final room = ConversationRoom.fromJson(roomJson);
  await database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: 'account-a',
          token: room.token.value,
          displayName: room.displayName,
          description: room.description,
          lastActivity: room.lastActivity,
          unreadMessages: room.unreadMessages,
          favorite: room.isFavorite,
          readOnly: Value(room.readOnly),
          roomType: Value(room.type),
          roomName: Value(room.name),
          objectType: Value(room.objectType),
          avatarVersion: Value(room.avatarVersion),
          isCustomAvatar: Value(room.isCustomAvatar),
          rawJson: jsonEncode(roomJson),
        ),
      );
}

/// Waits until the trust-establishing catch-up has actually issued its chat
/// read, so a relayed frame after this point lands on a trusted relay.
Future<void> _settleRelay(_RelayLifecycleClient client) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (client.chatReads > 0) {
      await _flushAsync();
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('The relay never ran its catch-up');
}

Future<List<int>> _relayMessageIds(
  ChatRepository chat, {
  required int timeoutMessage,
}) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    final messages = await chat
        .watchMessages(accountId: 'account-a', roomToken: 'rooma123')
        .first;
    final ids = messages
        .map((message) => message.messageId)
        .toList(growable: false);
    if (ids.contains(timeoutMessage)) {
      return ids;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('The relayed message never reached the database');
}

String _relayWelcome() => jsonEncode(<String, Object?>{
  'type': 'welcome',
  'welcome': <String, Object?>{
    'features': <Object?>['hello-v2', 'mcu', 'chat-relay'],
  },
});

String _relayComment(int id) => jsonEncode(<String, Object?>{
  'type': 'event',
  'event': <String, Object?>{
    'target': 'room',
    'type': 'message',
    'message': <String, Object?>{
      'roomid': 'rooma123',
      'data': <String, Object?>{
        'type': 'chat',
        'chat': <String, Object?>{
          'refresh': true,
          'comment': _relayCommentJson(id),
        },
      },
    },
  },
});

Map<String, Object?> _relayCommentJson(int id) => <String, Object?>{
  'id': id,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'user-b',
  'actorDisplayName': 'User B',
  'timestamp': 1770000000 + id,
  'systemMessage': '',
  'messageType': 'comment',
  'isReplyable': true,
  'referenceId': '',
  'message': 'relayed $id',
  // The server sends an empty parameter map as a JSON array.
  'messageParameters': const <Object?>[],
};

/// Signalling and chat in one snapshot: the relay needs both, because the
/// service refuses a room whose capabilities do not admit chat at all.
Map<String, Object?> _relayCapabilitiesJson() => <String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': <String, Object?>{
      'version': <String, Object?>{
        'major': 34,
        'minor': 0,
        'micro': 1,
        'string': '34.0.1',
        'edition': '',
        'extendedSupport': false,
      },
      'capabilities': <String, Object?>{
        'spreed': <String, Object?>{
          'features': <Object?>[
            'signaling-v3',
            'typing-privacy',
            'conversation-v4',
            'chat-v2',
            'chat-reference-id',
          ],
          'config': <String, Object?>{
            'chat': <String, Object?>{'typing-privacy': 0},
          },
          'version': '24.0.2',
        },
      },
    },
  },
};

/// The typing harness' server plus the chat endpoints the relay's catch-up
/// needs. Kept separate so the typing tests keep failing on an unexpected
/// request.
final class _RelayLifecycleClient extends http.BaseClient {
  final List<String> paths = <String>[];
  int chatReads = 0;
  late final Map<String, Object?> _room = _activeRoomJson();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    paths.add(request.url.path);
    if (request.url.path.endsWith('/cloud/capabilities')) {
      return _activeRawResponse(_relayCapabilitiesJson());
    }
    if (request.url.path.endsWith('/participants/active')) {
      if (request.method == 'DELETE') {
        return _activeResponse(null);
      }
      return _activeResponse(_room, cookie: 'nc_session=account-a');
    }
    if (request.url.path.endsWith('/settings')) {
      return _activeResponse(<String, Object?>{
        'signalingMode': 'external',
        'userId': 'fixture-user',
        'hideWarning': true,
        'server': 'https://hpb.example.invalid/signaling',
        'federation': null,
        'stunservers': <Object?>[],
        'turnservers': <Object?>[],
        'sipDialinInfo': '',
        'helloAuthParams': <String, Object?>{
          '2.0': <String, Object?>{'token': 'synthetic-token'},
        },
      });
    }
    if (request.url.path.contains('/chat/')) {
      chatReads++;
      // Nothing new over HTTP: the relay is the only thing delivering here,
      // which is exactly what the test needs to prove.
      return http.StreamedResponse(const Stream.empty(), 304);
    }
    if (request.url.path.endsWith('/participants')) {
      return _activeResponse(const <Object?>[]);
    }
    throw StateError('Unexpected request ${request.url.path}');
  }
}
