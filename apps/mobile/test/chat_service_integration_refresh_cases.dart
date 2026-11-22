part of 'chat_service_integration_test.dart';

extension _ChatRefreshCases on _ChatServiceIntegrationSuite {
  void registerRefreshCases() {
    test(
      're-reading one message repairs the path an attachment kept',
      () async {
        // The HPB relay rendered a file the way the SHARE sees it, so every
        // message an older build cached from the relay names a path the server
        // answers with 404 — and nothing re-reads a message the cache has.
        Map<String, Object?> fileMessage(String path) => <String, Object?>{
          'id': 140,
          'token': 'rooma123',
          'actorType': 'users',
          'actorId': 'fixture-user',
          'actorDisplayName': 'Fixture User',
          'timestamp': 1770000140,
          'systemMessage': '',
          'messageType': 'comment',
          'isReplyable': true,
          'referenceId': '',
          'message': '{file}',
          'messageParameters': <String, Object?>{
            'file': <String, Object?>{
              'type': 'file',
              'id': '4711',
              'name': 'voice-message.wav',
              'path': path,
              'mimetype': 'audio/wav',
            },
          },
          'markdown': true,
          'reactions': <String, Object?>{},
        };
        final cached = fileMessage('voice-message.wav');
        await database
            .into(database.cachedChatMessages)
            .insert(
              CachedChatMessagesCompanion.insert(
                accountId: 'account-a',
                roomToken: 'rooma123',
                messageId: 140,
                actorType: 'users',
                actorId: 'fixture-user',
                actorDisplayName: 'Fixture User',
                timestamp: 1770000140,
                systemMessage: '',
                messageType: 'comment',
                referenceId: '',
                displayText: 'voice-message.wav',
                deleted: false,
                rawJson: jsonEncode(cached),
              ),
            );
        Map<String, String>? asked;
        final api = HttpNextcloudApi(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              return http.Response(jsonEncode(_chatCapabilities()), 200);
            }
            asked = request.url.queryParameters;
            return http.Response(
              jsonEncode(<String, Object?>{
                'ocs': <String, Object?>{
                  'meta': <String, Object?>{
                    'status': 'ok',
                    'statuscode': 200,
                    'message': 'OK',
                  },
                  'data': <Object?>[fileMessage('Talk/room/voice-message.wav')],
                },
              }),
              200,
              headers: const <String, String>{
                'X-Chat-Last-Given': '140',
                'X-Chat-Last-Common-Read': '0',
              },
            );
          }),
        );
        addTearDown(api.close);
        final service = ChatService(
          accounts: accounts,
          chat: chat,
          credentials: credentials,
          api: api,
        );

        final reader = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        addTearDown(reader.close);
        final repaired = await service.refreshMessage(
          accountId: 'account-a',
          roomToken: 'rooma123',
          messageId: 140,
        );

