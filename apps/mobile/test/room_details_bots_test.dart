import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_background_surface.dart';
import 'package:nextcloudtalk/features/rooms/bots_service.dart';
import 'package:nextcloudtalk/features/rooms/room_details_screen.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;
  late StoredAccount account;
  late CachedConversation conversation;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault()..values['account-a'] = 'fixture-password';
    account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {'bots-v1'},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final roomJson = _roomJson()
      ..['participantType'] = 1
      ..['attributes'] = 0;
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
    conversation = await database
        .select(database.cachedConversations)
        .getSingle();
  });

  tearDown(() => database.close());

  Future<void> replaceRoom({
    required int participantType,
    int attributes = 0,
  }) async {
    await database.delete(database.cachedConversations).go();
    final roomJson = _roomJson()
      ..['participantType'] = participantType
      ..['attributes'] = attributes;
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
    conversation = await database
        .select(database.cachedConversations)
        .getSingle();
  }

  test(
    'service reloads account origin and credential for every call',
    () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return _ocs([
            {'id': 17, 'name': 'Assistant', 'description': null, 'state': 0},
          ]);
        }
        final enabled = request.method == 'POST';
        return _ocs({
          'id': 17,
          'name': 'Assistant',
          'description': null,
          'state': enabled ? 1 : 0,
        }, statusCode: enabled ? 201 : 200);
      });
      final service = BotsService(
        accounts: accounts,
        credentials: vault,
        api: HttpNextcloudApi(client: client),
      );

      await service.fetchBots(
        accountId: account.id,
        roomToken: conversation.token,
      );
      account = await accounts.upsertAccount(
        accountId: account.id,
        serverUrl: 'https://fresh.example.invalid/subdir',
        loginName: 'fresh-user',
        serverProductName: 'Nextcloud',
        talkFeatures: const {'bots-v1'},
        createdAt: DateTime.utc(2026, 1, 2),
      );
      vault.values[account.id] = 'fresh-password';
      final updated = await service.setEnabled(
        accountId: account.id,
        roomToken: conversation.token,
        botId: 17,
        enabled: true,
      );
      final disabled = await service.setEnabled(
        accountId: account.id,
        roomToken: conversation.token,
        botId: 17,
        enabled: false,
      );

      expect(updated.state, BotState.enabled);
      expect(disabled.state, BotState.disabled);
      expect(requests.map((request) => request.url.host), [
        'cloud.example.invalid',
        'fresh.example.invalid',
        'fresh.example.invalid',
      ]);
      expect(
        requests.last.headers['authorization'],
        'Basic ${base64Encode(utf8.encode('fresh-user:fresh-password'))}',
      );
      expect(requests[1].method, 'POST');
      expect(requests.last.method, 'DELETE');
      expect(requests.last.url.path, contains('/subdir/ocs/'));
    },
  );

  test('service fails closed without the fresh bots capability', () async {
    var requests = 0;
    final service = BotsService(
      accounts: accounts,
      credentials: vault,
      api: HttpNextcloudApi(
        client: MockClient((request) async {
          requests++;
          return _ocs(const <Object?>[]);
        }),
      ),
    );
    await accounts.updateTalkFeatures(account.id, const <String>{});

    await expectLater(
      service.fetchBots(accountId: account.id, roomToken: conversation.token),
      throwsA(
        isA<BotsServiceException>().having(
          (error) => error.code,
          'code',
          BotsServiceError.unsupported,
        ),
      ),
    );
    expect(requests, 0);
  });

  test(
    'service revalidates room role and classification before mutations',
    () async {
      var mutationRequests = 0;
      final service = BotsService(
        accounts: accounts,
        credentials: vault,
        api: HttpNextcloudApi(
          client: MockClient((request) async {
            if (request.method == 'GET') {
              return _ocs([
                {
                  'id': 17,
                  'name': 'Assistant',
                  'description': null,
                  'state': 0,
                },
              ]);
            }
            mutationRequests++;
            return _ocs({
              'id': 17,
              'name': 'Assistant',
              'description': null,
              'state': 1,
            }, statusCode: 201);
          }),
        ),
      );
      await service.fetchBots(
        accountId: account.id,
        roomToken: conversation.token,
      );

      await replaceRoom(participantType: 3);
      await expectLater(
        service.setEnabled(
          accountId: account.id,
          roomToken: conversation.token,
          botId: 17,
          enabled: true,
        ),
        throwsA(
          isA<BotsServiceException>().having(
            (error) => error.code,
            'code',
            BotsServiceError.forbidden,
          ),
        ),
      );
      await replaceRoom(participantType: 1, attributes: 4);
      await expectLater(
        service.setEnabled(
          accountId: account.id,
          roomToken: conversation.token,
          botId: 17,
          enabled: true,
        ),
        throwsA(
          isA<BotsServiceException>().having(
            (error) => error.code,
            'code',
            BotsServiceError.forbidden,
          ),
        ),
      );
      expect(mutationRequests, 0);
    },
  );

  test('bot text and controls keep contrast in both production themes', () {
    for (final theme in <ThemeData>[AppTheme.light(), AppTheme.dark()]) {
      final scheme = theme.colorScheme;
      expect(
        _contrast(scheme.onSurface, scheme.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(scheme.onSurfaceVariant, scheme.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(scheme.primary, scheme.surface),
        greaterThanOrEqualTo(3),
      );
    }
  });

  testWidgets('owner loads bots only after expanding the bot section', (
    tester,
  ) async {
    var botRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocs(const <Object?>[]);
      }
      if (request.url.path.endsWith('/bot/${conversation.token}')) {
        botRequests++;
        return _ocs([
          {
            'id': 17,
            'name': 'Assistant',
            'description': 'Answers questions',
            'state': 0,
          },
        ]);
      }
      return _ocs(null, statusCode: 404, status: 'failure');
    });

    await _openBotDetails(
      tester,
      client: client,
      database: database,
      vault: vault,
      account: account,
      conversation: conversation,
    );

    expect(find.byKey(const Key('room-details-bots')), findsOneWidget);
    expect(botRequests, 0);
    await tester.tap(find.byKey(const Key('room-details-bots')));
    await _pumpUntil(
      tester,
      () => find.text('Assistant').evaluate().isNotEmpty,
    );
    expect(botRequests, 1);
    expect(find.text('Answers questions'), findsOneWidget);
    expect(find.byKey(const Key('room-details-bot-17')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('room-details-bot-17'))).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('bot content remains usable at 200 percent text scale', (
    tester,
  ) async {
    await _openBotDetails(
      tester,
      client: _roomClient([
        {
          'id': 17,
          'name': 'Conversation assistant with a descriptive name',
          'description':
              'A longer description that wraps instead of clipping at large text.',
          'state': 0,
        },
      ]),
      database: database,
      vault: vault,
      account: account,
      conversation: conversation,
      textScaler: const TextScaler.linear(2),
    );
    await tester.tap(find.byKey(const Key('room-details-bots')));
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('room-details-bot-17')).evaluate().isNotEmpty,
    );

    expect(tester.takeException(), equals(null));
    expect(
      tester.getSize(find.byKey(const Key('room-details-bot-17'))).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('reverse mutation completion preserves both bot updates', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final first = Completer<http.Response>();
    final second = Completer<http.Response>();
    var mutationRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocs(const <Object?>[]);
      }
      if (request.method == 'GET' && request.url.path.contains('/bot/')) {
        return _ocs([
          {'id': 17, 'name': 'Assistant', 'description': null, 'state': 0},
          {'id': 18, 'name': 'Recorder', 'description': null, 'state': 0},
        ]);
      }
      mutationRequests++;
      return request.url.path.endsWith('/17') ? first.future : second.future;
    });
    await _openBotDetails(
      tester,
      client: client,
      database: database,
      vault: vault,
      account: account,
      conversation: conversation,
    );
    await tester.tap(find.byKey(const Key('room-details-bots')));
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('room-details-bot-18')).evaluate().isNotEmpty,
    );

    for (final id in const <int>[17, 18]) {
      final tile = tester.widget<SwitchListTile>(
        find.byKey(Key('room-details-bot-$id')),
      );
      tile.onChanged!(true);
      await tester.pump();
    }
    await _pumpUntil(tester, () => mutationRequests == 2);
    expect(find.bySemanticsLabel('Updating bot…'), findsNWidgets(2));

    second.complete(
      _ocs({
        'id': 18,
        'name': 'Recorder',
        'description': null,
        'state': 1,
      }, statusCode: 201),
    );
    await _pumpUntil(tester, () => _botEnabled(tester, 18));
    first.complete(
      _ocs({
        'id': 17,
        'name': 'Assistant',
        'description': null,
        'state': 1,
      }, statusCode: 201),
    );
    await _pumpUntil(
      tester,
      () => _botEnabled(tester, 17) && _botEnabled(tester, 18),
    );
    semantics.dispose();
  });

  testWidgets('mutation forbidden response hides bot management', (
    tester,
  ) async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocs(const <Object?>[]);
      }
      if (request.method == 'GET') {
        return _ocs([
          {'id': 17, 'name': 'Assistant', 'description': null, 'state': 0},
        ]);
      }
      return _ocs(null, statusCode: 403, status: 'failure');
    });
    await _openBotDetails(
      tester,
      client: client,
      database: database,
      vault: vault,
      account: account,
      conversation: conversation,
    );
    await tester.tap(find.byKey(const Key('room-details-bots')));
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('room-details-bot-17')).evaluate().isNotEmpty,
    );
    tester
        .widget<SwitchListTile>(find.byKey(const Key('room-details-bot-17')))
        .onChanged!(true);
    await tester.pump();

    await _pumpUntil(
      tester,
      () => find.byKey(const Key('room-details-bots')).evaluate().isEmpty,
    );
  });

  testWidgets('guest moderator and classified owner cannot manage bots', (
    tester,
  ) async {
    final client = _roomClient(const <Object?>[]);
    await replaceRoom(participantType: 6);
    await _openBotDetails(
      tester,
      client: client,
      database: database,
      vault: vault,
      account: account,
      conversation: conversation,
    );
    expect(find.byKey(const Key('room-details-bots')), findsNothing);

    await replaceRoom(participantType: 1, attributes: 4);
    await tester.pumpWidget(const SizedBox.shrink());
    await _openBotDetails(
      tester,
      client: client,
      database: database,
      vault: vault,
      account: account,
      conversation: conversation,
    );
    expect(find.byKey(const Key('room-details-bots')), findsNothing);
  });

  testWidgets('bot load error ends and retry shows the empty state', (
    tester,
  ) async {
    var attempts = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocs(const <Object?>[]);
      }
      if (request.url.path.contains('/bot/')) {
        attempts++;
        return attempts == 1 ? http.Response('', 503) : _ocs(const <Object?>[]);
      }
      return _ocs(null, statusCode: 404, status: 'failure');
    });
    await _openBotDetails(
      tester,
      client: client,
      database: database,
      vault: vault,
      account: account,
      conversation: conversation,
    );
    await tester.tap(find.byKey(const Key('room-details-bots')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-bots-error'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.byKey(const Key('room-details-bots-loading')), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('room-details-bots-retry'))).height,
      greaterThanOrEqualTo(44),
    );

    await _tapVisible(tester, find.byKey(const Key('room-details-bots-retry')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-bots-empty'))
          .evaluate()
          .isNotEmpty,
    );
    expect(attempts, 2);
  });

  testWidgets('switch applies authoritative state and no-setup stays fixed', (
    tester,
  ) async {
    final mutationMethods = <String>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocs(const <Object?>[]);
      }
      if (request.method == 'GET' && request.url.path.contains('/bot/')) {
        return _ocs([
          {
            'id': 17,
            'name': 'Assistant',
            'description': 'Answers questions',
            'state': 0,
          },
          {'id': 18, 'name': 'Bridge', 'description': null, 'state': 2},
        ]);
      }
      if (request.method == 'POST' && request.url.path.endsWith('/17')) {
        mutationMethods.add(request.method);
        return _ocs({
          'id': 17,
          'name': 'Assistant',
          'description': 'Answers questions',
          'state': 1,
        }, statusCode: 201);
      }
      if (request.method == 'DELETE' && request.url.path.endsWith('/17')) {
        mutationMethods.add(request.method);
        return _ocs({
          'id': 17,
          'name': 'Assistant',
          'description': 'Answers questions',
          'state': 0,
        });
      }
      return _ocs(null, statusCode: 404, status: 'failure');
    });
    await _openBotDetails(
      tester,
      client: client,
      database: database,
      vault: vault,
      account: account,
      conversation: conversation,
    );
    await tester.tap(find.byKey(const Key('room-details-bots')));
    await _pumpUntil(
      tester,
      () => find.text('Assistant').evaluate().isNotEmpty,
    );

    final fixed = tester.widget<SwitchListTile>(
      find.byKey(const Key('room-details-bot-18')),
    );
    expect(fixed.value, isTrue);
    expect(fixed.onChanged, isNull);
    await _tapVisible(tester, find.byKey(const Key('room-details-bot-17')));
    await _pumpUntil(tester, () {
      final finder = find.byKey(const Key('room-details-bot-17'));
      if (finder.evaluate().isEmpty) {
        return false;
      }
      final tile = tester.widget<SwitchListTile>(finder);
      return tile.value;
    });
    await _tapVisible(tester, find.byKey(const Key('room-details-bot-17')));
    await _pumpUntil(tester, () {
      final finder = find.byKey(const Key('room-details-bot-17'));
      if (finder.evaluate().isEmpty) {
        return false;
      }
      return !tester.widget<SwitchListTile>(finder).value;
    });
    expect(mutationMethods, ['POST', 'DELETE']);
  });
}

