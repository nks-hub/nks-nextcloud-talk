part of 'room_details_screen_test.dart';

void _registerClearHistoryTests() {
  testWidgets('hides clear history without capability or moderator role', (
    tester,
  ) async {
    await openDetails(
      tester,
      forAccount: account,
      forConversation: conversation,
      client: participantsClient(const <Object?>[]),
    );
    expect(find.byKey(const Key('room-details-clear-history')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());

    final capableAccount = await withCapabilities({'clear-history'});
    final participantConversation = await _insertConversation(
      database,
      capableAccount,
      overrides: {'participantType': 3},
    );
    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: participantConversation,
      client: participantsClient(const <Object?>[]),
    );
    expect(find.byKey(const Key('room-details-clear-history')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancel closes the warning without a DELETE', (tester) async {
    final capableAccount = await withCapabilities({'clear-history'});
    var deleteRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess();
      }
      if (request.method == 'DELETE') {
        deleteRequests++;
      }
      return http.Response('', 500);
    });

    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: conversation,
      client: client,
    );
    await tester.tap(find.byKey(const Key('room-details-clear-history')));
    await tester.pump();

    expect(
      find.byKey(const Key('room-details-clear-history-dialog')),
      findsOneWidget,
    );
    expect(
      find.text(
        'This permanently deletes messages and threads for everyone in this '
        'conversation. This cannot be undone.',
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('room-details-clear-history-cancel')),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(deleteRequests, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('confirmed clear DELETEs once and forces a full resync', (
    tester,
  ) async {
    final capableAccount = await withCapabilities({'clear-history'});
    await (database.update(
      database.accounts,
    )..where((row) => row.id.equals(capableAccount.id))).write(
      const AccountsCompanion(
        conversationCursor: Value('1724300000'),
        conversationHash: Value('cached-hash'),
      ),
    );

    var deleteRequests = 0;
    final modifiedSinceValues = <String?>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess();
      }
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return _clearHistoryCapabilities(const <String>[
          'clear-history',
          'conversation-v4',
        ]);
      }
      if (request.method == 'DELETE' &&
          request.url.path.endsWith('/api/v1/chat/rooma123')) {
        deleteRequests++;
        return _clearHistoryResponse(200);
      }
      if (request.method == 'GET' &&
          request.url.path.endsWith('/api/v4/room')) {
        modifiedSinceValues.add(request.url.queryParameters['modifiedSince']);
        return _clearHistoryConversationListResponse();
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: conversation,
      client: client,
    );
    await _confirmClearHistory(tester);
    await _pumpUntil(
      tester,
      () =>
          modifiedSinceValues.isNotEmpty &&
          find.text('Conversation history was cleared.').evaluate().isNotEmpty,
    );

    expect(deleteRequests, 1);
    expect(modifiedSinceValues, <String?>[null]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('202 warns about copies even when the resync fails', (
    tester,
  ) async {
    final capableAccount = await withCapabilities({'clear-history'});
    var capabilityRequests = 0;
    var deleteRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess();
      }
      if (request.url.path.endsWith('/cloud/capabilities')) {
        capabilityRequests++;
        return _clearHistoryCapabilities(const <String>['clear-history']);
      }
      if (request.method == 'DELETE' &&
          request.url.path.endsWith('/api/v1/chat/rooma123')) {
        deleteRequests++;
        return _clearHistoryResponse(202);
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: conversation,
      client: client,
    );
    await _confirmClearHistory(tester);
    await _pumpUntil(
      tester,
      () => find
          .text(
            'Conversation history was cleared here. External services may '
            'still retain copies.',
          )
          .evaluate()
          .isNotEmpty,
    );

    expect(deleteRequests, 1);
    // The sync reuses the freshly forced capability snapshot from the clear
    // request, so no second HTTP capability read is necessary.
    expect(capabilityRequests, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a refused clear leaves the local message cache intact', (
    tester,
  ) async {
    final capableAccount = await withCapabilities({'clear-history'});
    await _seedRoomDetailsCachedMessage();
    var deleteRequests = 0;
    var conversationRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess();
      }
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return _clearHistoryCapabilities(const <String>['clear-history']);
      }
      if (request.method == 'DELETE' &&
          request.url.path.endsWith('/api/v1/chat/rooma123')) {
        deleteRequests++;
        return _clearHistoryResponse(403, status: 'failure');
      }
      if (request.url.path.endsWith('/api/v4/room')) {
        conversationRequests++;
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: conversation,
      client: client,
    );
    await _confirmClearHistory(tester);
    await _pumpUntil(
      tester,
      () => find
          .text("You don't have permission to do this.")
          .evaluate()
          .isNotEmpty,
    );

    final messages = await database.select(database.cachedChatMessages).get();
    expect(deleteRequests, 1);
    expect(conversationRequests, 0);
    expect(messages, hasLength(1));
    expect(messages.single.messageId, 4);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the clear-history warning fits at 200 % text', (tester) async {
    final capableAccount = await withCapabilities({'clear-history'});
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess();
      }
      return http.Response('', 500);
    });

    // The most destructive confirmation in the app: if large text pushed its
    // buttons off the screen, a moderator would be left with a warning they
    // can neither accept nor dismiss.
    // The screen itself scrolls, so it is loaded on a surface tall enough to
    // reach the action; the window is then cut down to a real phone before
    // the dialog opens, because a dialog is sized against the screen and a
    // tall test window would hide exactly the overflow this is looking for.
    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: conversation,
      client: client,
      textScale: 2,
      height: 6000,
    );
    expect(find.byKey(const Key('room-details-clear-history')), findsOneWidget);
    await tester.tap(find.byKey(const Key('room-details-clear-history')));
    await tester.pump();

    final overflows = await overflowsWhile(() async {
      tester.view.physicalSize = const Size(360, 640);
      await tester.pump();
      await tester.pump();
    });

    expect(
      find.byKey(const Key('room-details-clear-history-dialog')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('room-details-clear-history-cancel')),
      findsOneWidget,
      reason: 'the way out of the warning must survive the larger text',
    );
    expect(overflows, isEmpty, reason: overflows.join(' | '));

    await tester.tap(
      find.byKey(const Key('room-details-clear-history-cancel')),
    );
    await tester.pumpAndSettle();
  });
}

