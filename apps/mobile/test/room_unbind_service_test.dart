import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/rooms/room_settings_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault()..values['account-a'] = 'password-a';
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://a.example.invalid',
      loginName: 'user-a',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
      talkFeatures: const <String>{'unbind-conversation'},
    );
  });

  tearDown(() => database.close());

  RoomSettingsService serviceWith(MockClient client) {
    final api = HttpNextcloudApi(client: client);
    addTearDown(api.close);
    return RoomSettingsService(
      accounts: accounts,
      chat: ChatRepository(database),
      credentials: vault,
      api: api,
    );
  }

  MockClient serverReturning({
    required String objectType,
    int statusCode = 200,
    List<String>? calls,
  }) => MockClient((request) async {
    if (request.url.path.endsWith('/cloud/capabilities')) {
      return http.Response(
        jsonEncode(
          capabilitiesJson(talkFeatures: const ['unbind-conversation']),
        ),
        200,
      );
    }
    calls?.add('${request.method} ${request.url.path}');
    if (statusCode != 200) {
      return http.Response(
        jsonEncode(<String, Object?>{
          'ocs': <String, Object?>{
            'meta': <String, Object?>{
              'status': 'failure',
              'statuscode': statusCode,
              'message': '',
            },
            'data': <String, Object?>{'error': 'object-type'},
          },
        }),
        statusCode,
      );
    }
    return http.Response(
      jsonEncode(<String, Object?>{
        'ocs': <String, Object?>{
          'meta': <String, Object?>{
            'status': 'ok',
            'statuscode': 200,
            'message': 'OK',
          },
          'data': roomJson(objectType: objectType),
        },
      }),
      200,
    );
  });

  test('an event room comes back with no binding at all', () async {
    final calls = <String>[];
    final service = serviceWith(serverReturning(objectType: '', calls: calls));

    final remaining = await service.unbindConversation(
      accountId: 'account-a',
      roomToken: 'rooma123',
      objectType: 'event',
    );

    expect(remaining, '');
    expect(
      calls.single,
      'DELETE /ocs/v2.php/apps/spreed/api/v4/room/rooma123/object',
    );
  });

  test('a temporary phone room comes back as a persistent one', () async {
    // Measured on the reference server: this is the transition that a naive
    // implementation would report as "now an ordinary conversation".
    final service = serviceWith(serverReturning(objectType: 'phone_persist'));

    final remaining = await service.unbindConversation(
      accountId: 'account-a',
      roomToken: 'rooma123',
      objectType: 'phone_temporary',
    );

    expect(remaining, 'phone_persist');
  });

  test('a binding the server refuses never leaves this side', () async {
    var reached = false;
    final service = serviceWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              capabilitiesJson(talkFeatures: const ['unbind-conversation']),
            ),
            200,
          );
        }
        reached = true;
        return http.Response('', 200);
      }),
    );

    for (final refused in const <String>['', 'phone_persist', 'note_to_self']) {
      await expectLater(
        () => service.unbindConversation(
          accountId: 'account-a',
          roomToken: 'rooma123',
          objectType: refused,
        ),
        throwsA(
          isA<RoomSettingsException>().having(
            (error) => error.code,
            'code',
            RoomSettingsError.rejected,
          ),
        ),
        reason: refused,
      );
    }
    expect(reached, isFalse);
  });

  test('a non-moderator is reported as forbidden', () async {
    final service = serviceWith(
      serverReturning(objectType: '', statusCode: 403),
    );

    await expectLater(
      () => service.unbindConversation(
        accountId: 'account-a',
        roomToken: 'rooma123',
        objectType: 'event',
      ),
      throwsA(
        isA<RoomSettingsException>().having(
          (error) => error.code,
          'code',
          RoomSettingsError.forbidden,
        ),
      ),
    );
  });

  test('a server without the capability is never asked', () async {
    var reached = false;
    final service = serviceWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(capabilitiesJson(talkFeatures: const ['chat-v2'])),
            200,
          );
        }
        reached = true;
        return http.Response('', 200);
      }),
    );

    await expectLater(
      () => service.unbindConversation(
        accountId: 'account-a',
        roomToken: 'rooma123',
        objectType: 'event',
      ),
      throwsA(isA<RoomSettingsException>()),
    );
    expect(reached, isFalse);
  });
}

/// The room payload the endpoint answers with, reduced to what the decoder
/// requires.
Map<String, Object?> roomJson({required String objectType}) => {
  'actorId': 'user-a',
  'actorType': 'users',
  'attendeeId': 101,
  'attendeePermissions': 0,
  'attendeePin': null,
  'avatarVersion': '1',
  'breakoutRoomMode': 0,
  'breakoutRoomStatus': 0,
  'callFlag': 0,
  'callPermissions': 0,
  'callRecording': 0,
  'callStartTime': 0,
  'canDeleteConversation': true,
  'canEnableSIP': false,
  'canLeaveConversation': true,
  'canStartCall': true,
  'defaultPermissions': 0,
  'description': '',
  'displayName': 'UP13 probe',
  'hasCall': false,
  'hasPassword': false,
  'id': 1001,
  'isCustomAvatar': false,
  'isFavorite': false,
  'lastActivity': 1724300100,
  'lastCommonReadMessage': 0,
  'lastPing': 0,
  'lastReadMessage': 0,
  'listable': 0,
  'liveTranscriptionLanguageId': '',
  'lobbyState': 0,
  'lobbyTimer': 0,
  'mentionPermissions': 0,
  'messageExpiration': 0,
  'name': 'UP13 probe',
  'notificationCalls': 1,
  'notificationLevel': 1,
  'objectId': objectType.isEmpty ? '' : 'probe',
  'objectType': objectType,
  'participantFlags': 0,
  'participantType': 1,
  'permissions': 255,
  'readOnly': 0,
  'recordingConsent': 0,
  'sessionId': 'fixture-session',
  'sipEnabled': 0,
  'token': 'rooma123',
  'type': 3,
  'unreadMention': false,
  'unreadMentionDirect': false,
  'unreadMessages': 0,
  'isArchived': false,
  'isImportant': false,
  'isSensitive': false,
  'tagIds': <Object?>[],
  'hasScheduledMessages': 0,
  'lastPinnedId': 0,
  'hiddenPinnedId': 0,
  'attributes': 0,
};
