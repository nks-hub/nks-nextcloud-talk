import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

List<Map<String, Object?>> creationPresets({int forcedPermissions = 129}) => [
  {
    'identifier': 'default',
    'name': 'Server defaults',
    'description': '',
    'parameters': {
      'roomType': 2,
      'readOnly': 0,
      'listable': 0,
      'messageExpiration': 0,
      'lobbyState': 0,
      'sipEnabled': 0,
      'permissions': 0,
      'recordingConsent': 0,
      'mentionPermissions': 0,
    },
  },
  {
    'identifier': 'webinar',
    'name': 'Webinar',
    'description': 'Moderated discussion',
    'parameters': {
      'roomType': 3,
      'permissions': 389,
      'lobbyState': 1,
      'recordingConsent': 1,
    },
  },
  {
    'identifier': 'presentation',
    'name': 'Presentation',
    'description': '',
    'parameters': {'permissions': 389},
  },
  {
    'identifier': 'forced',
    'name': '',
    'description': '',
    'parameters': {'permissions': forcedPermissions},
  },
];

RoomPresetCatalog creationCatalog() =>
    RoomPresetCatalog.fromJson(creationPresets());

Map<String, dynamic> creationCapabilities({
  bool presets = true,
  bool password = true,
  bool force = false,
  bool all = true,
}) {
  final fixture =
      readFixtureJson(
            'client-bootstrap/fixtures/capabilities-authenticated.response.json',
          )
          as Map<String, dynamic>;
  final capabilities =
      fixture['ocs']['data']['capabilities'] as Map<String, dynamic>;
  capabilities['spreed'] = {
    'features': [
      if (presets) 'conversation-presets',
      if (password) 'conversation-creation-password',
      if (all) 'conversation-creation-all',
    ],
    'config': <String, Object?>{
      'conversations': {'force-passwords': force},
    },
  };
  return fixture;
}

Map<String, Object?> createdConversation({int status = 201}) {
  final fixture =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )
          as Map;
  final room = Map<String, Object?>.from(
    (fixture['ocs']['data'] as List).first as Map,
  );
  if (status == 202) {
    room['invalidParticipants'] = {
      'users': ['missing-user'],
    };
  }
  return {
    'ocs': {
      'meta': {'status': 'ok', 'statuscode': status},
      'data': room,
    },
  };
}
