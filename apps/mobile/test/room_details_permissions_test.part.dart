part of 'room_details_screen_test.dart';

void _registerPermissionEditorTests() {
  testWidgets(
    'permission editors are reachable only when their capabilities are cached',
    (tester) async {
      final permissionAccount = await withCapabilities({
        'conversation-permissions',
        'publishing-permissions',
        'mention-permissions',
      });
      await openDetails(
        tester,
        forAccount: permissionAccount,
        forConversation: conversation,
        client: participantsClient(_moderationParticipants()),
        height: 5000,
      );

      expect(
        find.byKey(const Key('room-details-default-permissions')),
        findsOne,
      );
      expect(
        find.byKey(const Key('room-details-mention-permissions')),
        findsOne,
      );

      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('room-participant-menu-3'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.byKey(const Key('room-participant-menu-3')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('room-participant-3-editPermissions')),
        findsOne,
      );

      final basicAccount = await withCapabilities(const {});
      await openDetails(
        tester,
        forAccount: basicAccount,
        forConversation: conversation,
        client: participantsClient(_moderationParticipants()),
        height: 5000,
      );
      expect(
        find.byKey(const Key('room-details-default-permissions')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('room-details-mention-permissions')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'default permissions require the destructive reset confirmation',
    (tester) async {
      final server = _PermissionUiServer()..member['attendeePermissions'] = 129;
      final permissionAccount = await withCapabilities(server.features);
      await openDetails(
        tester,
        forAccount: permissionAccount,
        forConversation: conversation,
        client: server.client,
        height: 5000,
      );

      await tester.tap(
        find.byKey(const Key('room-details-default-permissions')),
      );
      await _waitForPermissionEditor(tester);
      await tester.tap(find.byKey(const Key('room-details-permission-save')));
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('room-details-permission-reset-dialog'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(
        find.byKey(const Key('room-details-permission-reset-dialog-cancel')),
      );
      await tester.pumpAndSettle();
      expect(server.mutations, isEmpty);

      await tester.tap(
        find.byKey(const Key('room-details-default-permissions')),
      );
      await _waitForPermissionEditor(tester);
      await tester.tap(find.byKey(const Key('room-details-permission-save')));
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('room-details-permission-reset-confirm'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(
        find.byKey(const Key('room-details-permission-reset-confirm')),
      );
      await _pumpUntil(tester, () => server.mutations.length == 1);

      expect(
        server.mutations.single.url.path,
        endsWith('/permissions/default'),
      );
      expect(server.member['attendeePermissions'], 0);
    },
  );

  testWidgets('attendee custom none stays distinct from inherited zero', (
    tester,
  ) async {
    final server = _PermissionUiServer(
      maximumDefault: 0,
      maximumCustom: 1,
      serverDefault: 0,
    );
    final permissionAccount = await withCapabilities(server.features);
    await openDetails(
      tester,
      forAccount: permissionAccount,
      forConversation: conversation,
      client: server.client,
      height: 5000,
    );

    await _openMemberPermissionEditor(tester);
    await tester.tap(find.byKey(const Key('room-details-permission-custom')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-details-permission-save')));
    await _pumpUntil(tester, () => server.mutations.length == 1);

    expect(server.mutations.single.bodyFields, {
      'attendeeId': '17',
      'permissions': '1',
      'method': 'set',
    });
  });

  testWidgets('self-joined attendee conversion requires confirmation', (
    tester,
  ) async {
    final server = _PermissionUiServer()..member['participantType'] = 5;
    final permissionAccount = await withCapabilities(server.features);
    await openDetails(
      tester,
      forAccount: permissionAccount,
      forConversation: conversation,
      client: server.client,
      height: 5000,
    );

    await _openMemberPermissionEditor(tester);
    await tester.tap(find.byKey(const Key('room-details-permission-custom')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-details-permission-save')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-permission-membership-dialog'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const Key('room-details-permission-membership-dialog-cancel')),
    );
    await tester.pumpAndSettle();

    expect(server.mutations, isEmpty);
    expect(server.member['participantType'], 5);
  });

  testWidgets('mention editor updates the authoritative subtitle', (
    tester,
  ) async {
    final server = _PermissionUiServer();
    final permissionAccount = await withCapabilities(server.features);
    await openDetails(
      tester,
      forAccount: permissionAccount,
      forConversation: conversation,
      client: server.client,
      height: 5000,
    );

    await tester.tap(find.byKey(const Key('room-details-mention-permissions')));
    await _waitForPermissionEditor(tester);
    await tester.tap(find.byKey(const Key('room-details-mention-moderators')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-details-permission-save')));
    await _pumpUntil(
      tester,
      () =>
          server.mutations.length == 1 &&
          _textByKey(tester, 'room-details-mention-permissions-subtitle') ==
              'Moderators only',
    );

    expect(server.mutations.single.url.path, endsWith('/mention-permissions'));
  });

  testWidgets('forced and unsupported permissions cannot be changed', (
    tester,
  ) async {
    final server = _PermissionUiServer(
      maximumDefault: 254,
      maximumCustom: 255,
      serverDefault: 246,
      forced: {'permissions': 128},
      callsEnabled: false,
      features: const {
        'conversation-permissions',
        'publishing-permissions',
        'mention-permissions',
        'conversation-presets',
      },
    );
    final permissionAccount = await withCapabilities(server.features);
    await openDetails(
      tester,
      forAccount: permissionAccount,
      forConversation: conversation,
      client: server.client,
      height: 5000,
    );

    await tester.tap(find.byKey(const Key('room-details-default-permissions')));
    await _waitForPermissionEditor(tester);

    expect(find.byKey(const Key('room-details-permission-managed')), findsOne);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('room-details-permission-startCall')),
          )
          .onChanged,
      isNull,
    );
    expect(find.byKey(const Key('room-details-permission-chat')), findsNothing);
    expect(
      find.byKey(const Key('room-details-permission-react')),
      findsNothing,
    );
  });

  testWidgets('a forced zero mask leaves only inheritance available', (
    tester,
  ) async {
    final server = _PermissionUiServer(
      maximumDefault: 254,
      maximumCustom: 255,
      serverDefault: 246,
      forced: {'permissions': 0},
      features: const {'publishing-permissions', 'conversation-presets'},
    );
    final permissionAccount = await withCapabilities(server.features);
    await openDetails(
      tester,
      forAccount: permissionAccount,
      forConversation: conversation,
      client: server.client,
      height: 5000,
    );

    await _openMemberPermissionEditor(tester);
    expect(
      tester
          .widget<RadioListTile<bool>>(
            find.byKey(const Key('room-details-permission-custom')),
          )
          .enabled,
      isFalse,
    );
    await tester.tap(find.byKey(const Key('room-details-permission-save')));
    await _pumpUntil(tester, () => server.mutations.length == 1);
    expect(server.mutations.single.bodyFields['permissions'], '0');
  });

  testWidgets('permission editor remains usable at 200 percent text', (
    tester,
  ) async {
    final server = _PermissionUiServer();
    final permissionAccount = await withCapabilities(server.features);
    await openDetails(
      tester,
      forAccount: permissionAccount,
      forConversation: conversation,
      client: server.client,
      textScale: 2,
    );
    tester.view.physicalSize = const Size(400, 640);
    await tester.pump();

    final tile = find.byKey(const Key('room-details-default-permissions'));
    for (var attempt = 0; attempt < 20 && tile.evaluate().isEmpty; attempt++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -300));
      await tester.pump();
    }
    expect(tile, findsOne);
    await tester.ensureVisible(tile);
    await tester.tapAt(tester.getTopLeft(tile) + const Offset(200, 32));
    await _waitForPermissionEditor(tester);

    final save = find.byKey(const Key('room-details-permission-save'));
    expect(save, findsOne);
    await tester.ensureVisible(save);
    await tester.tap(save);
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-permission-reset-dialog'))
          .evaluate()
          .isNotEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving the room cancels a permission preparation', (
    tester,
  ) async {
    final server = _PermissionUiServer()..capabilitiesGate = Completer<void>();
    final permissionAccount = await withCapabilities(server.features);
    await openDetails(
      tester,
      forAccount: permissionAccount,
      forConversation: conversation,
      client: server.client,
      height: 5000,
    );

    await tester.tap(find.byKey(const Key('room-details-default-permissions')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    server.capabilitiesGate!.complete();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('room-details-permission-editor')),
      findsNothing,
    );
    expect(server.mutations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed default readback remains visibly uncertain', (
    tester,
  ) async {
    final server = _PermissionUiServer()
      ..member['attendeePermissions'] = 129
      ..keepOverrides = true;
    final permissionAccount = await withCapabilities(server.features);
    await openDetails(
      tester,
      forAccount: permissionAccount,
      forConversation: conversation,
      client: server.client,
      height: 5000,
    );

    await tester.tap(find.byKey(const Key('room-details-default-permissions')));
    await _waitForPermissionEditor(tester);
    await tester.tap(find.byKey(const Key('room-details-permission-save')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-permission-reset-confirm'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const Key('room-details-permission-reset-confirm')),
    );
    await _pumpUntil(
      tester,
      () => find
          .text(
            'The server did not confirm this change. Refresh the conversation '
            'settings before trying again.',
          )
          .evaluate()
          .isNotEmpty,
    );

    expect(server.mutations, hasLength(1));
    expect(server.member['attendeePermissions'], 129);
  });
}

Future<void> _waitForPermissionEditor(WidgetTester tester) => _pumpUntil(
  tester,
  () => find
      .byKey(const Key('room-details-permission-editor'))
      .evaluate()
      .isNotEmpty,
);

Future<void> _openMemberPermissionEditor(WidgetTester tester) async {
  await _pumpUntil(
    tester,
    () =>
        find.byKey(const Key('room-participant-menu-17')).evaluate().isNotEmpty,
  );
  await tester.tap(find.byKey(const Key('room-participant-menu-17')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(const Key('room-participant-17-editPermissions')),
  );
  await _waitForPermissionEditor(tester);
}

final class _PermissionUiServer {
  _PermissionUiServer({
    this.maximumDefault = 510,
    this.maximumCustom = 511,
    this.serverDefault = 502,
    this.forced,
    this.callsEnabled = true,
    Set<String>? features,
  }) : features =
           features ??
           const {
             'conversation-permissions',
             'publishing-permissions',
             'mention-permissions',
             'chat-permission',
             'react-permission',
           } {
    room = Map<String, Object?>.from(_conversationRoomJson())
      ..addAll({
        'type': 2,
        'participantType': 1,
        'defaultPermissions': 0,
        'attributes': 0,
        'objectType': '',
        'remoteServer': '',
        'mentionPermissions': 0,
      });
    people = [
      _permissionPerson(1, 'fixture-user', 1),
      _permissionPerson(17, 'synthetic-member', 3),
    ];
    client = MockClient(_handle);
  }

  final int maximumDefault;
  final int maximumCustom;
  final int serverDefault;
  final Map<String, int>? forced;
  final bool callsEnabled;
  final Set<String> features;
  late final Map<String, Object?> room;
  late final List<Map<String, Object?>> people;
  late final http.Client client;
  final mutations = <http.Request>[];
  Completer<void>? capabilitiesGate;
  bool keepOverrides = false;

  Map<String, Object?> get member => people.last;

  Future<http.Response> _handle(http.Request request) async {
    if (request.method != 'GET') {
      mutations.add(request);
      return _mutate(request);
    }
    if (request.url.path.endsWith('/capabilities')) {
      await capabilitiesGate?.future;
      return _capabilities();
    }
    if (request.url.path.endsWith('/presets/room')) {
      return _ocsSuccess([
        {
          'identifier': 'default',
          'name': '',
          'description': '',
          'parameters': {'roomType': 2},
        },
        {
          'identifier': 'forced',
          'name': '',
          'description': '',
          'parameters': forced ?? <String, int>{},
        },
      ]);
    }
    if (request.url.path.endsWith('/room')) return _ocsSuccess([room]);
    if (request.url.path.endsWith('/participants')) {
      return _ocsSuccess(_participants());
    }
    return http.Response('', 404);
  }

  http.Response _capabilities() {
    final root =
        _readFixtureJson(
              'client-bootstrap/fixtures/capabilities-authenticated.response.json',
            )!
            as Map<String, Object?>;
    final ocs = root['ocs']! as Map<String, Object?>;
    final data = ocs['data']! as Map<String, Object?>;
    final capabilities = data['capabilities']! as Map<String, Object?>;
    capabilities['spreed'] = {
      'features': features.toList(),
      'config': {
        'permissions': {
          'max-default': maximumDefault,
          'max-custom': maximumCustom,
          'default': serverDefault,
        },
        'call': {'enabled': callsEnabled},
      },
    };
    return http.Response(jsonEncode(root), 200);
  }

  List<Map<String, Object?>> _participants() => people.map((person) {
    final raw = person['attendeePermissions'] as int;
    final roomDefault = room['defaultPermissions'] as int;
    return {
      ...person,
      'permissions': const {1, 2, 6}.contains(person['participantType'])
          ? maximumDefault
          : raw != 0
          ? raw
          : roomDefault != 0
          ? roomDefault
          : serverDefault,
    };
  }).toList();

  Future<http.Response> _mutate(http.Request request) async {
    if (request.url.path.endsWith('/permissions/default')) {
      room['defaultPermissions'] = normalizePermissionSet(
        int.parse(request.bodyFields['permissions']!),
      );
      if (!keepOverrides) {
        for (final person in people) {
          person['attendeePermissions'] = 0;
        }
      }
      return _ocsSuccess(room);
    }
    if (request.url.path.endsWith('/mention-permissions')) {
      room['mentionPermissions'] = int.parse(
        request.bodyFields['mentionPermissions']!,
      );
      return _ocsSuccess(room);
    }
    final id = int.parse(request.bodyFields['attendeeId']!);
    final target = people.singleWhere((person) => person['attendeeId'] == id);
    target['attendeePermissions'] = normalizePermissionSet(
      int.parse(request.bodyFields['permissions']!),
    );
    if (target['participantType'] == 5) target['participantType'] = 3;
    return _ocsSuccess(
      _participants().where((person) => person['attendeeId'] == id).toList(),
    );
  }
}

Map<String, Object?> _permissionPerson(int id, String actor, int role) => {
  'attendeeId': id,
  'actorType': 'users',
  'actorId': actor,
  'displayName': actor,
  'participantType': role,
  'lastPing': 0,
  'sessionIds': <String>[],
  'permissions': 0,
  'attendeePermissions': 0,
  'inCall': 0,
};
