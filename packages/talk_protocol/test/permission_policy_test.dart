import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

import 'permission_test_support.dart';

void main() {
  test('keeps inheritance distinct from explicit no rights', () {
    expect(normalizePermissionSet(0), 0);
    expect(normalizePermissionSet(1), 1);
    expect(normalizePermissionSet(128), 129);
    expect(defaultPermissionRequest(mask: 0).formBody['permissions'], '0');
    expect(attendeePermissionRequest(mask: 1).formBody['permissions'], '1');
  });

  test(
    'uses supported fallback masks and excludes lobby bypass from inherited defaults',
    () {
      final modern = permissionPolicy();
      final legacy = permissionPolicy(
        features: permissionFeatures.difference({'react-permission'}),
      );
      expect(
        [modern.maximumDefault, modern.maximumCustom, modern.serverDefault],
        [510, 511, 502],
      );
      expect(
        [legacy.maximumDefault, legacy.maximumCustom, legacy.serverDefault],
        [254, 255, 246],
      );
      expect(modern.canEditReactions, isTrue);
      expect(legacy.canEditReactions, isFalse);
      expect(
        () => attendeePermissionRequest(policy: legacy, mask: 257),
        throwsA(isA<TalkProtocolException>()),
      );
    },
  );

  test('honors configured masks and rejects bits outside them', () {
    final policy = RoomPermissionPolicy.fromCapabilities(
      permissionCapabilities(
        permissions: {'max-default': 6, 'max-custom': 7, 'default': 4},
      ),
    );
    expect(
      [policy.maximumDefault, policy.maximumCustom, policy.serverDefault],
      [6, 7, 4],
    );
    expect(
      defaultPermissionRequest(policy: policy, mask: 5).formBody['permissions'],
      '5',
    );
    expect(
      () => defaultPermissionRequest(policy: policy, mask: 8),
      throwsA(isA<TalkProtocolException>()),
    );
    expect(policy.canEditReactions, isFalse);
  });

  test(
    'rejects malformed and contradictory policy rather than clipping it',
    () {
      for (final config in <Map<String, Object?>>[
        {'max-default': -1},
        {'max-default': 511},
        {'max-custom': 510},
        {'max-default': 510, 'max-custom': 255},
        {'max-custom': 513},
        {'default': '502'},
        {'default': null},
        {'max-custom': 7, 'default': 128},
      ]) {
        expect(
          () => RoomPermissionPolicy.fromCapabilities(
            permissionCapabilities(permissions: config),
          ),
          throwsA(isA<TalkProtocolException>()),
        );
      }
      expect(
        () => RoomPermissionPolicy.fromCapabilities(
          permissionCapabilities(callsEnabled: 'yes'),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    },
  );

  test(
    'requires the advertised forced preset and an authenticated snapshot',
    () {
      expect(
        () => RoomPermissionPolicy.fromCapabilities(
          permissionCapabilities(
            features: {...permissionFeatures, 'conversation-presets'},
          ),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => RoomPermissionPolicy.fromCapabilities(
          permissionCapabilities(),
          presets: permissionPresets({}),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => RoomPermissionPolicy.fromCapabilities(
          permissionCapabilities(context: CapabilityContext.anonymous),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    },
  );

  test(
    'preserves raw forced mask while still allowing attendee inheritance reset',
    () {
      final policy = permissionPolicy(forced: {'permissions': 128});
      expect(
        defaultPermissionRequest(
          policy: policy,
          mask: 128,
        ).formBody['permissions'],
        '128',
      );
      expect(
        attendeePermissionRequest(
          policy: policy,
          mask: 128,
        ).formBody['permissions'],
        '128',
      );
      expect(
        attendeePermissionRequest(
          policy: policy,
          mask: 0,
        ).formBody['permissions'],
        '0',
      );
      expect(
        () => defaultPermissionRequest(policy: policy, mask: 129),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => defaultPermissionRequest(policy: policy, mask: 0),
        throwsA(isA<TalkProtocolException>()),
      );
      for (final method in [
        PermissionPatchMethod.add,
        PermissionPatchMethod.remove,
      ]) {
        expect(
          () => attendeePermissionRequest(
            policy: policy,
            mask: 128,
            method: method,
          ),
          throwsA(isA<TalkProtocolException>()),
        );
        expect(
          attendeePermissionRequest(
            policy: policy,
            mask: 0,
            method: method,
          ).formBody['method'],
          method.name,
        );
      }
    },
  );

  test('forced zero and mention policy cannot be overridden', () {
    final policy = permissionPolicy(
      forced: {'permissions': 0, 'mentionPermissions': 1},
    );
    expect(
      defaultPermissionRequest(policy: policy, mask: 0).formBody['permissions'],
      '0',
    );
    expect(
      () => attendeePermissionRequest(policy: policy, mask: 1),
      throwsA(isA<TalkProtocolException>()),
    );
    expect(
      mentionPermissionRequest(
        policy: policy,
        value: 1,
      ).formBody['mentionPermissions'],
      '1',
    );
    expect(
      () => mentionPermissionRequest(policy: policy, value: 0),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test(
    'gates each operation independently and keeps call configuration separate',
    () {
      final defaultsOnly = permissionPolicy(
        features: {'conversation-permissions'},
      );
      expect(
        defaultPermissionRequest(policy: defaultsOnly),
        isA<SetRoomDefaultPermissionsRequest>(),
      );
      expect(
        () => attendeePermissionRequest(policy: defaultsOnly),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => mentionPermissionRequest(policy: defaultsOnly),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(defaultsOnly.canEditChat, isFalse);
      final callsOff = RoomPermissionPolicy.fromCapabilities(
        permissionCapabilities(callsEnabled: false),
      );
      expect(callsOff.callsEnabled, isFalse);
      expect(callsOff.canEditAttendees, isTrue);
    },
  );

  test('builds only the stable routes and puts attendee identity in the body', () {
    final defaults = defaultPermissionRequest();
    final attendee = attendeePermissionRequest(
      method: PermissionPatchMethod.add,
      mask: 16,
    );
    final mentions = mentionPermissionRequest();
    expect(
      defaults.uri.path,
      '/cloud/ocs/v2.php/apps/spreed/api/v4/room/rooma123/permissions/default',
    );
    expect(
      attendee.uri.path,
      '/cloud/ocs/v2.php/apps/spreed/api/v4/room/rooma123/attendees/permissions',
    );
    expect(
      mentions.uri.path,
      '/cloud/ocs/v2.php/apps/spreed/api/v4/room/rooma123/mention-permissions',
    );
    expect(attendee.uri.queryParameters, {'format': 'json'});
    expect(attendee.formBody, {
      'attendeeId': '17',
      'permissions': '16',
      'method': 'add',
    });
    for (final request in [defaults, attendee, mentions]) {
      expect(request.httpMethod, 'PUT');
      expect(request.headers['OCS-APIRequest'], 'true');
      expect(request.uri.path, isNot(endsWith('/permissions/call')));
      expect(request.uri.path, isNot(endsWith('/permissions/all')));
      expect(() => request.formBody.clear(), throwsUnsupportedError);
      expect(request.toString(), isNot(contains('rooma123')));
    }
  });

  test('refuses invalid identities and values before forming a mutation', () {
    for (final id in [-1, 9007199254740992]) {
      expect(
        () => attendeePermissionRequest(attendeeId: id),
        throwsA(isA<TalkProtocolException>()),
      );
    }
    for (final value in [-1, 512, 1024]) {
      expect(
        () => defaultPermissionRequest(mask: value),
        throwsA(isA<TalkProtocolException>()),
      );
    }
    expect(
      () => mentionPermissionRequest(value: 2),
      throwsA(isA<TalkProtocolException>()),
    );
    expect(
      () => SetRoomMentionPermissionsRequest(
        accountId: AccountId.parse('account-a'),
        server: ServerBase.parse('https://cloud.example.invalid'),
        roomToken: ConversationToken.parse('rooma123', path: r'$.token'),
        policy: permissionPolicy(),
        mentionPermissions: 0,
        userAgent: 'invalid\r\nheader',
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });
}