Future<void> _openBotDetails(
  WidgetTester tester, {
  required http.Client client,
  required AppDatabase database,
  required MemoryCredentialVault vault,
  required StoredAccount account,
  required CachedConversation conversation,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 2600);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(
          HttpNextcloudApi(client: client),
        ),
        chatBackgroundProvider.overrideWith(
          (ref, key) => Stream<String?>.value(null),
        ),
        chatAttachmentDependenciesProvider.overrideWith(
          (ref, key) => Future<ChatAttachmentDependencies>.error(
            StateError('not used'),
            StackTrace.empty,
          ),
        ),
      ],
      child: localizedTestApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: textScaler),
          child: RoomDetailsScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      ),
    ),
  );
  await _pumpUntil(
    tester,
    () => find
        .byKey(const Key('room-details-notification-picker'))
        .evaluate()
        .isNotEmpty,
  );
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

http.Response _ocs(
  Object? data, {
  int statusCode = 200,
  String status = 'ok',
  int? metaStatusCode,
}) {
  return http.Response(
    jsonEncode({
      'ocs': {
        'meta': {
          'status': status,
          'statuscode': metaStatusCode ?? (status == 'ok' ? 200 : statusCode),
          'message': 'OK',
        },
        'data': data,
      },
    }),
    statusCode,
  );
}

http.Client _roomClient(Object? bots) {
  return MockClient((request) async {
    if (request.url.path.endsWith('/participants')) {
      return _ocs(const <Object?>[]);
    }
    if (request.url.path.contains('/bot/')) {
      return _ocs(bots);
    }
    return _ocs(null, statusCode: 404, status: 'failure');
  });
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  fail('Condition was not reached');
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

bool _botEnabled(WidgetTester tester, int botId) {
  final finder = find.byKey(Key('room-details-bot-$botId'));
  return finder.evaluate().isNotEmpty &&
      tester.widget<SwitchListTile>(finder).value;
}

double _contrast(Color first, Color second) {
  final firstLuminance = first.computeLuminance();
  final secondLuminance = second.computeLuminance();
  final lighter = firstLuminance > secondLuminance
      ? firstLuminance
      : secondLuminance;
  final darker = firstLuminance > secondLuminance
      ? secondLuminance
      : firstLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}
