import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';

const permissionFeatures = <String>{
  'conversation-permissions',
  'publishing-permissions',
  'mention-permissions',
  'chat-permission',
  'react-permission',
};

CapabilitySnapshot permissionCapabilities({
  Set<String> features = permissionFeatures,
  Map<String, Object?>? permissions,
  Object? callsEnabled = true,
  CapabilityContext context = CapabilityContext.authenticated,
}) {
  final fixture =
      jsonDecode(
            File(
              '../../contracts/client-bootstrap/fixtures/capabilities-authenticated.response.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final ocs = fixture['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  final capabilities = data['capabilities']! as Map<String, Object?>;
  capabilities['spreed'] = {
    'features': features.toList(),
    'config': <String, Object?>{
      'permissions': ?permissions,
      'call': {'enabled': callsEnabled},
    },
  };
  return CapabilitySnapshot.fromJson(fixture, context: context);
}

RoomPresetCatalog permissionPresets(Map<String, int> forced) =>
    RoomPresetCatalog.fromJson([
      {
        'identifier': 'default',
        'name': 'Default',
        'description': '',
        'parameters': {'roomType': 2},
      },
      {
        'identifier': 'forced',
        'name': '',
        'description': '',
        'parameters': forced,
      },
    ]);

RoomPermissionPolicy permissionPolicy({
  Map<String, int>? forced,
  Set<String> features = permissionFeatures,
}) => RoomPermissionPolicy.fromCapabilities(
  permissionCapabilities(
    features: {...features, if (forced != null) 'conversation-presets'},
  ),
  presets: forced == null ? null : permissionPresets(forced),
);

SetRoomDefaultPermissionsRequest defaultPermissionRequest({
  RoomPermissionPolicy? policy,
  int mask = 129,
}) => SetRoomDefaultPermissionsRequest(
  accountId: AccountId.parse('account-a'),
  server: ServerBase.parse('https://cloud.example.invalid/cloud'),
  roomToken: ConversationToken.parse('rooma123', path: r'$.token'),
  policy: policy ?? permissionPolicy(),
  permissions: mask,
);

SetParticipantPermissionsRequest attendeePermissionRequest({
  RoomPermissionPolicy? policy,
  int mask = 129,
  int attendeeId = 17,
  PermissionPatchMethod method = PermissionPatchMethod.set,
}) => SetParticipantPermissionsRequest(
  accountId: AccountId.parse('account-a'),
  server: ServerBase.parse('https://cloud.example.invalid/cloud'),
  roomToken: ConversationToken.parse('rooma123', path: r'$.token'),
  policy: policy ?? permissionPolicy(),
  attendeeId: attendeeId,
  method: method,
  permissions: mask,
);

SetRoomMentionPermissionsRequest mentionPermissionRequest({
  RoomPermissionPolicy? policy,
  int value = 1,
}) => SetRoomMentionPermissionsRequest(
  accountId: AccountId.parse('account-a'),
  server: ServerBase.parse('https://cloud.example.invalid/cloud'),
  roomToken: ConversationToken.parse('rooma123', path: r'$.token'),
  policy: policy ?? permissionPolicy(),
  mentionPermissions: value,
);

Map<String, Object?> permissionRoom({String token = 'rooma123'}) {
  final fixture =
      jsonDecode(
            File(
              '../../contracts/conversation-list/fixtures/conversations-full.response.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final ocs = fixture['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  return {...rooms.first! as Map<String, Object?>, 'token': token};
}

Map<String, Object?> permissionAttendee({int id = 17}) => {
  'attendeeId': id,
  'actorType': 'users',
  'actorId': 'person-a',
  'displayName': 'Person A',
  'participantType': 3,
  'lastPing': 0,
  'sessionIds': <String>[],
  'permissions': 129,
  'attendeePermissions': 129,
  'inCall': 0,
};

Uint8List permissionResponseBody(int code, Object? data, {String? status}) =>
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'ocs': {
            'meta': {
              'status': status ?? (code == 200 ? 'ok' : 'failure'),
              'statuscode': code,
            },
            'data': data,
          },
        }),
      ),
    );
