import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/chat/location_share_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  group('current location source', () {
    test('requests permission and returns the current fix', () async {
      final platform = _FakeLocationPlatform(
        permission: LocationPermission.denied,
        requestedPermission: LocationPermission.whileInUse,
      );

      final position = await GeolocatorCurrentLocationSource(
        platform: platform,
      ).current();

      expect(position.latitude, 50.0875);
      expect(platform.permissionRequests, 1);
      expect(platform.currentRequests, 1);
    });

    for (final entry in const <LocationPermission, CurrentLocationError>{
      LocationPermission.denied: CurrentLocationError.permissionDenied,
      LocationPermission.deniedForever:
          CurrentLocationError.permissionDeniedForever,
    }.entries) {
      test('maps ${entry.key.name} without requesting a fix', () async {
        final platform = _FakeLocationPlatform(
          permission: entry.key,
          requestedPermission: entry.key,
        );

        await expectLater(
          GeolocatorCurrentLocationSource(platform: platform).current(),
          throwsA(
            isA<CurrentLocationException>().having(
              (error) => error.code,
              'code',
              entry.value,
            ),
          ),
        );
        expect(platform.currentRequests, 0);
      });
    }

    test('rejects a disabled location service', () async {
      final platform = _FakeLocationPlatform(serviceEnabled: false);

      await expectLater(
        GeolocatorCurrentLocationSource(platform: platform).current(),
        throwsA(
          isA<CurrentLocationException>().having(
            (error) => error.code,
            'code',
            CurrentLocationError.servicesDisabled,
          ),
        ),
      );
      expect(platform.permissionChecks, 0);
    });

    test('uses only a last-known fix newer than five minutes', () async {
      final fresh = _FakeLocationPlatform(
        currentError: TimeoutException('fixture timeout'),
        lastKnown: LocatedPosition(
          latitude: 49.99,
          longitude: 14.41,
          timestamp: DateTime.now().subtract(const Duration(minutes: 4)),
        ),
      );
      final stale = _FakeLocationPlatform(
        currentError: TimeoutException('fixture timeout'),
        lastKnown: LocatedPosition(
          latitude: 49.99,
          longitude: 14.41,
          timestamp: DateTime.now().subtract(const Duration(minutes: 6)),
        ),
      );

      final fallback = await GeolocatorCurrentLocationSource(
        platform: fresh,
      ).current();
      expect(fallback.latitude, 49.99);
      await expectLater(
        GeolocatorCurrentLocationSource(platform: stale).current(),
        throwsA(
          isA<CurrentLocationException>().having(
            (error) => error.code,
            'code',
            CurrentLocationError.unavailable,
          ),
        ),
      );
    });
  });

  group('location share service', () {
    late AppDatabase database;
    late AccountRepository accounts;
    late ChatRepository chat;
    late MemoryCredentialVault vault;
    late StoredAccount account;
    late CachedConversation conversation;

    setUp(() async {
      database = openTestDatabase();
      accounts = AccountRepository(database);
      chat = ChatRepository(database);
      vault = MemoryCredentialVault();
      account = await accounts.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://cloud.example.invalid/nextcloud',
        loginName: 'user-a',
        serverProductName: 'Nextcloud',
        talkFeatures: const {},
        createdAt: DateTime.utc(2026, 1, 1),
      );
      vault.values[account.id] = 'app-password';
      conversation = await _insertConversation(database, account);
    });

    tearDown(() => database.close());

    test('posts an exact account-bound root location', () async {
      var shareRequests = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return _capabilitiesResponse();
        }
        shareRequests++;
        final fields = request.bodyFields;
        expect(request.url.path, endsWith('/chat/${conversation.token}/share'));
        expect(fields['objectType'], 'geo-location');
        final metadata =
            jsonDecode(fields['metaData']!) as Map<String, Object?>;
        expect(metadata['latitude'], '50.0875');
        expect(metadata['longitude'], '14.42076');
        return _shareResponse(
          roomToken: conversation.token,
          referenceId: fields['referenceId']!,
          metadata: metadata,
        );
      });

      final message = await _service(accounts, chat, vault, client).share(
        accountId: account.id,
        roomToken: conversation.token,
        position: const SharedPosition(50.0875, 14.42076),
        name: 'Shared location',
        threadId: null,
      );

      expect(message.messageId, 500);
      expect(shareRequests, 1);
    });

    for (final entry in const <String, Map<String, Object?>>{
      'read-only room': {'readOnly': 1},
      'missing chat permission': {'permissions': 0},
      'active lobby without bypass': {'lobbyState': 1, 'permissions': 128},
    }.entries) {
      test('rejects ${entry.key} before HTTP', () async {
        await _replaceConversation(database, conversation, entry.value);
        var requests = 0;
        final client = MockClient((request) async {
          requests++;
          return http.Response('', 500);
        });

        await expectLater(
          _service(accounts, chat, vault, client).share(
            accountId: account.id,
            roomToken: conversation.token,
            position: const SharedPosition(50, 14),
            name: 'Shared location',
            threadId: null,
          ),
          _locationError(LocationShareError.contextMissing),
        );
        expect(requests, 0);
      });
    }

    test('rejects missing credentials and named root before HTTP', () async {
      vault.values.clear();
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return http.Response('', 500);
      });
      final service = _service(accounts, chat, vault, client);

      await expectLater(
        service.share(
          accountId: account.id,
          roomToken: conversation.token,
          position: const SharedPosition(50, 14),
          name: 'Shared location',
          threadId: null,
        ),
        _locationError(LocationShareError.credentialMissing),
      );
      vault.values[account.id] = 'app-password';
      await expectLater(
        service.share(
          accountId: account.id,
          roomToken: conversation.token,
          position: const SharedPosition(50, 14),
          name: 'Shared location',
          threadId: 777,
        ),
        _locationError(LocationShareError.contextMissing),
      );
      expect(requests, 0);
    });

    for (final status in const <int?>[null, 503]) {
      test(
        'classifies ${status ?? 'network loss'} after POST as ambiguous',
        () async {
          final client = MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              return _capabilitiesResponse();
            }
            if (status == null) {
              throw http.ClientException('fixture disconnect', request.url);
            }
            return http.Response('', status);
          });

          await expectLater(
            _service(accounts, chat, vault, client).share(
              accountId: account.id,
              roomToken: conversation.token,
              position: const SharedPosition(50, 14),
              name: 'Shared location',
              threadId: null,
            ),
            _locationError(LocationShareError.ambiguous),
          );
        },
      );
    }
  });
}

