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
import 'package:nextcloudtalk/features/conversations/conversation_upcoming_event.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  test('loads the first event for the exact conversation call URL', () async {
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.path,
          '/nextcloud/ocs/v2.php/apps/dav/api/v1/events/upcoming',
        );
        expect(
          request.url.queryParameters['location'],
          'https://cloud.example.invalid/nextcloud/call/rooma123',
        );
        expect(request.url.queryParameters['format'], 'json');
        expect(request.headers['OCS-APIRequest'], 'true');
        expect(request.headers['Authorization'], startsWith('Basic '));
        return _response(200, _eventsData);
      }),
    );
    addTearDown(api.close);

    final event = await api.getUpcomingConversationEvent(
      server: ServerBase.parse('https://cloud.example.invalid/nextcloud'),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
      roomToken: 'rooma123',
    );

    expect(event, isNotNull);
    expect(event!.summary, 'Planning call');
    expect(
      event.start,
      DateTime.fromMillisecondsSinceEpoch(1772359200000, isUtc: true),
    );
  });

  test('an empty event list has no banner content', () async {
    final api = HttpNextcloudApi(
      client: MockClient(
        (_) async => _response(200, <String, Object?>{'events': <Object?>[]}),
      ),
    );
    addTearDown(api.close);

    expect(
      await api.getUpcomingConversationEvent(
        server: ServerBase.parse('https://cloud.example.invalid'),
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
        roomToken: 'rooma123',
      ),
      isNull,
    );
  });

  test('rejects an event returned for another conversation', () async {
    final api = HttpNextcloudApi(
      client: MockClient(
        (_) async => _response(200, <String, Object?>{
          'events': <Object?>[
            <String, Object?>{
              ..._eventData,
              'location': 'https://cloud.example.invalid/call/other-room',
            },
          ],
        }),
      ),
    );
    addTearDown(api.close);

    await expectLater(
      api.getUpcomingConversationEvent(
        server: ServerBase.parse('https://cloud.example.invalid'),
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
        roomToken: 'rooma123',
      ),
      throwsA(
        isA<NextcloudApiException>().having(
          (error) => error.code,
          'code',
          NextcloudApiError.invalidJson,
        ),
      ),
    );
  });

  test('missing capability does not request upcoming events', () async {
    final database = openTestDatabase();
    final accounts = AccountRepository(database);
    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    final vault = MemoryCredentialVault()
      ..values[account.id] = 'fixture-password';
    var eventRequests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return _response(200, _capabilitiesData);
        }
        eventRequests++;
        return http.Response('', 500);
      }),
    );
    final container = ProviderContainer(
      overrides: [
        accountRepositoryProvider.overrideWithValue(accounts),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(api),
      ],
    );
    addTearDown(() async {
      container.dispose();
      api.close();
      await database.close();
    });

    final event = await container.read(conversationUpcomingEventLoaderProvider)(
      (accountId: account.id, roomToken: 'rooma123'),
      Completer<void>().future,
    );

    expect(event, isNull);
    expect(eventRequests, 0);
  });

  testWidgets('disposing the banner aborts its in-flight request', (
    tester,
  ) async {
    final entered = Completer<void>();
    final aborted = Completer<void>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationUpcomingEventLoaderProvider.overrideWithValue((
            key,
            abortTrigger,
          ) async {
            entered.complete();
            await abortTrigger;
            aborted.complete();
            return null;
          }),
        ],
        child: localizedTestApp(
          home: const Scaffold(
            body: ConversationUpcomingEventBanner(
              account: _account,
              conversation: _conversation,
            ),
          ),
        ),
      ),
    );

    await entered.future;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await aborted.future.timeout(const Duration(seconds: 5));
  });

  testWidgets('room change clears stale and late event results', (
    tester,
  ) async {
    final roomB = Completer<UpcomingTalkEvent?>();
    final roomC = Completer<UpcomingTalkEvent?>();
    var conversation = _conversation;
    late StateSetter updateHost;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationUpcomingEventLoaderProvider.overrideWithValue((
            key,
            abortTrigger,
          ) {
            return switch (key.roomToken) {
              'rooma123' => Future.value(_event()),
              'roomb123' => roomB.future,
              'roomc123' => roomC.future,
              _ => Future.value(),
            };
          }),
        ],
        child: localizedTestApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                updateHost = setState;
                return Column(
                  children: [
                    ConversationUpcomingEventBanner(
                      account: _account,
                      conversation: conversation,
                    ),
                    const Expanded(child: SizedBox()),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Planning call'), findsOneWidget);

    updateHost(() => conversation = conversation.copyWith(token: 'roomb123'));
    await tester.pump();
    expect(find.byKey(const Key('conversation-upcoming-event')), findsNothing);

    updateHost(() => conversation = conversation.copyWith(token: 'roomc123'));
    await tester.pump();
    roomB.complete(_event(summary: 'Room B event'));
    await tester.pump();
    expect(find.text('Room B event'), findsNothing);
    expect(find.byKey(const Key('conversation-upcoming-event')), findsNothing);

    roomC.complete();
    await tester.pump();
    expect(find.byKey(const Key('conversation-upcoming-event')), findsNothing);
  });

  testWidgets('shows and dismisses the first upcoming event', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationUpcomingEventLoaderProvider.overrideWithValue(
            (key, abortTrigger) async => _event(),
          ),
        ],
        child: localizedTestApp(
          home: const Scaffold(
            body: Column(
              children: [
                ConversationUpcomingEventBanner(
                  account: _account,
                  conversation: _conversation,
                ),
                Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('conversation-upcoming-event')),
      findsOneWidget,
    );
    expect(find.text('Planning call'), findsOneWidget);
    expect(find.byIcon(Icons.event_outlined), findsOneWidget);
    final semanticBanner = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.label?.contains('Planning call') == true,
    );
    expect(semanticBanner, findsOneWidget);
    expect(tester.getSemantics(semanticBanner).childrenCount, 0);

    await tester.tap(find.byKey(const Key('dismiss-upcoming-event')));
    await tester.pump();

    expect(find.byKey(const Key('conversation-upcoming-event')), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('long event stays bounded at 200 percent text', (tester) async {
    final longSummary = List.filled(270, 'Upcoming event').join(' ');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationUpcomingEventLoaderProvider.overrideWithValue(
            (key, abortTrigger) async => _event(summary: longSummary),
          ),
        ],
        child: localizedTestApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(2),
            ),
            child: const Scaffold(
              body: Column(
                children: [
                  ConversationUpcomingEventBanner(
                    account: _account,
                    conversation: _conversation,
                  ),
                  Expanded(child: SizedBox()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final summary = tester.widget<Text>(find.text(longSummary));
    expect(summary.maxLines, 2);
    expect(summary.overflow, TextOverflow.ellipsis);
    expect(
      tester
          .getSize(find.byKey(const Key('conversation-upcoming-event')))
          .height,
      lessThan(300),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('account mismatch does not start an event lookup', (
    tester,
  ) async {
    var requests = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationUpcomingEventLoaderProvider.overrideWithValue((
            key,
            abortTrigger,
          ) async {
            requests++;
            return null;
          }),
        ],
        child: localizedTestApp(
          home: Scaffold(
            body: ConversationUpcomingEventBanner(
              account: _account,
              conversation: _conversation.copyWith(accountId: 'account-b'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(requests, 0);
    expect(find.byKey(const Key('conversation-upcoming-event')), findsNothing);
  });
}

UpcomingTalkEvent _event({String summary = 'Planning call'}) =>
    UpcomingTalkEvent.fromOcsJson(
      _ocs(<String, Object?>{
        'events': <Object?>[
          <String, Object?>{..._eventData, 'summary': summary},
        ],
      }),
      expectedLocation: 'https://cloud.example.invalid/nextcloud/call/rooma123',
    )!;

http.Response _response(int status, Object? data) => http.Response.bytes(
  utf8.encode(jsonEncode(_ocs(data))),
  status,
  headers: const {'content-type': 'application/json'},
);

Map<String, Object?> _ocs(Object? data) => <String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': data,
  },
};

const _eventsData = <String, Object?>{
  'events': <Object?>[_eventData],
};

const _capabilitiesData = <String, Object?>{
  'version': <String, Object?>{
    'major': 34,
    'minor': 0,
    'micro': 1,
    'string': '34.0.1',
    'edition': '',
    'extendedSupport': false,
  },
  'capabilities': <String, Object?>{
    'spreed': <String, Object?>{
      'features': <Object?>['conversation-v4'],
      'config': <String, Object?>{},
    },
  },
};

const _eventData = <String, Object?>{
  'uri': 'event-a.ics',
  'calendarUri': 'personal',
  'start': 1772359200,
  'summary': 'Planning call',
  'location': 'https://cloud.example.invalid/nextcloud/call/rooma123',
};

const _account = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '["upcoming-reminders"]',
  selected: true,
  createdAtMillis: 0,
);

const _conversation = CachedConversation(
  accountId: 'account-a',
  token: 'rooma123',
  displayName: 'Planning room',
  description: '',
  lastActivity: 0,
  unreadMessages: 0,
  favorite: false,
  isArchived: false,
  readOnly: 0,
  roomType: 2,
  roomName: '',
  objectType: '',
  avatarVersion: '',
  isCustomAvatar: false,
  rawJson: '{}',
);
