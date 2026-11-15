part of 'chat_service_integration_test.dart';

extension _ChatServiceColdAdmissionCases on _ChatServiceIntegrationSuite {
  void registerColdAdmissionCases() {
    test('a send without a capability snapshot in memory is in the outbox '
        'before the server answers anything', () async {
      // An earlier run of the app left its capabilities in the database.
      final warmApi = HttpNextcloudApi(
        client: _sendServer((request) => _acceptedSend(request, 121)),
      );
      addTearDown(warmApi.close);
      final warm = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: warmApi,
      );
      await warm.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
      await warm.close();

      // This one starts cold, and its server takes its time.
      final answer = Completer<void>();
      final requests = <String>[];
      final coldApi = HttpNextcloudApi(
        client: MockClient((request) async {
          final capabilities = request.url.path.endsWith('/cloud/capabilities');
          requests.add(capabilities ? 'capabilities' : request.method);
          await answer.future;
          if (capabilities) {
            return http.Response(
              jsonEncode(
                _chatCapabilities(talkFeatures: _sendFeatures.toList()),
              ),
              200,
            );
          }
          return request.method == 'GET'
              ? http.Response('', 304)
              : _acceptedSend(request, 121);
        }),
      );
      addTearDown(coldApi.close);
      final cold = ChatService(
        accounts: AccountRepository(database),
        chat: ChatRepository(database),
        credentials: credentials,
        api: coldApi,
      );
      addTearDown(cold.close);

      await cold
          .sendText(
            accountId: 'account-a',
            roomToken: 'rooma123',
            message: 'durable before the network',
          )
          .timeout(const Duration(seconds: 2));

      final admitted = await database
          .select(database.textSendOperations)
          .getSingle();
      expect(admitted.message, 'durable before the network');
      expect(admitted.outboxState, 'queued');
      // The server is asked alongside, and has not said a word yet.
      await _waitForChatCondition(() => requests.isNotEmpty);
      expect(requests, ['capabilities']);

      answer.complete();
      await _waitForOutboxSettled(chat);
      final sent = await database
          .select(database.textSendOperations)
          .getSingle();
      expect(sent.outboxState, 'completed');
      expect(requests, ['capabilities', 'POST']);
    });
  }
}
