part of 'chat_service_integration_test.dart';

extension _ChatServiceSendActivityCases on _ChatServiceIntegrationSuite {
  void registerSendActivityCases() {
    test(
      'a text send is reported from the tap until it is delivered',
      () async {
        final activity = <bool>[];
        List<bool>? duringPost;
        final api = HttpNextcloudApi(
          client: _sendServer((request) {
            duringPost = List<bool>.of(activity);
            return _acceptedSend(request, 121);
          }),
        );
        addTearDown(api.close);
        final service = ChatService(
          accounts: accounts,
          chat: chat,
          credentials: credentials,
          api: api,
          reportSendActivity: activity.add,
        );
        addTearDown(service.close);
        await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
        expect(activity, isEmpty, reason: 'reading a room is not a send');

        final admitted = service.sendText(
          accountId: 'account-a',
          roomToken: 'rooma123',
          message: 'held while it travels',
        );
        expect(activity, [true], reason: 'held before anything is awaited');
        await admitted;
        await _waitForOutboxSettled(chat);
        await _waitForChatCondition(() => activity.length == 2);

        expect(duringPost, [true]);
        expect(activity, [true, false]);
      },
    );

    test('a send that cannot leave releases the process while it waits for '
        'its retry', () async {
      final activity = <bool>[];
      final api = HttpNextcloudApi(
        client: _UnreachableClient(
          _sendServer((request) => _acceptedSend(request, 121)),
          unreachable: (request) => request.method == 'POST',
        ),
      );
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
        reportSendActivity: activity.add,
      );
      addTearDown(service.close);
      await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');

      await service.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'no way out',
      );
      await _waitForChatCondition(() => activity.length == 2);

      expect(activity, [true, false]);
      final row = await database
          .select(database.textSendOperations)
          .getSingle();
      expect(row.outboxState, 'retryable');
    });

    test('a send that is refused admission releases the process', () async {
      final activity = <bool>[];
      final api = HttpNextcloudApi(
        client: _sendServer((request) => _acceptedSend(request, 121)),
      );
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
        reportSendActivity: activity.add,
      );
      addTearDown(service.close);

      await expectLater(
        service.sendText(
          accountId: 'account-a',
          roomToken: 'rooma123',
          message: '   ',
        ),
        throwsA(isA<ChatServiceException>()),
      );

      expect(activity, [true, false]);
    });
  }
}