LocationShareService _service(
  AccountRepository accounts,
  ChatRepository chat,
  MemoryCredentialVault vault,
  http.Client client,
) => LocationShareService(
  accounts: accounts,
  chat: chat,
  credentials: vault,
  api: HttpNextcloudApi(client: client),
);

Matcher _locationError(LocationShareError code) => throwsA(
  isA<LocationShareException>().having((error) => error.code, 'code', code),
);

Future<CachedConversation> _insertConversation(
  AppDatabase database,
  StoredAccount account,
) async {
  final roomJson = _roomJson();
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
  return database.select(database.cachedConversations).getSingle();
}

Future<void> _replaceConversation(
  AppDatabase database,
  CachedConversation conversation,
  Map<String, Object?> overrides,
) async {
  final raw = jsonDecode(conversation.rawJson) as Map<String, Object?>
    ..addAll(overrides);
  await (database.update(database.cachedConversations)..where(
        (row) =>
            row.accountId.equals(conversation.accountId) &
            row.token.equals(conversation.token),
      ))
      .write(CachedConversationsCompanion(rawJson: Value(jsonEncode(raw))));
}

Map<String, Object?> _roomJson() {
  final root =
      jsonDecode(
            File(
              '../../contracts/conversation-list/fixtures/'
              'conversations-full.response.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  return Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
}

http.Response _capabilitiesResponse() => _jsonResponse(
  capabilitiesJson(
    talkFeatures: const <String>['chat-v2', 'geo-location-sharing'],
  ),
);

http.Response _shareResponse({
  required String roomToken,
  required String referenceId,
  required Map<String, Object?> metadata,
}) => _jsonResponse({
  'ocs': {
    'meta': {'status': 'ok', 'statuscode': 201, 'message': 'OK'},
    'data': {
      'id': 500,
      'token': roomToken,
      'actorType': 'users',
      'actorId': 'user-a',
      'actorDisplayName': 'User A',
      'timestamp': 1787443000,
      'systemMessage': 'object_shared',
      'messageType': 'system',
      'isReplyable': true,
      'referenceId': referenceId,
      'message': '{object}',
      'messageParameters': {'object': metadata},
      'markdown': false,
      'reactions': <String, Object?>{},
      'threadId': 500,
    },
  },
}, statusCode: 201);

http.Response _jsonResponse(Object? body, {int statusCode = 200}) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      statusCode,
      headers: {'content-type': 'application/json'},
    );

final class _FakeLocationPlatform implements LocationPlatform {
  _FakeLocationPlatform({
    this.serviceEnabled = true,
    this.permission = LocationPermission.whileInUse,
    this.requestedPermission = LocationPermission.whileInUse,
    this.currentError,
    this.lastKnown,
  });

  final bool serviceEnabled;
  final LocationPermission permission;
  final LocationPermission requestedPermission;
  final Object? currentError;
  final LocatedPosition? lastKnown;
  var permissionChecks = 0;
  var permissionRequests = 0;
  var currentRequests = 0;

  @override
  Future<LocationPermission> checkPermission() async {
    permissionChecks++;
    return permission;
  }

  @override
  Future<LocatedPosition> currentPosition() async {
    currentRequests++;
    if (currentError != null) {
      throw currentError!;
    }
    return LocatedPosition(
      latitude: 50.0875,
      longitude: 14.42076,
      timestamp: DateTime.now(),
    );
  }

  @override
  Future<bool> isServiceEnabled() async => serviceEnabled;

  @override
  Future<LocatedPosition?> lastKnownPosition() async => lastKnown;

  @override
  Future<LocationPermission> requestPermission() async {
    permissionRequests++;
    return requestedPermission;
  }
}
