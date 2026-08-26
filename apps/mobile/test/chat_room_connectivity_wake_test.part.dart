part of 'chat_room_live_sync_test.dart';

void _registerConnectivityWakeTest() {
  testWidgets(
    'foreground connectivity drains once and inactive pane ignores events',
    (tester) async {
      final database = openTestDatabase();
      addTearDown(database.close);
      final accounts = AccountRepository(database);
      final chat = ChatRepository(database);
      final vault = MemoryCredentialVault();
      final wakes = StreamController<void>.broadcast();
      addTearDown(wakes.close);
      final account = await accounts.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://cloud.example.invalid',
        loginName: 'fixture-user',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      vault.values[account.id] = 'fixture-app-password-never-use';
      final roomJson = _conversationRoomJson();
      final room = ConversationRoom.fromJson(roomJson);
      await database
          .into(database.cachedConversations)
          .insert(
            CachedConversationsCompanion.insert(
              accountId: account.id,
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
      final conversation = await chat.getConversation(
        accountId: account.id,
        roomToken: room.token.value,
      );
      expect(conversation, isNotNull);

      const features = <String>{
        'conversation-v4',
        'chat-v2',
        'chat-reference-id',
      };
      var capabilityRequests = 0;
      var sendRequests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            capabilityRequests++;
            return http.Response(
              jsonEncode(capabilitiesJson(talkFeatures: features.toList())),
              200,
            );
          }
          if (request.method == 'POST') {
            sendRequests++;
            final response =
                jsonDecode(
                      jsonEncode(
                        readFixtureJson(
                          'chat-messages/fixtures/send-success.response.json',
                        ),
                      ),
                    )!
                    as Map<String, Object?>;
            final ocs = response['ocs']! as Map<String, Object?>;
            final data = ocs['data']! as Map<String, Object?>;
            data['referenceId'] = request.bodyFields['referenceId'];
            data['message'] = request.bodyFields['message'];
            return http.Response(
              jsonEncode(response),
              201,
              headers: const <String, String>{'X-Chat-Last-Common-Read': '110'},
            );
          }
          return http.Response('', 304);
        }),
      );
      addTearDown(api.close);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(() {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
            credentialVaultProvider.overrideWithValue(vault),
            nextcloudApiProvider.overrideWithValue(api),
            connectivityWakeEventsProvider.overrideWithValue(wakes.stream),
          ],
          child: localizedTestApp(
            home: ChatRoomPane(account: account, conversation: conversation!),
          ),
        ),
      );
      await _pumpUntil(tester, () => capabilityRequests == 1);
      await _waitForConnectivityCapability(tester, chat, account.id);
      await _pumpUntil(
        tester,
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );

      await _admitConnectivityWidgetSend(
        chat,
        accountId: account.id,
        roomToken: room.token,
        features: features,
        operationId: '11111111-1111-4111-8111-111111111111',
        referenceId: '22222222-2222-4222-8222-222222222222',
      );
      wakes
        ..add(null)
        ..add(null);
      await _pumpUntil(tester, () => sendRequests == 1);

      var operations = await database.select(database.textSendOperations).get();
      expect(capabilityRequests, 2);
      expect(sendRequests, 1);
      expect(operations.single.outboxState, 'completed');
      expect(operations.single.attemptCount, 1);

      await _admitConnectivityWidgetSend(
        chat,
        accountId: account.id,
        roomToken: room.token,
        features: features,
        operationId: '33333333-3333-4333-8333-333333333333',
        referenceId: '44444444-4444-4444-8444-444444444444',
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      wakes.add(null);
      await tester.pump(const Duration(milliseconds: 100));

      operations = await database.select(database.textSendOperations).get();
      final inactiveOperation = operations.singleWhere(
        (operation) =>
            operation.operationId == '33333333-3333-4333-8333-333333333333',
      );
      expect(capabilityRequests, 2);
      expect(sendRequests, 1);
      expect(inactiveOperation.outboxState, 'queued');
      expect(inactiveOperation.attemptCount, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      wakes.add(null);
      await tester.pump(const Duration(milliseconds: 100));
      expect(capabilityRequests, 2);
      expect(sendRequests, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _waitForConnectivityCapability(
  WidgetTester tester,
  ChatRepository chat,
  String accountId,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final capability = await tester.runAsync(
      () => chat.getReadyCapabilitySnapshot(accountId),
    );
    if (capability != null) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 10));
  }
  fail('Capability snapshot was not persisted');
}

Future<void> _admitConnectivityWidgetSend(
  ChatRepository chat, {
  required String accountId,
  required ConversationToken roomToken,
  required Set<String> features,
  required String operationId,
  required String referenceId,
}) async {
  final capability = await chat.getReadyCapabilitySnapshot(accountId);
  expect(capability, isNotNull);
  await chat.admitTextSend(
    accountId: accountId,
    roomToken: roomToken,
    authority: ChatTextSendAuthority(
      accountId: AccountId.parse(accountId),
      server: ServerBase.parse('https://cloud.example.invalid'),
      capabilityGeneration: capability!.generation,
      profile: ChatCapabilityProfile.fromTalkFeatures(
        features.toList(),
        federated: false,
      ),
      replayContractRevision: textSendReplayContractRevision,
    ),
    operationId: ChatOperationId.parse(operationId),
    referenceId: ChatReferenceId.parse(referenceId),
    message: 'Connectivity widget fixture',
  );
}
