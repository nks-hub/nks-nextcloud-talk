import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_absence.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  test('loads current peer absence from the account origin', () async {
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.path,
          '/nextcloud/ocs/v2.php/apps/dav/api/v1/outOfOffice/peer-a/now',
        );
        expect(request.headers['OCS-APIRequest'], 'true');
        expect(request.headers['Authorization'], startsWith('Basic '));
        return _response(200, _absenceData);
      }),
    );
    addTearDown(api.close);

    final absence = await api.getCurrentOutOfOffice(
      server: ServerBase.parse('https://cloud.example.invalid/nextcloud'),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
      userId: 'peer-a',
    );

    expect(absence, isNotNull);
    expect(absence!.userId, 'peer-a');
    expect(
      absence.start,
      DateTime.fromMillisecondsSinceEpoch(1772323200000, isUtc: true),
    );
    expect(
      absence.end,
      DateTime.fromMillisecondsSinceEpoch(1772496000000, isUtc: true),
    );
    expect(absence.replacementUserDisplayName, 'Backup Person');
  });

  test('404 means the peer has no current absence', () async {
    final api = HttpNextcloudApi(
      client: MockClient((_) async => http.Response('', 404)),
    );
    addTearDown(api.close);

    expect(
      await api.getCurrentOutOfOffice(
        server: ServerBase.parse('https://cloud.example.invalid'),
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
        userId: 'peer-a',
      ),
      isNull,
    );
  });

  test('rejects a mismatched user and reversed period', () {
    for (final data in <Map<String, Object?>>[
      <String, Object?>{..._absenceData, 'userId': 'other-user'},
      <String, Object?>{
        ..._absenceData,
        'startDate': 1772496000,
        'endDate': 1772323200,
      },
    ]) {
      expect(
        () => CurrentOutOfOffice.fromOcsJson(
          _ocs(data),
          expectedUserId: 'peer-a',
        ),
        throwsA(
          isA<NextcloudApiException>().having(
            (error) => error.code,
            'code',
            NextcloudApiError.invalidJson,
          ),
        ),
      );
    }
  });

  testWidgets('disposing the provider aborts an in-flight capability request', (
    tester,
  ) async {
    final entered = Completer<void>();
    final aborted = Completer<void>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationAbsenceLoaderProvider.overrideWithValue((
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
            body: ConversationAbsenceBanner(
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

  testWidgets('direct chat shows the absence period and replacement', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationAbsenceLoaderProvider.overrideWithValue(
            (key, abortTrigger) async => CurrentOutOfOffice.fromOcsJson(
              _ocs(_absenceData),
              expectedUserId: key.userId,
            ),
          ),
        ],
        child: localizedTestApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(2),
            ),
            child: const Scaffold(
              body: ConversationAbsenceBanner(
                account: _account,
                conversation: _conversation,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('conversation-absence-banner')),
      findsOneWidget,
    );
    expect(find.textContaining('Peer User is out of office'), findsOneWidget);
    expect(find.text('I am away.'), findsOneWidget);
    expect(find.textContaining('Backup Person'), findsOneWidget);
    expect(find.byIcon(Icons.event_busy_outlined), findsOneWidget);
    final semanticBanner = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.label?.startsWith('Peer User is out of office') ==
              true,
    );
    expect(semanticBanner, findsOneWidget);
    expect(tester.getSemantics(semanticBanner).childrenCount, 0);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('long absence content stays bounded at 200 percent text', (
    tester,
  ) async {
    final longMessage = List.filled(190, 'Long absence message').join('\n');
    final longReplacement = List.filled(341, 'Replacement').join(' ');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationAbsenceLoaderProvider.overrideWithValue(
            (key, abortTrigger) async => CurrentOutOfOffice.fromOcsJson(
              _ocs(<String, Object?>{
                ..._absenceData,
                'message': longMessage,
                'replacementUserDisplayName': longReplacement,
              }),
              expectedUserId: key.userId,
            ),
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
                  ConversationAbsenceBanner(
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

    final message = tester.widget<Text>(find.text(longMessage));
    final replacement = tester.widget<Text>(
      find.textContaining(longReplacement),
    );
    expect(message.maxLines, 3);
    expect(message.overflow, TextOverflow.ellipsis);
    expect(replacement.maxLines, 2);
    expect(replacement.overflow, TextOverflow.ellipsis);
    expect(
      tester
          .getSize(find.byKey(const Key('conversation-absence-banner')))
          .height,
      lessThan(400),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('account mismatch does not start an absence lookup', (
    tester,
  ) async {
    var requests = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationAbsenceLoaderProvider.overrideWithValue((
            key,
            abortTrigger,
          ) async {
            requests++;
            return null;
          }),
        ],
        child: localizedTestApp(
          home: Scaffold(
            body: ConversationAbsenceBanner(
              account: _account,
              conversation: _conversation.copyWith(accountId: 'account-b'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(requests, 0);
    expect(find.byKey(const Key('conversation-absence-banner')), findsNothing);
  });
}

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

const _absenceData = <String, Object?>{
  'id': 'absence-a',
  'userId': 'peer-a',
  'startDate': 1772323200,
  'endDate': 1772496000,
  'shortMessage': 'Away',
  'message': 'I am away.',
  'replacementUserId': 'backup-a',
  'replacementUserDisplayName': 'Backup Person',
};

const _account = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: true,
  createdAtMillis: 0,
);

const _conversation = CachedConversation(
  accountId: 'account-a',
  token: 'rooma123',
  displayName: 'Peer User',
  description: '',
  lastActivity: 0,
  unreadMessages: 0,
  favorite: false,
  isArchived: false,
  readOnly: 0,
  roomType: 1,
  roomName: 'peer-a',
  objectType: '',
  avatarVersion: '',
  isCustomAvatar: false,
  rawJson: '{}',
);
