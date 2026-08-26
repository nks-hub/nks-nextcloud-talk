part of 'room_details_screen_test.dart';

void _registerConversationTagsTests() {
  testWidgets('tags need capability but not moderator rights', (tester) async {
    await openDetails(
      tester,
      forAccount: account,
      forConversation: conversation,
      client: participantsClient(const <Object?>[]),
    );
    expect(
      find.byKey(const Key('room-details-conversation-tags')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());

    final capableAccount = await withCapabilities({'conversation-tags'});
    final participantRoom = await _insertConversation(
      database,
      capableAccount,
      overrides: {'participantType': 3},
    );
    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: participantRoom,
      client: participantsClient(const <Object?>[]),
    );
    expect(
      find.byKey(const Key('room-details-conversation-tags')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('dialog shows only custom tags and cancel does not POST', (
    tester,
  ) async {
    final capableAccount = await withCapabilities({'conversation-tags'});
    final taggedRoom = await _insertConversation(
      database,
      capableAccount,
      overrides: {
        'participantType': 3,
        'tagIds': <String>['11'],
      },
    );
    var assignmentRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess();
      }
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return _conversationTagsCapabilities();
      }
      if (request.method == 'GET' &&
          request.url.path.endsWith('/api/v4/tags')) {
        return _conversationTagsDefinitionsResponse();
      }
      if (request.method == 'POST') {
        assignmentRequests++;
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: taggedRoom,
      client: client,
    );
    await tester.tap(find.byKey(const Key('room-details-conversation-tags')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-conversation-tags-dialog'))
          .evaluate()
          .isNotEmpty,
    );

    expect(find.text('Favorites'), findsNothing);
    expect(find.text('Other'), findsNothing);
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Family'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('room-details-conversation-tag-11')),
          )
          .value,
      isTrue,
    );
    await tester.tap(
      find.byKey(const Key('room-details-conversation-tags-cancel')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(assignmentRequests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('save posts the full set and applies the authoritative room', (
    tester,
  ) async {
    final capableAccount = await withCapabilities({'conversation-tags'});
    final taggedRoom = await _insertConversation(
      database,
      capableAccount,
      overrides: {
        'participantType': 3,
        'tagIds': <String>['11', '77'],
      },
    );
    List<String>? postedTagIds;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess();
      }
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return _conversationTagsCapabilities();
      }
      if (request.method == 'GET' &&
          request.url.path.endsWith('/api/v4/tags')) {
        return _conversationTagsDefinitionsResponse();
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/api/v4/room/rooma123/tags')) {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        postedTagIds = (body['tagIds']! as List<Object?>).cast<String>();
        final room = _conversationRoomJson()
          ..['participantType'] = 3
          ..['tagIds'] = <String>['22'];
        return _ocsSuccess(room);
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: taggedRoom,
      client: client,
    );
    await tester.tap(find.byKey(const Key('room-details-conversation-tags')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-conversation-tags-dialog'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(find.byKey(const Key('room-details-conversation-tag-11')));
    await tester.tap(find.byKey(const Key('room-details-conversation-tag-22')));
    await tester.tap(
      find.byKey(const Key('room-details-conversation-tags-save')),
    );
    await _pumpUntil(
      tester,
      () =>
          postedTagIds != null &&
          _textByKey(tester, 'room-details-conversation-tags-subtitle') ==
              'Selected: 1',
    );

    expect(postedTagIds, containsAll(<String>['22', '77']));
    expect(postedTagIds, hasLength(2));
    final stored =
        await (database.select(database.cachedConversations)..where(
              (row) =>
                  row.accountId.equals(capableAccount.id) &
                  row.token.equals(taggedRoom.token),
            ))
            .getSingle();
    expect(ConversationRoom.fromJson(jsonDecode(stored.rawJson)).tagIds, {
      '22',
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('malformed definitions fail closed without assignment', (
    tester,
  ) async {
    final capableAccount = await withCapabilities({'conversation-tags'});
    var assignmentRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess();
      }
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return _conversationTagsCapabilities();
      }
      if (request.method == 'GET' &&
          request.url.path.endsWith('/api/v4/tags')) {
        return _ocsSuccess(<Object?>[
          _conversationTagDefinition('11', 'Work'),
          _conversationTagDefinition('11', 'Duplicate'),
        ]);
      }
      if (request.method == 'POST') {
        assignmentRequests++;
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: conversation,
      client: client,
    );
    await tester.tap(find.byKey(const Key('room-details-conversation-tags')));
    await _pumpUntil(
      tester,
      () => find
          .text('The change could not be saved. Please try again.')
          .evaluate()
          .isNotEmpty,
    );

    expect(
      find.byKey(const Key('room-details-conversation-tags-dialog')),
      findsNothing,
    );
    expect(assignmentRequests, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

http.Response _conversationTagsCapabilities() => http.Response(
  jsonEncode(
    capabilitiesJson(talkFeatures: const <String>['conversation-tags']),
  ),
  200,
);

http.Response _conversationTagsDefinitionsResponse() => _ocsSuccess(<Object?>[
  {
    'id': '1',
    'name': 'Favorites',
    'sortOrder': 0,
    'collapsed': false,
    'type': 'favorites',
  },
  _conversationTagDefinition('11', 'Work', sortOrder: 1),
  _conversationTagDefinition('22', 'Family', sortOrder: 2),
  {
    'id': '2',
    'name': 'Other',
    'sortOrder': 3,
    'collapsed': false,
    'type': 'other',
  },
]);

Map<String, Object?> _conversationTagDefinition(
  String id,
  String name, {
  int sortOrder = 1,
}) => {
  'id': id,
  'name': name,
  'sortOrder': sortOrder,
  'collapsed': false,
  'type': 'custom',
};
