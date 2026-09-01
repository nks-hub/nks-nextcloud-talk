import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/credential_vault.dart';
import 'package:nextcloudtalk/features/conversations/conversation_sync_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  test('every sync failure is decided transient or not', () {
    // Two wake-up paths lean on this: the push transport retries on it, and
    // the client-push wake swallows it instead of letting the zone report a
    // fatal crash. A new code must land on one side deliberately, so the
    // whole enum is listed here rather than a sample of it.
    const transient = <ConversationSyncError>{
      ConversationSyncError.network,
      ConversationSyncError.rateLimited,
      ConversationSyncError.serviceUnavailable,
    };
    for (final code in ConversationSyncError.values) {
      expect(
        ConversationSyncException(code).isTransient,
        transient.contains(code),
        reason: '${code.name} is classified the same way on both paths',
      );
    }
  });

  late AppDatabase database;
  late AccountRepository repository;
  late MemoryCredentialVault vault;

  setUp(() async {
    database = openTestDatabase();
    repository = AccountRepository(database);
    vault = MemoryCredentialVault();
    await repository.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    vault.values['account-a'] = 'fixture-app-password-never-use';
  });

  tearDown(() => database.close());

  test('temporary Apple credential lock is a transient sync failure', () async {
    var requests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((_) async {
        requests++;
        return http.Response('', 500);
      }),
    );
    addTearDown(api.close);
    final service = ConversationSyncService(
      accounts: repository,
      credentials: const _TemporarilyUnavailableCredentialVault(),
      api: api,
    );

    await expectLater(
      service.sync('account-a'),
      throwsA(
        isA<ConversationSyncException>()
            .having((error) => error.isTransient, 'isTransient', isTrue)
            .having(
              (error) => error.code,
              'code',
              ConversationSyncError.network,
            ),
      ),
    );

    expect(requests, 0);
    expect((await repository.getAccount('account-a'))?.lastSyncError, isNull);
  });

  test('transport failures never escape the public sync boundary', () async {
    final api = HttpNextcloudApi(
      client: MockClient(
        (_) async => throw http.ClientException('network unavailable'),
      ),
    );
    addTearDown(api.close);
    final service = ConversationSyncService(
      accounts: repository,
      credentials: vault,
      api: api,
    );

    await expectLater(
      service.sync('account-a'),
      throwsA(
        isA<ConversationSyncException>().having(
          (error) => error.code,
          'code',
          ConversationSyncError.network,
        ),
      ),
    );

    expect(
      (await repository.getAccount('account-a'))?.lastSyncError,
      ConversationSyncError.network.name,
    );
  });

  test(
    'single-flight sync merges a full conversation response atomically',
    () async {
      var conversationRequests = 0;
      final conversationResponse =
          readFixtureJson(
                'conversation-list/fixtures/'
                'conversations-full.response.json',
              )
              as Map<String, Object?>;
      final ocs = conversationResponse['ocs']! as Map<String, Object?>;
      final rawRooms = ocs['data']! as List<Object?>;
      final firstRoom = rawRooms.first! as Map<String, Object?>;
      firstRoom['type'] = 1;
      firstRoom['objectType'] = 'file';
      firstRoom['avatarVersion'] = 'custom-avatar-v7';
      firstRoom['isCustomAvatar'] = true;
      firstRoom['status'] = 'away';
      firstRoom['statusClearAt'] = 1770000120;
      firstRoom['statusIcon'] = '☕';
      firstRoom['statusMessage'] = 'Coffee break';
      final firstLastMessage =
          firstRoom['lastMessage']! as Map<String, Object?>;
      firstLastMessage['message'] = _giphyResourceUrl;
      firstLastMessage['messageParameters'] = <String, Object?>{};
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(jsonEncode(capabilitiesJson()), 200);
          }
          conversationRequests++;
          expect(request.url.queryParameters['noStatusUpdate'], '1');
          expect(request.url.queryParameters['includeStatus'], 'true');
          expect(request.headers['Authorization'], startsWith('Basic '));
          return http.Response.bytes(
            utf8.encode(jsonEncode(conversationResponse)),
            200,
            headers: const <String, String>{
              'X-Nextcloud-Talk-Hash': 'fixture-hash-a',
              'X-Nextcloud-Talk-Modified-Before': '1724300001',
              'X-Nextcloud-Talk-Federation-Invites': '0',
            },
          );
        }),
      );
      addTearDown(api.close);
      final service = ConversationSyncService(
        accounts: repository,
        credentials: vault,
        api: api,
      );

      await Future.wait<void>([
        service.sync('account-a'),
        service.sync('account-a'),
      ]);

      final rooms = await repository.watchConversations('account-a').first;
      final account = await repository.getAccount('account-a');
      expect(conversationRequests, 1);
      expect(rooms.map((room) => room.displayName), [
        'Synthetic room B',
        'Synthetic room A',
      ]);
      expect(account?.conversationHash, 'fixture-hash-a');
      expect(account?.conversationCursor, '1724300001');
      expect(account?.lastSyncError, isNull);
      expect(jsonDecode(account!.talkFeaturesJson), [
        'chat-v2',
        'conversation-v4',
      ]);

      final firstStoredRoom = rooms.firstWhere(
        (room) => room.token == 'rooma123',
      );
      expect(firstStoredRoom.roomType, 1);
      expect(firstStoredRoom.roomName, 'synthetic-room-a');
      expect(firstStoredRoom.objectType, 'file');
      expect(firstStoredRoom.avatarVersion, 'custom-avatar-v7');
      expect(firstStoredRoom.isCustomAvatar, isTrue);
      expect(firstStoredRoom.peerStatus, 'away');
      expect(firstStoredRoom.peerStatusClearAt, 1770000120);
      expect(firstStoredRoom.peerStatusIcon, '☕');
      expect(firstStoredRoom.peerStatusMessage, 'Coffee break');
      final firstStoredWire =
          jsonDecode(firstStoredRoom.rawJson) as Map<String, Object?>;
      expect(firstStoredWire['status'], 'away');
      expect(firstStoredWire['statusClearAt'], 1770000120);
      expect(firstStoredWire['statusIcon'], '☕');
      expect(firstStoredWire['statusMessage'], 'Coffee break');
      expect(firstStoredRoom.lastMessageText, 'GIF');
      expect(firstStoredRoom.lastMessageText, isNot(_giphyResourceUrl));

      final secondStoredRoom = rooms.firstWhere(
        (room) => room.token == 'roomb456',
      );
      expect(secondStoredRoom.roomType, 3);
      expect(secondStoredRoom.roomName, 'synthetic-room-b');
      expect(secondStoredRoom.objectType, isEmpty);
      expect(secondStoredRoom.avatarVersion, '2');
      expect(secondStoredRoom.isCustomAvatar, isFalse);
    },
  );

  test(
    'status survives an absent delta and clears on an authoritative full',
    () async {
      Map<String, Object?> response() =>
          jsonDecode(
                jsonEncode(
                  readFixtureJson(
                    'conversation-list/fixtures/'
                    'conversations-full.response.json',
                  ),
                ),
              )
              as Map<String, Object?>;

      Map<String, Object?> firstRoom(Map<String, Object?> response) {
        final ocs = response['ocs']! as Map<String, Object?>;
        return (ocs['data']! as List<Object?>).first! as Map<String, Object?>;
      }

      final statusFull = response();
      firstRoom(statusFull)
        ..['type'] = 1
        ..['status'] = 'online'
        ..['statusClearAt'] = 1770000120
        ..['statusIcon'] = '🟢'
        ..['statusMessage'] = 'Available';
      final absentDelta = response();
      firstRoom(absentDelta)['type'] = 1;
      final clearingFull = response();
      firstRoom(clearingFull)['type'] = 1;

      var conversationRequests = 0;
      final modifiedSinceValues = <String?>[];
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(jsonEncode(capabilitiesJson()), 200);
          }
          conversationRequests++;
          expect(request.url.queryParameters['includeStatus'], 'true');
          modifiedSinceValues.add(request.url.queryParameters['modifiedSince']);
          final body = switch (conversationRequests) {
            1 => statusFull,
            2 => absentDelta,
            _ => clearingFull,
          };
          return http.Response.bytes(
            utf8.encode(jsonEncode(body)),
            200,
            headers: <String, String>{
              'X-Nextcloud-Talk-Hash': 'fixture-hash-a',
              'X-Nextcloud-Talk-Modified-Before':
                  '${1724300000 + conversationRequests}',
              'X-Nextcloud-Talk-Federation-Invites': '0',
            },
          );
        }),
      );
      addTearDown(api.close);
      final service = ConversationSyncService(
        accounts: repository,
        credentials: vault,
        api: api,
      );

      await service.sync('account-a');
      var stored = (await repository.watchConversations('account-a').first)
          .firstWhere((room) => room.token == 'rooma123');
      expect(stored.peerStatus, 'online');
      expect(stored.peerStatusClearAt, 1770000120);
      expect(stored.peerStatusIcon, '🟢');
      expect(stored.peerStatusMessage, 'Available');

      await service.sync('account-a');
      stored = (await repository.watchConversations('account-a').first)
          .firstWhere((room) => room.token == 'rooma123');
      final preservedWire = jsonDecode(stored.rawJson) as Map<String, Object?>;
      expect(stored.peerStatus, 'online');
      expect(stored.peerStatusClearAt, 1770000120);
      expect(stored.peerStatusIcon, '🟢');
      expect(stored.peerStatusMessage, 'Available');
      expect(preservedWire['status'], 'online');
      expect(preservedWire['statusClearAt'], 1770000120);
      expect(preservedWire['statusIcon'], '🟢');
      expect(preservedWire['statusMessage'], 'Available');

      await service.sync('account-a', forceFull: true);
      stored = (await repository.watchConversations('account-a').first)
          .firstWhere((room) => room.token == 'rooma123');
      final clearedWire = jsonDecode(stored.rawJson) as Map<String, Object?>;
      expect(stored.peerStatus, isNull);
      expect(stored.peerStatusClearAt, isNull);
      expect(stored.peerStatusIcon, isNull);
      expect(stored.peerStatusMessage, isNull);
      expect(clearedWire.containsKey('status'), isFalse);
      expect(clearedWire.containsKey('statusClearAt'), isFalse);
      expect(clearedWire.containsKey('statusIcon'), isFalse);
      expect(clearedWire.containsKey('statusMessage'), isFalse);
      expect(modifiedSinceValues, [null, '1724300001', null]);
    },
  );

  test(
    'manual full refresh reconciles stale rooms without crossing account or outbox scope',
    () async {
      final fullResponse =
          readFixtureJson(
                'conversation-list/fixtures/conversations-full.response.json',
              )
              as Map<String, Object?>;
      final reconciledResponse =
          jsonDecode(jsonEncode(fullResponse)) as Map<String, Object?>;
      final reconciledRooms =
          (reconciledResponse['ocs']! as Map<String, Object?>)['data']!
              as List<Object?>;
      reconciledRooms.removeWhere(
        (room) => (room! as Map<String, Object?>)['token'] == 'roomb456',
      );

      var conversationRequests = 0;
      final modifiedSinceValues = <String?>[];
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(jsonEncode(capabilitiesJson()), 200);
          }
          modifiedSinceValues.add(request.url.queryParameters['modifiedSince']);
          conversationRequests++;
          return http.Response(
            jsonEncode(
              conversationRequests == 1 ? fullResponse : reconciledResponse,
            ),
            200,
            headers: <String, String>{
              'X-Nextcloud-Talk-Hash': 'fixture-hash-a',
              'X-Nextcloud-Talk-Modified-Before':
                  switch (conversationRequests) {
                    1 => '1724300001',
                    2 => '1724300101',
                    _ => '1724300201',
                  },
              'X-Nextcloud-Talk-Federation-Invites': '0',
            },
          );
        }),
      );
      addTearDown(api.close);
      final service = ConversationSyncService(
        accounts: repository,
        credentials: vault,
        api: api,
      );

      await service.sync('account-a');
      await repository.upsertAccount(
        accountId: 'account-b',
        serverUrl: 'https://other.example.invalid',
        loginName: 'other-user',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 2),
      );
      await database
          .into(database.cachedConversations)
          .insert(
            CachedConversationsCompanion.insert(
              accountId: 'account-b',
              token: 'roomb456',
              displayName: 'Other account room',
              description: '',
              lastActivity: 1,
              unreadMessages: 0,
              favorite: false,
              rawJson: '{}',
            ),
          );
      await database
          .into(database.textSendOperations)
          .insert(
            TextSendOperationsCompanion.insert(
              accountId: 'account-a',
              operationId: '00000000-0000-4000-8000-000000000001',
              roomToken: 'roomb456',
              referenceId: '00000000-0000-4000-8000-000000000001',
              message: 'Pending stale-room message',
              replayContractRevision: 'fixture-revision',
              enqueueSequence: 1,
              outboxState: 'queued',
              attemptCount: 0,
              messageIdsJson: '[]',
              duplicateRiskAcknowledged: false,
              createdAtMillis: 1,
              updatedAtMillis: 1,
            ),
          );

      await service.sync('account-a');
      final roomsAfterIncremental = await repository
          .watchConversations('account-a')
          .first;
      expect(roomsAfterIncremental.map((room) => room.token).toSet(), {
        'rooma123',
        'roomb456',
      });

      await service.sync('account-a', forceFull: true);

      final accountARooms = await repository
          .watchConversations('account-a')
          .first;
      final accountBRooms = await repository
          .watchConversations('account-b')
          .first;
      final pendingQuery = database.select(database.textSendOperations)
        ..where((operation) => operation.accountId.equals('account-a'))
        ..where((operation) => operation.roomToken.equals('roomb456'));
      final pending = await pendingQuery.get();
      expect(accountARooms.map((room) => room.token).toSet(), {'rooma123'});
      expect(accountBRooms.map((room) => room.token), ['roomb456']);
      expect(pending.single.message, 'Pending stale-room message');
      expect(conversationRequests, 3);
      expect(modifiedSinceValues, [null, '1724300001', null]);
    },
  );

  test(
    'force-full waiters coalesce after an in-flight incremental sync',
    () async {
      final fullResponse =
          readFixtureJson(
                'conversation-list/fixtures/conversations-full.response.json',
              )
              as Map<String, Object?>;
      final incrementalStarted = Completer<void>();
      final releaseIncremental = Completer<void>();
      addTearDown(() {
        if (!releaseIncremental.isCompleted) {
          releaseIncremental.complete();
        }
      });
      final modifiedSinceValues = <String?>[];
      var conversationRequests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(jsonEncode(capabilitiesJson()), 200);
          }
          conversationRequests++;
          modifiedSinceValues.add(request.url.queryParameters['modifiedSince']);
          if (conversationRequests == 2) {
            incrementalStarted.complete();
            await releaseIncremental.future;
          }
          return http.Response(
            jsonEncode(fullResponse),
            200,
            headers: <String, String>{
              'X-Nextcloud-Talk-Hash': 'fixture-hash-a',
              'X-Nextcloud-Talk-Modified-Before':
                  switch (conversationRequests) {
                    1 => '1724300001',
                    2 => '1724300101',
                    _ => '1724300201',
                  },
              'X-Nextcloud-Talk-Federation-Invites': '0',
            },
          );
        }),
      );
      addTearDown(api.close);
      final service = ConversationSyncService(
        accounts: repository,
        credentials: vault,
        api: api,
      );

      await service.sync('account-a');
      final incremental = service.sync('account-a');
      await incrementalStarted.future;
      final firstFull = service.sync('account-a', forceFull: true);
      final secondFull = service.sync('account-a', forceFull: true);
      releaseIncremental.complete();

      await Future.wait<void>([incremental, firstFull, secondFull]);
      expect(conversationRequests, 3);
      expect(modifiedSinceValues, [null, '1724300001', null]);
    },
  );

  test('force-full waiter retries after an incremental flight fails', () async {
    final fullResponse =
        readFixtureJson(
              'conversation-list/fixtures/conversations-full.response.json',
            )
            as Map<String, Object?>;
    final incrementalStarted = Completer<void>();
    final releaseIncremental = Completer<void>();
    addTearDown(() {
      if (!releaseIncremental.isCompleted) {
        releaseIncremental.complete();
      }
    });
    final modifiedSinceValues = <String?>[];
    var conversationRequests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(jsonEncode(capabilitiesJson()), 200);
        }
        conversationRequests++;
        modifiedSinceValues.add(request.url.queryParameters['modifiedSince']);
        if (conversationRequests == 2) {
          incrementalStarted.complete();
          await releaseIncremental.future;
          throw http.ClientException('network unavailable');
        }
        return http.Response(
          jsonEncode(fullResponse),
          200,
          headers: <String, String>{
            'X-Nextcloud-Talk-Hash': 'fixture-hash-a',
            'X-Nextcloud-Talk-Modified-Before': conversationRequests == 1
                ? '1724300001'
                : '1724300201',
            'X-Nextcloud-Talk-Federation-Invites': '0',
          },
        );
      }),
    );
    addTearDown(api.close);
    final service = ConversationSyncService(
      accounts: repository,
      credentials: vault,
      api: api,
    );

    await service.sync('account-a');
    final incremental = service.sync('account-a');
    await incrementalStarted.future;
    final full = service.sync('account-a', forceFull: true);
    final incrementalExpectation = expectLater(
      incremental,
      throwsA(
        isA<ConversationSyncException>().having(
          (error) => error.code,
          'code',
          ConversationSyncError.network,
        ),
      ),
    );
    releaseIncremental.complete();

    await incrementalExpectation;
    await full;
    final account = await repository.getAccount('account-a');
    expect(account?.lastSyncError, isNull);
    expect(conversationRequests, 3);
    expect(modifiedSinceValues, [null, '1724300001', null]);
  });

  test('guarded empty confirmation remains full on both attempts', () async {
    final fullResponse =
        readFixtureJson(
              'conversation-list/fixtures/conversations-full.response.json',
            )
            as Map<String, Object?>;
    final emptyResponse =
        readFixtureJson(
              'conversation-list/fixtures/conversations-empty.response.json',
            )
            as Map<String, Object?>;
    final modifiedSinceValues = <String?>[];
    var conversationRequests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(jsonEncode(capabilitiesJson()), 200);
        }
        conversationRequests++;
        modifiedSinceValues.add(request.url.queryParameters['modifiedSince']);
        return http.Response(
          jsonEncode(conversationRequests == 1 ? fullResponse : emptyResponse),
          200,
          headers: <String, String>{
            'X-Nextcloud-Talk-Hash': 'fixture-hash-a',
            'X-Nextcloud-Talk-Modified-Before': switch (conversationRequests) {
              1 => '1724300001',
              2 => '1724300101',
              _ => '1724300201',
            },
            'X-Nextcloud-Talk-Federation-Invites': '0',
          },
        );
      }),
    );
    addTearDown(api.close);
    final service = ConversationSyncService(
      accounts: repository,
      credentials: vault,
      api: api,
    );

    await service.sync('account-a');
    await service.sync('account-a', forceFull: true);

    final rooms = await repository.watchConversations('account-a').first;
    final account = await repository.getAccount('account-a');
    expect(rooms, isEmpty);
    expect(account?.emptyConfirmationRequestId, isNull);
    expect(conversationRequests, 3);
    expect(modifiedSinceValues, [null, null, null]);
  });

  test(
    'background cancellation does not cancel an attached manual refresh',
    () async {
      final client = _ControlledConversationClient(
        readFixtureJson(
              'conversation-list/fixtures/conversations-full.response.json',
            )
            as Map<String, Object?>,
      );
      addTearDown(() {
        if (!client.releaseFirstCapabilities.isCompleted) {
          client.releaseFirstCapabilities.complete();
        }
      });
      final api = HttpNextcloudApi(client: client);
      addTearDown(api.close);
      final service = ConversationSyncService(
        accounts: repository,
        credentials: vault,
        api: api,
      );
      final backgroundCancellation = Completer<void>();

      final background = service.sync(
        'account-a',
        abortTrigger: backgroundCancellation.future,
      );
      await client.firstCapabilitiesStarted.future;
      final manual = service.sync('account-a');

      backgroundCancellation.complete();
      await background.timeout(const Duration(seconds: 1));
      expect(client.transportCancellations, 0);

      client.releaseFirstCapabilities.complete();
      await manual;
      expect(client.conversationRequests, 1);
    },
  );

  test(
    'background waiter stops without owning a manual-first flight',
    () async {
      final client = _ControlledConversationClient(
        readFixtureJson(
              'conversation-list/fixtures/conversations-full.response.json',
            )
            as Map<String, Object?>,
      );
      addTearDown(() {
        if (!client.releaseFirstCapabilities.isCompleted) {
          client.releaseFirstCapabilities.complete();
        }
      });
      final api = HttpNextcloudApi(client: client);
      addTearDown(api.close);
      final service = ConversationSyncService(
        accounts: repository,
        credentials: vault,
        api: api,
      );
      final backgroundCancellation = Completer<void>();
      var manualFinished = false;

      final manual = service.sync('account-a');
      manual.whenComplete(() => manualFinished = true).ignore();
      await client.firstCapabilitiesStarted.future;
      final background = service.sync(
        'account-a',
        abortTrigger: backgroundCancellation.future,
      );

      backgroundCancellation.complete();
      await background.timeout(const Duration(seconds: 1));
      expect(manualFinished, isFalse);
      expect(client.transportCancellations, 0);

      client.releaseFirstCapabilities.complete();
      await manual;
      expect(manualFinished, isTrue);
      expect(client.conversationRequests, 1);
    },
  );

  test('capabilities 401 enters the reauthentication lane', () async {
    var requests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        requests++;
        expect(request.url.path, endsWith('/cloud/capabilities'));
        return http.Response('', 401);
      }),
    );
    addTearDown(api.close);
    final service = ConversationSyncService(
      accounts: repository,
      credentials: vault,
      api: api,
    );

    await expectLater(
      service.sync('account-a'),
      throwsA(
        isA<ConversationSyncException>().having(
          (error) => error.code,
          'code',
          ConversationSyncError.reauthenticationRequired,
        ),
      ),
    );

    final account = await repository.getAccount('account-a');
    expect(
      account?.lastSyncError,
      ConversationSyncError.reauthenticationRequired.name,
    );
    await expectLater(
      service.sync('account-a'),
      throwsA(
        isA<ConversationSyncException>().having(
          (error) => error.code,
          'code',
          ConversationSyncError.reauthenticationRequired,
        ),
      ),
    );
    expect(requests, 1, reason: 'durable re-auth state must stop retry loops');
  });

  test('transport cancellation stops without persisting an error', () async {
    final started = Completer<void>();
    final cancellation = Completer<void>();
    final api = HttpNextcloudApi(client: _AbortAwareClient(started));
    addTearDown(api.close);
    final service = ConversationSyncService(
      accounts: repository,
      credentials: vault,
      api: api,
    );

    final sync = service.sync('account-a', abortTrigger: cancellation.future);
    await started.future;
    cancellation.complete();
    await sync;

    final account = await repository.getAccount('account-a');
    expect(account?.lastSyncError, isNull);
  });

  test(
    'live transport accepts the reference conversation wire profile',
    () async {
      final api = HttpNextcloudApi();
      addTearDown(api.close);
      final server = ServerBase.parse(
        Platform.environment['NEXTCLOUD_TALK_ORIGIN']!,
      );
      final username = Platform.environment['NEXTCLOUD_TALK_USERNAME']!;
      final appPassword = Platform.environment['NEXTCLOUD_TALK_APP_PASSWORD']!;
      final capabilities = await api.getAuthenticatedCapabilities(
        server: server,
        loginName: username,
        appPassword: appPassword,
      );
      expect(capabilities.supportsTalk('conversation-v4'), isTrue);

      final response = await api.getConversations(
        conversationRequest: ConversationListRequest(
          accountId: AccountId.parse('live-account'),
          requestId: ConversationRequestId.parse('live-full-request'),
          server: server,
          mode: ConversationFetchMode.full,
          includeLastMessage: true,
          includeStatus: true,
        ),
        loginName: username,
        appPassword: appPassword,
      );

      expect(response, isA<ConversationListSuccess>());
      expect((response as ConversationListSuccess).rooms, isNotEmpty);
    },
    skip:
        Platform.environment['NEXTCLOUD_TALK_ORIGIN'] == null ||
            Platform.environment['NEXTCLOUD_TALK_USERNAME'] == null ||
            Platform.environment['NEXTCLOUD_TALK_APP_PASSWORD'] == null
        ? 'Live Nextcloud credentials are not configured.'
        : false,
  );
}