        expect(repaired, isTrue);
        // Exactly one message, and the one asked for: a page would move the
        // room's cursors, which this must not do.
        expect(asked?['limit'], '1');
        expect(asked?['lastKnownMessageId'], '140');
        expect(asked?['includeLastKnown'], '1');
        expect(asked?['lookIntoFuture'], '0');
        final row = await chat.getMessage(
          accountId: 'account-a',
          roomToken: 'rooma123',
          messageId: 140,
        );
        final stored = ChatMessage.fromJson(jsonDecode(row!.rawJson));
        expect(
          stored.messageParameters['file']?.wire['path'],
          'Talk/room/voice-message.wav',
        );
      },
    );

    test(
      'a message the server no longer returns leaves its row alone',
      () async {
        final api = HttpNextcloudApi(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              return http.Response(jsonEncode(_chatCapabilities()), 200);
            }
            return http.Response(
              jsonEncode(
                readFixtureJson(
                  'chat-messages/fixtures/chat-empty.response.json',
                ),
              ),
              200,
              headers: const <String, String>{
                'X-Chat-Last-Given': '141',
                'X-Chat-Last-Common-Read': '0',
              },
            );
          }),
        );
        addTearDown(api.close);
        final service = ChatService(
          accounts: accounts,
          chat: chat,
          credentials: credentials,
          api: api,
        );

        final reader = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        addTearDown(reader.close);
        expect(
          await service.refreshMessage(
            accountId: 'account-a',
            roomToken: 'rooma123',
            messageId: 141,
          ),
          isFalse,
        );
      },
    );

    test('a re-read that brings nothing new writes nothing', () async {
      final wire = _refreshWire(text: 'Unchanged');
      await _insertRefreshRow(database, wire);
      final api = _refreshServer(() async => wire);
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      final reader = service.bindLiveRoom(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      addTearDown(reader.close);
      var writes = 0;
      final watch = database
          .tableUpdates(TableUpdateQuery.onTable(database.cachedChatMessages))
          .listen((_) => writes++);
      addTearDown(watch.cancel);

      final refreshed = await service.refreshMessage(
        accountId: 'account-a',
        roomToken: 'rooma123',
        messageId: 140,
      );
      await Future<void>.delayed(Duration.zero);

      expect(refreshed, isTrue, reason: 'the cache already holds that copy');
      expect(writes, 0, reason: 'an identical row only wakes every watcher');
    });

    for (final (change, changed) in [
      ('edit', _refreshWire(text: 'Edited meanwhile')),
      ('deletion', _refreshWire(text: 'Message deleted', deleted: true)),
    ]) {
      test('a re-read keeps the $change live sync applied meanwhile', () async {
        final original = _refreshWire(text: 'Original');
        await _insertRefreshRow(database, original);
        final server = ServerBase.parse('https://cloud.example.invalid');
        // The live poll writes while the slower re-read is still on the wire
        // and then answers with the copy it read before that change.
        final api = _refreshServer(() async {
          await chat.applyMessageMutation(
            accountId: 'account-a',
            server: server,
            message: ChatMessage.fromJson(changed),
          );
          return original;
        });
        addTearDown(api.close);
        final service = ChatService(
          accounts: accounts,
          chat: chat,
          credentials: credentials,
          api: api,
        );
        final reader = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        addTearDown(reader.close);

        final refreshed = await service.refreshMessage(
          accountId: 'account-a',
          roomToken: 'rooma123',
          messageId: 140,
        );

        expect(refreshed, isFalse);
        final row = await chat.getMessage(
          accountId: 'account-a',
          roomToken: 'rooma123',
          messageId: 140,
        );
        expect(row?.rawJson, jsonEncode(ChatMessage.fromJson(changed).wire));
        expect(row?.deleted, changed['deleted'] == true);
      });
    }
  }
}

Map<String, Object?> _refreshWire({
  required String text,
  bool deleted = false,
}) => <String, Object?>{
  'id': 140,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'someone-else',
  'actorDisplayName': 'Other person',
  'timestamp': 1770000140,
  'systemMessage': '',
  'messageType': deleted ? 'comment_deleted' : 'comment',
  'isReplyable': !deleted,
  'referenceId': '',
  'message': text,
  'messageParameters': <String, Object?>{},
  'markdown': true,
  'reactions': <String, Object?>{},
  if (deleted) 'deleted': true,
};

Future<void> _insertRefreshRow(
  AppDatabase database,
  Map<String, Object?> wire,
) {
  final message = ChatMessage.fromJson(wire);
  return database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: 'account-a',
          roomToken: 'rooma123',
          messageId: message.messageId,
          actorType: message.actorType,
          actorId: message.actorId,
          actorDisplayName: message.actorDisplayName,
          timestamp: message.timestamp,
          systemMessage: message.systemMessage,
          messageType: message.messageType,
          referenceId: message.referenceId,
          displayText: message.message,
          deleted: message.deleted,
          rawJson: jsonEncode(message.wire),
        ),
      );
}

/// Answers every chat read with the one message [answer] yields.
HttpNextcloudApi _refreshServer(
  Future<Map<String, Object?>> Function() answer,
) => HttpNextcloudApi(
  client: MockClient((request) async {
    if (request.url.path.endsWith('/cloud/capabilities')) {
      return http.Response(jsonEncode(_chatCapabilities()), 200);
    }
    return http.Response(
      jsonEncode(<String, Object?>{
        'ocs': <String, Object?>{
          'meta': <String, Object?>{
            'status': 'ok',
            'statuscode': 200,
            'message': 'OK',
          },
          'data': <Object?>[await answer()],
        },
      }),
      200,
      headers: const <String, String>{
        'X-Chat-Last-Given': '140',
        'X-Chat-Last-Common-Read': '0',
      },
    );
  }),
);
