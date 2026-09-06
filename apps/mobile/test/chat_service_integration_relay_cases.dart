part of 'chat_service_integration_test.dart';

/// The HPB chat relay as the chat sync engine's second inlet.
///
/// What matters is not that a relayed message arrives — it is that having two
/// transports for one room cannot lose a message or store it twice, and that
/// handing delivery back and forth leaves the room's chat blocks contiguous.
extension _ChatServiceRelayCases on _ChatServiceIntegrationSuite {
  void registerRelayCases() {
    test('long poll, relay and long poll again deliver every message '
        'exactly once', () async {
      final server = _RelayFakeServer(<int>[110]);
      final api = HttpNextcloudApi(client: MockClient(server.handle));
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );

      // 1. HTTP only. This is what every server without an external HPB does
      //    and it has to keep behaving exactly like this.
      await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
      expect(await _messageIds(), <int>[110]);

      // 2. The signalling session confirms the room, so the relay starts
      //    listening; trust is earned by the catch-up that follows.
      final relay = service.bindRelay(
        accountId: 'account-a',
        roomToken: 'rooma123',
      )..activate(1);
      await _settle();
      expect(relay.isTrusted, isTrue);

      // 3. The relay delivers. Nothing is fetched: the payload itself is the
      //    message, and that is the point of the second transport.
      final requestsBeforeRelay = server.futureRequests;
      server.messages.addAll(<int>[111, 112]);
      relay
        ..receive(1, _relayChat(<int>[111]))
        ..receive(1, _relayChat(<int>[112]));
      await _settle();
      expect(await _messageIds(), <int>[110, 111, 112]);
      expect(server.futureRequests, requestsBeforeRelay);

      // 4. The relay repeats itself, as it does after a resume. The message
      //    id deduplicates; nothing is stored twice.
      relay.receive(1, _relayChat(<int>[112]));
      await _settle();
      expect(await _messageIds(), <int>[110, 111, 112]);

      // 5. The socket dies. 113 is created while nothing is listening and
      //    the relay never sees it — the case that would lose a message if
      //    the relay were a second writer instead of a second inlet.
      relay.deactivate();
      server.messages.addAll(<int>[113, 114]);
      await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');

      expect(await _messageIds(), <int>[110, 111, 112, 113, 114]);
      final scope = await chat.getRootScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      final blocks = (jsonDecode(scope!.blocksJson) as List<Object?>)
          .cast<Object?>();
      // One block: no handover left a hole behind.
      expect(blocks, hasLength(1));
      expect(scope.futureCursor, '114');
    });

    test('a relayed message for another room writes nothing', () async {
      final server = _RelayFakeServer(<int>[110]);
      final api = HttpNextcloudApi(client: MockClient(server.handle));
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
      final relay = service.bindRelay(
        accountId: 'account-a',
        roomToken: 'rooma123',
      )..activate(1);
      await _settle();
      final requestsBefore = server.futureRequests;

      relay.receive(1, _relayChat(<int>[999], roomToken: 'roomb999'));
      await _settle();

      expect(await _messageIds(), <int>[110]);
      expect(
        await chat
            .watchMessages(accountId: 'account-a', roomToken: 'roomb999')
            .first,
        isEmpty,
      );
      // A payload that cannot be merged hands the room back to HTTP rather
      // than leaving the relay claiming a stream it was never proven on.
      // The relay may go on to earn trust again from that fetch; what must
      // not happen is trusting it across a payload it could not merge.
      expect(server.futureRequests, greaterThan(requestsBefore));
    });

    test('a relayed message on a stale room epoch is ignored', () async {
      final server = _RelayFakeServer(<int>[110]);
      final api = HttpNextcloudApi(client: MockClient(server.handle));
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
      final relay = service.bindRelay(
        accountId: 'account-a',
        roomToken: 'rooma123',
      )..activate(1);
      await _settle();

      // A new HPB session moved the epoch on. Anything still arriving for
      // the old one belongs to a stream whose contiguity was never proven.
      relay.activate(2);
      relay.receive(1, _relayChat(<int>[111]));
      await _settle();

      expect(await _messageIds(), <int>[110]);
    });

    test('a bare refresh fetches instead of guessing', () async {
      final server = _RelayFakeServer(<int>[110]);
      final api = HttpNextcloudApi(client: MockClient(server.handle));
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
      final relay = service.bindRelay(
        accountId: 'account-a',
        roomToken: 'rooma123',
      )..activate(1);
      await _settle();

      // The server relays a bare refresh when a message is not visible to
      // this participant. It says the room changed without saying how.
      server.messages.add(111);
      relay.receive(1, <String, Object?>{'refresh': true});
      await _settle();

      expect(await _messageIds(), <int>[110, 111]);
      expect(relay.isTrusted, isTrue);
    });

