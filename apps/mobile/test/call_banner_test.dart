import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/call_session_repository.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/calls/call_banner.dart';
import 'package:nextcloudtalk/features/calls/call_join_controller.dart';
import 'package:nextcloudtalk/features/calls/call_lifecycle_controller.dart';
import 'package:nextcloudtalk/features/calls/call_lifecycle_service.dart';
import 'package:nextcloudtalk/features/calls/call_media_session.dart';
import 'package:nextcloudtalk/features/calls/call_transport_service.dart';
import 'package:nextcloudtalk/features/conversations/conversation_list_actions.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;
  late StoredAccount account;

  final callStart = DateTime.utc(2026, 8, 25, 10);

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault()..values['account-a'] = 'fixture-password';
    account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 1, 1),
    );
  });

  tearDown(() => database.close());

  CachedConversation conversation({
    bool hasCall = true,
    bool withStart = true,
    String token = 'rooma123',
  }) {
    return CachedConversation(
      accountId: 'account-a',
      token: token,
      displayName: 'Synthetic room A',
      description: '',
      lastActivity: 1724300000,
      unreadMessages: 0,
      favorite: false,
      isArchived: false,
      readOnly: 0,
      roomType: 2,
      roomName: 'synthetic-room-a',
      objectType: '',
      avatarVersion: '',
      isCustomAvatar: false,
      rawJson: jsonEncode(<String, Object?>{
        'hasCall': hasCall,
        if (withStart)
          'callStartTime': callStart.millisecondsSinceEpoch ~/ 1000,
      }),
    );
  }

  Widget banner({
    required CachedConversation room,
    required CallTransport transport,
    required DateTime Function() now,
    void Function()? onLifecycleRead,
  }) {
    return ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(vault),
        callTransportProvider.overrideWith((ref, key) async => transport),
        callLifecycleStatusProvider.overrideWith((ref, key) async {
          onLifecycleRead?.call();
          return _readyLifecycle(key);
        }),
      ],
      child: localizedTestApp(
        home: Scaffold(
          body: OngoingCallBanner(
            account: account,
            conversation: room,
            now: now,
          ),
        ),
      ),
    );
  }

  testWidgets('no banner without a server-reported call', (tester) async {
    var lifecycleReads = 0;
    await tester.pumpWidget(
      banner(
        room: conversation(hasCall: false),
        transport: CallTransport.internal,
        now: () => callStart,
        onLifecycleRead: () => lifecycleReads++,
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('call-banner')), findsNothing);
    expect(lifecycleReads, 0);
  });

  testWidgets('the duration keeps counting while the call runs', (
    tester,
  ) async {
    var now = callStart.add(const Duration(minutes: 2, seconds: 5));
    await tester.pumpWidget(
      banner(
        room: conversation(),
        transport: CallTransport.internal,
        now: () => now,
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('call-banner')), findsOneWidget);
    expect(find.text('02:05'), findsOneWidget);

    now = callStart.add(const Duration(minutes: 2, seconds: 6));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('02:06'), findsOneWidget);

    now = callStart.add(const Duration(hours: 1, seconds: 7));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1:00:07'), findsOneWidget);

    // The ticker must not outlive the banner.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a call without a start time shows no duration or ticker', (
    tester,
  ) async {
    await tester.pumpWidget(
      banner(
        room: conversation(withStart: false),
        transport: CallTransport.internal,
        now: () => callStart,
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('call-banner')), findsOneWidget);
    expect(find.byKey(const Key('call-banner-duration')), findsNothing);
  });

  testWidgets('a resolved transport offers a live join', (tester) async {
    var lifecycleReads = 0;
    await tester.pumpWidget(
      banner(
        room: conversation(),
        transport: CallTransport.externalHpb,
        now: () => callStart,
        onLifecycleRead: () => lifecycleReads++,
      ),
    );
    await tester.pump();

    expect(lifecycleReads, 1);
    final join = find.byKey(const Key('call-banner-join'));
    expect(join, findsOneWidget);
    expect(
      tester.widget<FilledButton>(join).onPressed,
      isNotNull,
      reason: 'media exists, so the button must act',
    );
    expect(
      find.text('The call runs through a separate call server.'),
      findsOneWidget,
      reason: 'the banner names the transport in words, not as an acronym',
    );
  });

  testWidgets('a join without a signalling session says so and stays idle', (
    tester,
  ) async {
    await tester.pumpWidget(
      banner(
        room: conversation(),
        transport: CallTransport.externalHpb,
        now: () => callStart,
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('call-banner-join')));
    await tester.pump();
    await tester.pump();

    expect(
      find.text(
        'The server has not opened a call in this conversation, '
        'so it cannot be joined.',
      ),
      findsOneWidget,
    );
    expect(find.text('Join call'), findsOneWidget);
  });

  testWidgets('an unresolved transport offers no join at all', (tester) async {
    await tester.pumpWidget(
      banner(
        room: conversation(),
        transport: CallTransport.reauthenticationRequired,
        now: () => callStart,
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('call-banner-join')), findsNothing);
    expect(
      find.text('Sign in again to see how this call is signalled.'),
      findsOneWidget,
    );
  });

  testWidgets('the banner says so while the transport is still unknown', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          credentialVaultProvider.overrideWithValue(vault),
          callTransportProvider.overrideWith(
            (ref, key) => Completer<CallTransport>().future,
          ),
          callLifecycleStatusProvider.overrideWith(
            (ref, key) async => _readyLifecycle(key),
          ),
        ],
        child: localizedTestApp(
          home: Scaffold(
            body: OngoingCallBanner(
              account: account,
              conversation: conversation(),
              now: () => callStart,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Checking how this call is signalled…'), findsOneWidget);
  });

  testWidgets('a lifecycle failure is localized and retry reloads the room', (
    tester,
  ) async {
    var transportAttempts = 0;
    var lifecycleAttempts = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          credentialVaultProvider.overrideWithValue(vault),
          callTransportProvider.overrideWith((ref, key) async {
            transportAttempts++;
            return transportAttempts == 1
                ? CallTransport.unavailable
                : CallTransport.internal;
          }),
          callLifecycleStatusProvider.overrideWith((ref, key) async {
            lifecycleAttempts++;
            if (lifecycleAttempts == 1) {
              throw const CallLifecycleException(
                CallLifecycleError.credentialMissing,
              );
            }
            return _readyLifecycle(key);
          }),
        ],
        child: localizedTestApp(
          home: Scaffold(
            body: OngoingCallBanner(
              account: account,
              conversation: conversation(),
              now: () => callStart,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text('Sign in again to see how this call is signalled.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('call-banner-join')), findsNothing);

    await tester.tap(find.byKey(const Key('call-banner-lifecycle-retry')));
    await tester.pump();
    await tester.pump();

    expect(transportAttempts, 2);
    expect(lifecycleAttempts, 2);
    expect(find.byKey(const Key('call-banner-join')), findsOneWidget);
    expect(find.byKey(const Key('call-banner-lifecycle-retry')), findsNothing);
  });

  testWidgets('a mismatched lifecycle result fails closed for the room', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          credentialVaultProvider.overrideWithValue(vault),
          callTransportProvider.overrideWith(
            (ref, key) async => CallTransport.internal,
          ),
          callLifecycleStatusProvider.overrideWith(
            (ref, key) async => _readyLifecycle((
              accountId: key.accountId,
              roomToken: 'another-room',
            )),
          ),
        ],
        child: localizedTestApp(
          home: Scaffold(
            body: OngoingCallBanner(
              account: account,
              conversation: conversation(),
              now: () => callStart,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('call-banner-join')), findsNothing);
    expect(
      find.text(
        'This call cannot be joined right now. Try again in a moment.',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('call-banner-lifecycle-retry')),
      findsOneWidget,
    );
  });

  testWidgets(
    'the banner runs durable recovery through the production provider',
    (tester) async {
      const features = <String>{
        'conversation-v4',
        'conversation-permissions',
        'in-call-flags',
        'silent-call',
        'recording-consent',
      };
      final conversationResponse = readFixtureJson(
        'conversation-list/fixtures/conversations-full.response.json',
      )!;
      var capabilityReads = 0;
      var conversationReads = 0;
      var callReads = 0;
      var callMutations = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            capabilityReads++;
            return http.Response(jsonEncode(_callCapabilities(features)), 200);
          }
          if (request.url.path.contains('/apps/spreed/api/v4/call/')) {
            if (request.method == 'GET') {
              callReads++;
            } else {
              callMutations++;
            }
            return _ocsResponse(<Object?>[
              <String, Object?>{
                'actorType': 'users',
                'actorId': 'fixture-user',
                'displayName': 'Fixture User',
                'token': 'rooma123',
                'lastPing': 1770000000,
                'sessionId': 'fixture-session-a',
              },
            ]);
          }
          if (request.url.path.endsWith('/participants/active')) {
            return request.method == 'DELETE'
                ? _ocsResponse(null)
                : _activeRoomResponse(conversationResponse);
          }
          if (request.url.path.contains('/apps/spreed/api/v4/room')) {
            conversationReads++;
            return http.Response(
              jsonEncode(conversationResponse),
              200,
              headers: const <String, String>{
                'X-Nextcloud-Talk-Hash': 'fixture-hash-call-banner',
                'X-Nextcloud-Talk-Modified-Before': '1724300001',
                'X-Nextcloud-Talk-Federation-Invites': '0',
              },
            );
          }
          fail('Unexpected request ${request.method} ${request.url}');
        }),
      );
      addTearDown(api.close);

      final chat = ChatRepository(database);
      final capability = await chat.recordCapabilities(
        accountId: account.id,
        talkFeatures: features,
        observedAt: DateTime.utc(2026, 8, 25, 9),
      );
      final sessions = CallLifecycleSessionRepository(database);
      final authority = CallLifecycleAuthority(
        accountId: AccountId.parse(account.id),
        server: ServerBase.parse(account.serverUrl),
        roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
        nextcloudSessionId: ConversationSessionId.parse('fixture-session-a'),
        credentialGeneration: capability.credentialGeneration,
        capabilityGeneration: capability.generation,
        capabilityRevision: 'call-v4:1:1:1:0',
      );
      await sessions.persist(
        CallLifecycleState.beginJoin(
          authority: authority,
          flags: CallInCallFlags.audioVideo(),
          updatedAt: DateTime.utc(2026, 8, 25, 9, 30),
        ).confirm(updatedAt: DateTime.utc(2026, 8, 25, 9, 30, 1)),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
            credentialVaultProvider.overrideWithValue(vault),
            nextcloudApiProvider.overrideWithValue(api),
            callTransportProvider.overrideWith(
              (ref, key) async => CallTransport.internal,
            ),
          ],
          child: localizedTestApp(
            home: Scaffold(
              body: OngoingCallBanner(
                account: account,
                conversation: conversation(withStart: false),
                now: () => callStart,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final key = (accountId: account.id, roomToken: 'rooma123');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(OngoingCallBanner)),
      );
      for (var attempt = 0; attempt < 40; attempt++) {
        final value = container.read(callLifecycleStatusProvider(key));
        if (value.hasValue || value.hasError) {
          break;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      await tester.pump();

      final lifecycle = container.read(callLifecycleStatusProvider(key));
      expect(
        callReads,
        1,
        reason:
            'lifecycle=$lifecycle capabilities=$capabilityReads '
            'conversations=$conversationReads',
      );
      expect(callMutations, 0);
      expect(find.byKey(const Key('call-banner-join')), findsOneWidget);
      expect(
        (await database.select(database.callLifecycleSessions).getSingle())
            .phase,
        CallLifecyclePhase.joined.name,
      );
    },
  );

  testWidgets('a hidden banner recovers durable state before a later join', (
    tester,
  ) async {
    const features = <String>{
      'conversation-v4',
      'conversation-permissions',
      'in-call-flags',
      'silent-call',
      'recording-consent',
    };
    final conversationResponse = readFixtureJson(
      'conversation-list/fixtures/conversations-full.response.json',
    )!;
    final callMethods = <String>[];
    var callReadCount = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(jsonEncode(_callCapabilities(features)), 200);
        }
        if (request.url.path.contains('/apps/spreed/api/v4/call/')) {
          callMethods.add(request.method);
          if (request.method == 'GET') {
            callReadCount++;
            if (callReadCount == 1) {
              return _ocsResponse(<Object?>[]);
            }
            return _ocsResponse(<Object?>[
              <String, Object?>{
                'actorType': 'users',
                'actorId': 'fixture-user',
                'displayName': 'Fixture User',
                'token': 'rooma123',
                'lastPing': 1770000000,
                'sessionId': 'fixture-session-a',
              },
            ]);
          }
          return _ocsResponse(<String, Object?>{});
        }
        if (request.url.path.endsWith('/participants/active')) {
          return request.method == 'DELETE'
              ? _ocsResponse(null)
              : _activeRoomResponse(conversationResponse);
        }
        if (request.url.path.contains('/apps/spreed/api/v4/room')) {
          return http.Response(
            jsonEncode(conversationResponse),
            200,
            headers: const <String, String>{
              'X-Nextcloud-Talk-Hash': 'fixture-hash-hidden-call-banner',
              'X-Nextcloud-Talk-Modified-Before': '1724300001',
              'X-Nextcloud-Talk-Federation-Invites': '0',
            },
          );
        }
        fail('Unexpected request ${request.method} ${request.url}');
      }),
    );
    addTearDown(api.close);

    final chat = ChatRepository(database);
    final capability = await chat.recordCapabilities(
      accountId: account.id,
      talkFeatures: features,
      observedAt: DateTime.utc(2026, 8, 25, 9),
    );
    final sessions = CallLifecycleSessionRepository(database);
    final authority = CallLifecycleAuthority(
      accountId: AccountId.parse(account.id),
      server: ServerBase.parse(account.serverUrl),
      roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
      nextcloudSessionId: ConversationSessionId.parse('fixture-session-a'),
      credentialGeneration: capability.credentialGeneration,
      capabilityGeneration: capability.generation,
      capabilityRevision: 'call-v4:1:1:1:0',
    );
    await sessions.persist(
      CallLifecycleState.beginJoin(
        authority: authority,
        flags: CallInCallFlags.audioVideo(),
        updatedAt: DateTime.utc(2026, 8, 25, 9, 30),
      ).confirm(updatedAt: DateTime.utc(2026, 8, 25, 9, 30, 1)),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          credentialVaultProvider.overrideWithValue(vault),
          nextcloudApiProvider.overrideWithValue(api),
        ],
        child: localizedTestApp(
          home: Scaffold(
            body: OngoingCallBanner(
              account: account,
              conversation: conversation(hasCall: false),
              now: () => callStart,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    var recovered = false;
    for (var attempt = 0; attempt < 80 && !recovered; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
      recovered =
          (await database.select(database.callLifecycleSessions).get()).isEmpty;
    }

    expect(find.byKey(const Key('call-banner')), findsNothing);
    expect(callMethods, <String>['GET']);
    expect(recovered, isTrue);

    final joinService = CallLifecycleService(
      accounts: accounts,
      chat: chat,
      sessions: sessions,
      credentials: vault,
      api: api,
      refreshConversationSession: (_, _) async =>
          ConversationSessionId.parse('fixture-session-a'),
    );
    final joined = await tester.runAsync(
      () => joinService
          .join(accountId: account.id, roomToken: 'rooma123')
          .timeout(const Duration(seconds: 5)),
    );

    expect(callMethods, <String>['GET', 'POST']);
    expect(joined?.phase, CallLifecyclePhase.joined);
  });

  testWidgets('the conversation list marks a room with a running call', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          credentialVaultProvider.overrideWithValue(vault),
          nextcloudApiProvider.overrideWithValue(
            HttpNextcloudApi(
              client: MockClient(
                (_) async => http.Response.bytes(utf8.encode('{}'), 404),
              ),
            ),
          ),
        ],
        child: localizedTestApp(
          home: Scaffold(
            body: ConversationListView(
              account: account,
              conversations: [
                conversation(),
                conversation(hasCall: false, token: 'roomquiet'),
              ],
              loading: false,
              onRefresh: () async {},
              onSelect: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('conversation-call-rooma123')), findsOneWidget);
    expect(find.byKey(const Key('conversation-call-roomquiet')), findsNothing);
    expect(
      tester
          .getSemantics(find.byKey(const Key('conversation-tile-rooma123')))
          .value,
      contains('Call in progress'),
      reason: 'the icon alone says nothing to assistive technology',
    );
    handle.dispose();
  });

  testWidgets('the joined banner controls fit across a phone', (tester) async {
    // THE BANNER'S CONTROL ROW HAD NO TEST AT ALL — nothing in the suite
    // rendered it in the joined state, which is why nobody saw it grow. It is
    // eight buttons on one line: the "open the call view" icon plus everything
    // `CallControls` draws, and call recording made that seven rather than six
    // on 7 September 2026. The row on the call SCREEN wraps; this one is a
    // plain `Row(mainAxisAlignment: end)` and clips instead.
    // 1080 physical pixels at 2.625 is the 411 dp the reporting phone has.
    tester.view.physicalSize = const Size(1080, 2220);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          credentialVaultProvider.overrideWithValue(vault),
          callTransportProvider.overrideWith(
            (ref, key) async => CallTransport.internal,
          ),
          callLifecycleStatusProvider.overrideWith(
            (ref, key) async => _readyLifecycle(key),
          ),
          callJoinControllerProvider.overrideWith(
            () => _FrozenBannerJoin(
              const CallJoinState(
                phase: CallJoinPhase.joined,
                publishing: CallPublishingRights(video: true, screen: true),
                canManageRecording: true,
                media: CallMediaState(
                  phase: CallMediaPhase.connected,
                  connectedPeers: 1,
                  peers: 2,
                ),
              ),
            ),
          ),
        ],
        child: localizedTestApp(
          home: Scaffold(
            body: OngoingCallBanner(
              account: account,
              conversation: conversation(),
              now: () => callStart,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('call-banner-open')), findsOneWidget);
    expect(find.byKey(const Key('call-banner-mute')), findsOneWidget);
    expect(find.byKey(const Key('call-banner-recording')), findsOneWidget);
    // An overflow reaches a test through the error reporter, not by throwing
    // where it happens, so this is the only way to see it.
    expect(
      tester.takeException(),
      isNull,
      reason: 'the banner may not run off the edge of a phone',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

final class _FrozenBannerJoin extends CallJoinController {
  _FrozenBannerJoin(this.frozen);

  final CallJoinState frozen;

  @override
  CallJoinState build(CallRoomKey arg) => frozen;
}

CallLifecycleRoomStatus _readyLifecycle(CallRoomKey key) {
  return CallLifecycleRoomStatus(
    key: key,
    status: CallLifecycleStatus(
      ownSessionPresent: false,
      peers: const <CallPeer>[],
      state: null,
    ),
  );
}

Map<String, Object?> _callCapabilities(Set<String> features) {
  final root = capabilitiesJson(talkFeatures: features);
  final ocs = root['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  final capabilities = data['capabilities']! as Map<String, Object?>;
  final spreed = capabilities['spreed']! as Map<String, Object?>;
  spreed['config'] = <String, Object?>{
    'call': <String, Object?>{'enabled': true, 'recording-consent': 0},
  };
  return root;
}

http.Response _ocsResponse(Object? data) => http.Response(
  jsonEncode(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': data,
    },
  }),
  200,
);

http.Response _activeRoomResponse(Object? conversationResponse) {
  final root = conversationResponse! as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final room = rooms.first! as Map<String, Object?>;
  return http.Response(
    _ocsResponse(room).body,
    200,
    headers: const <String, String>{
      'set-cookie': 'nc_session=call-banner; Path=/; HttpOnly',
    },
  );
}
