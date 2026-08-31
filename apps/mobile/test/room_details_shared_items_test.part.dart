part of 'room_details_screen_test.dart';

void _registerSharedItemsTests() {
  testWidgets('opens shared items only when the room capabilities allow it', (
    tester,
  ) async {
    final localAccount = await withCapabilities({'rich-object-list-media'});
    final overrides = <Override>[
      sharedItemsServiceProvider.overrideWithValue(
        const _EmptySharedItemsService(),
      ),
    ];
    await openDetails(
      tester,
      forAccount: localAccount,
      forConversation: conversation,
      client: participantsClient(const <Object?>[]),
      overrides: overrides,
    );

    final entry = find.byKey(const Key('room-details-shared-items'));
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    await _pumpUntil(
      tester,
      () => find.byType(SharedItemsScreen).evaluate().isNotEmpty,
    );
    expect(find.byType(SharedItemsScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 500));

    final remoteJson = <String, Object?>{
      ..._conversationRoomJson(),
      'token': 'remote123',
      'remoteServer': 'remote.example.invalid',
      'lastMessage': null,
    };
    final remoteConversation = conversation.copyWith(
      token: 'remote123',
      rawJson: jsonEncode(remoteJson),
    );
    await openDetails(
      tester,
      forAccount: localAccount,
      forConversation: remoteConversation,
      client: participantsClient(const <Object?>[]),
      overrides: overrides,
    );
    expect(entry, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());

    final federatedAccount = await withCapabilities({
      'rich-object-list-media',
      'federated-shared-items',
    });
    expect(
      jsonDecode(federatedAccount.talkFeaturesJson),
      containsAll(<String>['rich-object-list-media', 'federated-shared-items']),
    );
    expect(
      ConversationRoom.fromJson(remoteJson).remoteServer,
      'remote.example.invalid',
    );
    await openDetails(
      tester,
      forAccount: federatedAccount,
      forConversation: remoteConversation,
      client: participantsClient(const <Object?>[]),
      overrides: overrides,
    );
    expect(entry, findsOneWidget);
  });
}

final class _EmptySharedItemsService implements SharedItemsService {
  const _EmptySharedItemsService();

  @override
  Future<SharedItemsOverviewResponse> overview({
    required String accountId,
    required String roomToken,
    Future<void>? abortTrigger,
  }) async {
    final request = SharedItemsOverviewRequest(
      accountId: AccountId.parse(accountId),
      requestId: ChatRequestId.parse('shared-items-room-details-test'),
      server: ServerBase.parse(account.serverUrl),
      roomToken: ConversationToken.parse(
        roomToken,
        path: r'$.roomToken',
        code: TalkProtocolErrorCode.invalidSharedItemsRequest,
      ),
      sharedItemsAvailable: true,
      limit: sharedItemsOverviewLimit,
    );
    return decodeSharedItemsOverviewResponse(
      request: request,
      statusCode: 200,
      body: Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'ocs': {
              'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
              'data': <String, Object?>{},
            },
          }),
        ),
      ),
    );
  }

  @override
  Future<SharedItemsPageResponse> page({
    required String accountId,
    required String roomToken,
    required SharedItemType type,
    required int lastKnownMessageId,
    Future<void>? abortTrigger,
  }) => throw StateError('an empty overview must not request a page');
}