    test('a relayed attachment is fetched, not believed', () async {
      // The relay renders a file the way the SHARE sees it, so the path it
      // carries is not where the file is in the user's tree. A row written from
      // it is never read again — the poll skips ids it already knows — so the
      // wrong path is permanent and every download of that attachment is a 404.
      // Measured on a Galaxy S9+ on 6 September 2026; see the relay's own
      // comment for what was checked against the live server.
      final server = _RelayFakeServer(<int>[110]);
      final api = HttpNextcloudApi(client: MockClient(server.handle));
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
      final relay = service.bindRelay(
        accountId: 'account-a',
        roomToken: 'rooma123',
      )..activate(1);
      await _settle();
      final before = server.futureRequests;

      server.messages.add(111);
      server.fileMessages.add(111);
      relay.receive(1, <String, Object?>{
        'comments': <Object?>[_relayComment(111, filePath: _relayFilePath)],
      });
      await _settle();

      expect(await _messageIds(), <int>[110, 111]);
      expect(
        server.futureRequests,
        greaterThan(before),
        reason: 'an attachment has to be read from the chat endpoint',
      );
      expect(
        await _filePathOf(111),
        _servedFilePath,
        reason: "the stored path must be the server's, not the relay's",
      );
      expect(relay.isTrusted, isTrue);
    });

    test('a suspended account stops accepting relayed messages', () async {
      final server = _RelayFakeServer(<int>[110]);
      final api = HttpNextcloudApi(client: MockClient(server.handle));
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
      final relay = service.bindRelay(
        accountId: 'account-a',
        roomToken: 'rooma123',
      )..activate(1);
      await _settle();

      await service.suspendAccount('account-a');
      server.messages.add(111);
      relay.receive(1, _relayChat(<int>[111]));
      await _settle();

      expect(await _messageIds(), <int>[110]);
    });
  }

  /// The file path as it was actually stored, read out of the cached wire.
  Future<String?> _filePathOf(int messageId) async {
    final messages = await chat
        .watchMessages(accountId: 'account-a', roomToken: 'rooma123')
        .first;
    for (final message in messages) {
      if (message.messageId == messageId) {
        final wire = jsonDecode(message.rawJson) as Map<String, Object?>;
        final parameters = wire['messageParameters'] as Map<String, Object?>?;
        final file = parameters?['file'] as Map<String, Object?>?;
        return file?['path'] as String?;
      }
    }
    return null;
  }

  Future<List<int>> _messageIds() async {
    final messages = await chat
        .watchMessages(accountId: 'account-a', roomToken: 'rooma123')
        .first;
    return messages.map((message) => message.messageId).toList(growable: false);
  }
}

/// Lets every queued relay merge and its follow-up fetch run to completion.
Future<void> _settle() async {
  for (var pass = 0; pass < 20; pass++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Map<String, Object?> _relayChat(
  List<int> ids, {
  String roomToken = 'rooma123',
}) => <String, Object?>{
  'refresh': true,
  'comments': ids
      .map((id) => _relayComment(id, roomToken: roomToken))
      .toList(growable: false),
};

Map<String, Object?> _relayComment(
  int id, {
  String roomToken = 'rooma123',
  String? filePath,
}) => <String, Object?>{
  'id': id,
  'token': roomToken,
  'actorType': 'users',
  'actorId': 'user-b',
  'actorDisplayName': 'User B',
  'timestamp': 1770000000 + id,
  'systemMessage': '',
  'messageType': 'comment',
  'isReplyable': true,
  'referenceId': '',
  'message': filePath == null ? 'message $id' : '{file}',
  'messageParameters': filePath == null
      ? <String, Object?>{}
      : <String, Object?>{
          'file': <String, Object?>{
            'type': 'file',
            'id': '$id',
            'name': 'voice-message.m4a',
            'path': filePath,
            'mimetype': 'audio/mp4',
          },
        },
};

/// The path the relay would put in a file parameter: relative to the share,
/// which is not where the file is in the user's own tree.
const String _relayFilePath = 'voice-message.m4a';

/// The path every chat read gives for the same file.
const String _servedFilePath =
    'Talk/room-rooma123/user-b/voice-message.m4a';

/// A chat endpoint that answers from a mutable message list, so a test can
/// decide which messages the HTTP transport can see and which ones only the
/// relay delivered.
final class _RelayFakeServer {
  _RelayFakeServer(List<int> messages) : messages = <int>[...messages];

  final List<int> messages;

  /// Ids the endpoint answers with a file rich object, always carrying the
  /// path as the user's own tree has it.
  final Set<int> fileMessages = <int>{};

  int futureRequests = 0;

  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.endsWith('/cloud/capabilities')) {
      return http.Response(jsonEncode(_chatCapabilities()), 200);
    }
    final query = request.url.queryParameters;
    final anchor = int.parse(query['lastKnownMessageId'] ?? '0');
    final sorted = messages.toList()..sort();
    if (query['lookIntoFuture'] == '0') {
      // The oldest page, and there is nothing before it.
      if (anchor != 0) {
        return http.Response('', 304);
      }
      return _page(sorted, cursor: sorted.first);
    }
    futureRequests++;
    final fresh = sorted.where((id) => id > anchor).toList(growable: false);
    if (fresh.isEmpty) {
      return http.Response('', 304);
    }
    return _page(fresh, cursor: fresh.last);
  }

  http.Response _page(List<int> ids, {required int cursor}) => http.Response(
    jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': 'ok',
          'statuscode': 200,
          'message': 'OK',
        },
        'data': ids
            .map(
              (id) => _relayComment(
                id,
                filePath: fileMessages.contains(id) ? _servedFilePath : null,
              ),
            )
            .toList(growable: false),
      },
    }),
    200,
    headers: <String, String>{'X-Chat-Last-Given': '$cursor'},
  );
}
