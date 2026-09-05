import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/core/background_drain.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/chat/attachment_service.dart';
import 'package:nextcloudtalk/features/chat/chat_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

const _channelName = 'com.nkshub.nextcloudtalk/background_drain';
const _talkFeatures = <String>{
  'conversation-v4',
  'chat-v2',
  'chat-reference-id',
};

/// Records what the platform side would have been asked to do.
final class _RecordingPlatform {
  final List<MethodCall> calls = <MethodCall>[];
  Object? Function(MethodCall call)? answer;

  final MethodChannel channel = const MethodChannel(_channelName);

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return answer?.call(call);
        });
  }

  void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  /// Delivers what the platform's job would send inwards to the app engine.
  ///
  /// Not awaited: the job's own reply waits for the whole wake, including the
  /// upload resume that these tests deliberately leave hanging, while what is
  /// under test is the outbox work that happens first.
  void runDrain() {
    unawaited(
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            _channelName,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('runDrain'),
            ),
            (_) {},
          ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackgroundDrainSchedule', () {
    late _RecordingPlatform platform;

    setUp(() {
      platform = _RecordingPlatform()..install();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
    });

    tearDown(() {
      platform.remove();
      debugDefaultTargetPlatformOverride = null;
    });

    test('registers the wake once however often it is asked', () async {
      final schedule = BackgroundDrainSchedule(channel: platform.channel);

      await Future.wait<void>(<Future<void>>[
        schedule.ensure(),
        schedule.ensure(),
      ]);
      await schedule.ensure();

      expect(platform.calls.map((call) => call.method), <String>[
        'ensureScheduled',
      ]);
    });

    test('leaves desktop alone, where nothing is ever suspended', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await BackgroundDrainSchedule(channel: platform.channel).ensure();

      expect(platform.calls, isEmpty);
    });

    test('a platform that refuses the wake is not an app failure', () async {
      platform.answer = (_) =>
          throw PlatformException(code: 'unavailable', message: 'No scheduler');

      await expectLater(
        BackgroundDrainSchedule(channel: platform.channel).ensure(),
        completes,
      );
    });
  });

  group('runBackgroundDrainIsolate', () {
    late _RecordingPlatform platform;

    setUp(() => platform = _RecordingPlatform()..install());
    tearDown(() => platform.remove());

    test('reports a finished drain so the job can end', () async {
      var drained = 0;

      await runBackgroundDrainIsolate(
        drain: () async => drained++,
        channel: platform.channel,
      );

      expect(drained, 1);
      expect(platform.calls.single.method, 'finished');
      expect(platform.calls.single.arguments, <String, Object?>{
        'retry': false,
      });
    });

    test('asks for a reschedule when the drain threw', () async {
      await runBackgroundDrainIsolate(
        drain: () async => throw StateError('no network'),
        channel: platform.channel,
      );

      expect(platform.calls.single.arguments, <String, Object?>{'retry': true});
    });
  });

  group('a scheduled wake reaching a running app', () {
    late AppDatabase database;
    late AccountRepository accounts;
    late ChatRepository chat;
    late MemoryCredentialVault credentials;
    late _RecordingPlatform platform;
    late Completer<AttachmentService> attachments;

    setUp(() async {
      database = openTestDatabase();
      accounts = AccountRepository(database);
      chat = ChatRepository(database);
      credentials = MemoryCredentialVault();
      platform = _RecordingPlatform()..install();
      attachments = Completer<AttachmentService>();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final account = await accounts.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://cloud.example.invalid',
        loginName: 'fixture-user',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      credentials.values[account.id] = 'fixture-app-password-never-use';
      await _cacheConversation(database, accountId: account.id);
      await accounts.updateTalkFeatures('account-a', _talkFeatures);
      await chat.recordCapabilities(
        accountId: 'account-a',
        talkFeatures: _talkFeatures,
        observedAt: DateTime.utc(2026, 1, 1),
      );
    });

    tearDown(() async {
      platform.remove();
      debugDefaultTargetPlatformOverride = null;
      await database.close();
    });

    /// Queues one message the way a tunnel does: the send is admitted from the
    /// stored capability snapshot and then fails to reach the server.
    Future<void> queueOfflineSend() async {
      final offline = HttpNextcloudApi(
        client: MockClient(
          (request) async => throw http.ClientException('offline', request.url),
        ),
      );
      addTearDown(offline.close);
      await ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: offline,
      ).sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'Queued while offline',
      );
      expect(
        (await database.select(database.textSendOperations).getSingle())
            .outboxState,
        'queued',
      );
    }

    ProviderContainer runningApp({
      required http.Client client,
      ChatService Function(ChatService service)? tap,
    }) {
      final api = HttpNextcloudApi(client: client);
      addTearDown(api.close);
      final container = ProviderContainer(
        overrides: <Override>[
          appDatabaseProvider.overrideWithValue(database),
          credentialVaultProvider.overrideWithValue(credentials),
          nextcloudApiProvider.overrideWithValue(api),
          connectivityWakeEventsProvider.overrideWithValue(
            const Stream<void>.empty(),
          ),
          appLifecycleResumeEventsProvider.overrideWithValue(
            const Stream<void>.empty(),
          ),
          // Held open on purpose: the outbox is drained before the wake gets
          // this far, so the sends are observable without a real upload
          // runtime standing behind the provider.
          attachmentServiceProvider.overrideWith((ref) => attachments.future),
          if (tap != null)
            chatServiceProvider.overrideWith(
              (ref) => tap(
                ChatService(
                  accounts: ref.watch(accountRepositoryProvider),
                  chat: ref.watch(chatRepositoryProvider),
                  credentials: ref.watch(credentialVaultProvider),
                  api: ref.watch(nextcloudApiProvider),
                ),
              ),
            ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('delivers what the outbox still holds', () async {
      var sends = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(capabilitiesJson(talkFeatures: _talkFeatures.toList())),
            200,
          );
        }
        if (request.method == 'GET') {
          return http.Response('', 304);
        }
        sends++;
        final fixture =
            readFixtureJson(
                  'chat-messages/fixtures/send-success.response.json',
                )!
                as Map<String, Object?>;
        final data =
            (fixture['ocs']! as Map<String, Object?>)['data']!
                as Map<String, Object?>;
        data['referenceId'] = request.bodyFields['referenceId'];
        data['message'] = request.bodyFields['message'];
        return http.Response(
          jsonEncode(fixture),
          201,
          headers: const <String, String>{'X-Chat-Last-Common-Read': '110'},
        );
      });
      addTearDown(client.close);
      final container = runningApp(client: client);

      // The app has been up and idle for a while: its own start-up drain
      // already ran and found nothing, which is exactly the state a phone is
      // in when its owner queues a message and pockets it.
      container.read(outboxDrainProvider);
      await pumpEventQueue(times: 200);
      await queueOfflineSend();
      sends = 0;

      platform.runDrain();
      await pumpEventQueue(times: 200);

      expect(sends, 1);
      expect(
        (await database.select(database.textSendOperations).getSingle())
            .outboxState,
        'completed',
      );
    });

    test('a suspended account keeps its rows and sends nothing', () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return http.Response('', 304);
      });
      addTearDown(client.close);
      late ChatService service;
      final container = runningApp(
        client: client,
        tap: (created) => service = created,
      );

      container.read(outboxDrainProvider);
      await pumpEventQueue(times: 200);
      await queueOfflineSend();
      await service.suspendAccount('account-a');
      requests = 0;

      platform.runDrain();
      await pumpEventQueue(times: 200);

      expect(requests, 0);
      expect(
        (await database.select(database.textSendOperations).getSingle())
            .outboxState,
        'queued',
      );
    });

    test('the app registers its wake with the platform on start', () async {
      final client = MockClient((_) async => http.Response('', 304));
      addTearDown(client.close);
      final container = runningApp(client: client);

      container.read(outboxDrainProvider);
      await pumpEventQueue();

      expect(
        platform.calls.map((call) => call.method),
        contains('ensureScheduled'),
      );
    });
  });
}

Future<void> _cacheConversation(
  AppDatabase database, {
  required String accountId,
}) async {
  final root =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final rooms =
      (root['ocs']! as Map<String, Object?>)['data']! as List<Object?>;
  final roomJson = Map<String, Object?>.from(
    rooms.first! as Map<String, Object?>,
  );
  final room = ConversationRoom.fromJson(roomJson);
  await database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: accountId,
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
}