Future<void> _confirmClearHistory(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('room-details-clear-history')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('room-details-clear-history-confirm')));
  await tester.pump();
}

http.Response _clearHistoryCapabilities(Iterable<String> features) =>
    http.Response(jsonEncode(capabilitiesJson(talkFeatures: features)), 200);

http.Response _clearHistoryResponse(int statusCode, {String status = 'ok'}) =>
    http.Response(
      jsonEncode({
        'ocs': {
          'meta': {
            'status': status,
            'statuscode': statusCode,
            'message': status,
          },
          'data': statusCode == 200 || statusCode == 202
              ? _clearHistorySystemMessage()
              : const <Object?>[],
        },
      }),
      statusCode,
    );

http.Response _clearHistoryConversationListResponse() {
  final fixture = _readFixtureJson(
    'conversation-list/fixtures/conversations-full.response.json',
  );
  return http.Response.bytes(
    utf8.encode(jsonEncode(fixture)),
    200,
    headers: const <String, String>{
      'X-Nextcloud-Talk-Hash': 'fixture-hash-after-clear',
      'X-Nextcloud-Talk-Modified-Before': '1724300001',
      'X-Nextcloud-Talk-Federation-Invites': '0',
    },
  );
}

Future<void> _seedRoomDetailsCachedMessage() async {
  await database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: account.id,
          roomToken: conversation.token,
          messageId: 4,
          actorType: 'users',
          actorId: account.loginName,
          actorDisplayName: 'Fixture User',
          timestamp: 4,
          systemMessage: '',
          messageType: 'comment',
          referenceId: '',
          displayText: 'old',
          deleted: false,
          rawJson: jsonEncode({
            ..._clearHistorySystemMessage(),
            'id': 4,
            'systemMessage': '',
            'messageType': 'comment',
            'isReplyable': true,
            'message': 'old',
          }),
        ),
      );
}

Map<String, Object?> _clearHistorySystemMessage() => <String, Object?>{
  'id': 42,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'fixture-user',
  'actorDisplayName': 'Fixture User',
  'timestamp': 1787695200,
  'systemMessage': 'history_cleared',
  'messageType': 'system',
  'isReplyable': false,
  'referenceId': '',
  'message': 'You cleared the history of the conversation',
  'messageParameters': <String, Object?>{},
};
