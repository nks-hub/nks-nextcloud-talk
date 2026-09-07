import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'publishes with a password in the same POST and retains legacy empty body',
    () {
      SetRoomPublicRequest request({
        String? password,
        bool available = true,
        bool public = true,
        bool force = false,
      }) => SetRoomPublicRequest(
        accountId: AccountId.parse('account-a'),
        server: ServerBase.parse('https://cloud.example.invalid'),
        roomToken: ConversationToken.parse('roomabc', path: r'$.token'),
        public: public,
        password: password,
        creationPasswordAvailable: available,
        forcePasswords: force,
      );
      final protected = request(password: '  pass value  ', force: true);
      expect(protected.httpMethod, 'POST');
    expect(protected.uri.path, endsWith('/room/roomabc/public'));
      expect(protected.formBody, {'password': '  pass value  '});
      expect(protected.toString(), isNot(contains('pass value')));
      expect(request().formBody, isNull);
      expect(request(public: false).httpMethod, 'DELETE');
      for (final make in <void Function()>[
        () => request(password: 'x', available: false),
        () => request(password: 'x', public: false),
        () => request(force: true),
        () => request(password: '', force: true),
        () => request(force: true, available: false),
      ]) {
        expect(make, throwsA(isA<TalkProtocolException>()));
      }
    },
  );
  test(
    'merges default selected user then forced without retaining old choices',
    () {
      final catalog = RoomPresetCatalog.fromJson([
        _preset('default', {'roomType': 2, 'permissions': 0, 'listable': 0}),
        _preset('webinar', {
          'roomType': 3,
          'permissions': 389,
          'lobbyState': 1,
        }),
        _preset('presentation', {'permissions': 389}),
        _preset('forced', {'permissions': 129, 'lobbyState': 1}),
      ]);
      final selected = catalog.resolve(
        presetIdentifier: 'webinar',
        userChoices: {'roomType': 2, 'permissions': 511, 'listable': 1},
      );
      expect(selected.parameters, {
        'roomType': 2,
        'permissions': 129,
        'listable': 1,
        'lobbyState': 1,
      });
      expect(selected.forcedKeys, {'permissions', 'lobbyState'});
      final next = catalog.resolve(presetIdentifier: 'presentation');
      expect(next.parameters['roomType'], 2);
      expect(next.parameters['listable'], 0);
      expect(catalog.selectablePresets.map((p) => p.identifier), [
        'default',
        'webinar',
        'presentation',
      ]);
      expect(
        () => selected.parameters['permissions'] = 511,
        throwsUnsupportedError,
      );
    },
  );

  test('accepts only an empty PHP list for empty forced parameters', () {
    final catalog = RoomPresetCatalog.fromJson([
      _preset('default', {'roomType': 2}),
      _preset('forced', <Object?>[]),
    ]);
    expect(catalog.forcedPreset.parameters, isEmpty);
    expect(catalog.defaultPreset.name, 'Výchozí název');
    expect(
      () => RoomPresetCatalog.fromJson([
        _preset('default', {'roomType': 2}),
        _preset('forced', [1]),
      ]),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test(
    'rejects unknown policy instead of partially applying forced parameters',
    () {
      expect(
        () => RoomPresetCatalog.fromJson([
          _preset('default', {'roomType': 2}),
          _preset('forced', {'permissions': 129, 'futureSecuritySetting': 1}),
        ]),
        throwsA(isA<TalkProtocolException>()),
      );
    },
  );

  test('requires unique identifiers and both policy layers', () {
    for (final invalid in <Object?>[
      [],
      {},
      [_preset('default', {})],
      [_preset('default', {}), _preset('default', {}), _preset('forced', {})],
      [_preset('default', {}), _preset('forced', {}), _preset('../escape', {})],
      List.generate(65, (i) => _preset('preset$i', {})),
    ]) {
      expect(
        () => RoomPresetCatalog.fromJson(invalid),
        throwsA(isA<TalkProtocolException>()),
      );
    }
  });

  test(
    'bounds all supported creation parameters including room-only consent',
    () {
      for (final entry in roomPresetParameterMaximums.entries) {
        expect(
          validateRoomPresetParameters({entry.key: entry.value})[entry.key],
          entry.value,
        );
        expect(
          () => validateRoomPresetParameters({entry.key: entry.value + 1}),
          throwsA(isA<TalkProtocolException>()),
        );
        expect(
          () => validateRoomPresetParameters({entry.key: -1}),
          throwsA(isA<TalkProtocolException>()),
        );
        expect(
          () => validateRoomPresetParameters({entry.key: '1'}),
          throwsA(isA<TalkProtocolException>()),
        );
      }
      expect(
        () => validateRoomPresetParameters({'roomType': 1}),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => validateRoomPresetParameters({'recordingConsent': 2}),
        throwsA(isA<TalkProtocolException>()),
      );
    },
  );

  test('does not select forced or a voice preset absent from the response', () {
    final catalog = RoomPresetCatalog.fromJson([
      _preset('default', {}),
      _preset('forced', {}),
    ]);
    for (final id in ['forced', 'voiceroom']) {
      expect(
        () => catalog.resolve(presetIdentifier: id),
        throwsA(isA<TalkProtocolException>()),
      );
    }
  });

  test(
    'rejects oversized localized strings and malformed success metadata',
    () {
      final presets = [_preset('default', {}), _preset('forced', {})];
      for (final field in ['name', 'description']) {
        final invalid = [...presets];
        invalid[0] = {...invalid[0], field: 'x' * 4097};
        expect(
          () => RoomPresetCatalog.fromJson(invalid),
          throwsA(isA<TalkProtocolException>()),
        );
      }
      expect(
        decodeRoomPresetsResponse(
          statusCode: 200,
          json: {
            'ocs': {
              'meta': {'status': 'ok', 'statuscode': 200},
              'data': presets,
            },
          },
        ).presets,
        hasLength(2),
      );
      for (final status in [201, '200', 403]) {
        expect(
          () => decodeRoomPresetsResponse(
            statusCode: 200,
            json: {
              'ocs': {
                'meta': {'status': 'ok', 'statuscode': status},
                'data': presets,
              },
            },
          ),
          throwsA(isA<TalkProtocolException>()),
        );
      }
    },
  );

  test(
    'sends effective fields and preserves an invited group on public creation',
    () {
      final request = _create(
        password: '  secret value  ',
        preset: 'webinar',
        parameters: {'roomType': 3, 'lobbyState': 1},
        invite: true,
      );
      expect(request.formBody, {
        'roomType': '3',
        'roomName': 'Room',
        'password': '  secret value  ',
        'preset': 'webinar',
        'lobbyState': '1',
        'invite': 'group-a',
        'source': 'groups',
      });
      expect(request.toString(), isNot(contains('secret value')));
      expect(request.uri.toString(), isNot(contains('secret')));
      expect(request.headers.toString(), isNot(contains('secret')));
    },
  );

  test(
    'refuses password or preset payload without the matching capabilities',
    () {
      for (final make in <void Function()>[
        () => _create(password: 'secret', passwordAvailable: false),
        () => _create(password: '', force: true),
        () => _create(force: true),
        () => _create(preset: 'webinar', presetsAvailable: false),
        () => _create(parameters: {'readOnly': 1}, allAvailable: false),
        () => _create(preset: 'forced'),
        () => _create(parameters: {'roomType': 2}),
      ]) {
        expect(make, throwsA(isA<TalkProtocolException>()));
      }
      expect(_create(password: '').formBody['password'], '');
      expect(_create().formBody.containsKey('password'), isFalse);
    },
  );
}

Map<String, Object?> _preset(String id, Object parameters) => {
  'identifier': id,
  'name': 'Výchozí název',
  'description': '',
  'parameters': parameters,
};

CreateConversationRequest _create({
  String? password,
  String? preset,
  Map<String, int> parameters = const {},
  bool invite = false,
  bool passwordAvailable = true,
  bool presetsAvailable = true,
  bool allAvailable = true,
  bool force = false,
}) => CreateConversationRequest(
  accountId: AccountId.parse('account-a'),
  requestId: ConversationRequestId.parse('create-a'),
  server: ServerBase.parse('https://cloud.example.invalid'),
  roomType: CreateConversationRoomType.public,
  roomName: 'Room',
  inviteId: invite ? 'group-a' : null,
  inviteSource: invite ? 'groups' : null,
  password: password,
  presetIdentifier: preset,
  presetParameters: parameters,
  creationPasswordAvailable: passwordAvailable,
  presetsAvailable: presetsAvailable,
  creationAllAvailable: allAvailable,
  forcePasswords: force,
);