const _giphyResourceUrl = 'https://giphy.com/gifs/waving-cat-fixture123';

final class _TemporarilyUnavailableCredentialVault implements CredentialVault {
  const _TemporarilyUnavailableCredentialVault();

  @override
  Future<void> deleteAppPassword(String accountId) async {}

  @override
  Future<String?> readAppPassword(String accountId) {
    throw const CredentialVaultTemporarilyUnavailable();
  }

  @override
  Future<void> writeAppPassword(String accountId, String appPassword) async {}
}

final class _AbortAwareClient extends http.BaseClient {
  _AbortAwareClient(this.started);

  final Completer<void> started;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request, isA<http.Abortable>());
    if (!started.isCompleted) {
      started.complete();
    }
    await (request as http.Abortable).abortTrigger;
    throw http.RequestAbortedException(request.url);
  }
}

final class _ControlledConversationClient extends http.BaseClient {
  _ControlledConversationClient(this.conversationResponse);

  final Map<String, Object?> conversationResponse;
  final Completer<void> firstCapabilitiesStarted = Completer<void>();
  final Completer<void> releaseFirstCapabilities = Completer<void>();
  int transportCancellations = 0;
  int conversationRequests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/cloud/capabilities')) {
      expect(request, isA<http.Abortable>());
      if (!firstCapabilitiesStarted.isCompleted) {
        firstCapabilitiesStarted.complete();
      }
      final transportAbort = (request as http.Abortable).abortTrigger;
      expect(transportAbort, isNotNull);
      var cancelled = false;
      await Future.any<void>([
        releaseFirstCapabilities.future,
        transportAbort!.then<void>((_) {
          cancelled = true;
        }),
      ]);
      if (cancelled) {
        transportCancellations++;
        throw http.RequestAbortedException(request.url);
      }
      return _jsonResponse(capabilitiesJson());
    }

    conversationRequests++;
    return _jsonResponse(
      conversationResponse,
      headers: const <String, String>{
        'X-Nextcloud-Talk-Hash': 'fixture-hash-a',
        'X-Nextcloud-Talk-Modified-Before': '1724300001',
        'X-Nextcloud-Talk-Federation-Invites': '0',
      },
    );
  }

  http.StreamedResponse _jsonResponse(
    Map<String, Object?> body, {
    Map<String, String> headers = const <String, String>{},
  }) {
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
      200,
      headers: headers,
    );
  }
}
