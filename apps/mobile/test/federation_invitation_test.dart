import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/features/conversations/conversation_sync_service.dart';
import 'package:nextcloudtalk/features/conversations/federation_invitation_service.dart';
import 'package:nextcloudtalk/features/conversations/federation_invitation_strip.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

Map<String, Object?> _invitation(int id) => {
  'id': id,
  'state': 0,
  'localCloudId': 'me@shared.example.invalid',
  'localToken': 'localtok$id',
  'remoteAttendeeId': 12,
  'remoteServerUrl': 'talk2.example.invalid',
  'remoteToken': 'remotetok$id',
  'roomName': 'Federated room $id',
  'userId': 'me',
  'inviterCloudId': 'other@talk2.example.invalid',
  'inviterDisplayName': 'Other Person',
};

String _ocs(Object? data) => jsonEncode({
  'ocs': {
    'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
    'data': data,
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the strip shows the count and the sheet decides', (
    tester,
  ) async {
    final invitations = [
      for (final id in [7, 8])
        FederationInvitation(
          id: id,
          state: 0,
          localToken: 'localtok$id',
          remoteServerUrl: 'talk2.example.invalid',
          remoteToken: 'remotetok$id',
          roomName: 'Federated room $id',
          inviterCloudId: 'other@talk2.example.invalid',
          inviterDisplayName: 'Other Person',
        ),
    ];
    final decisions = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Column(
            children: [
              FederationInvitationStrip(
                invitations: invitations,
                onDecide: (invitation, {required accept}) async {
                  decisions.add('${invitation.id}:$accept');
                  return accept ? 'accepted' : 'declined';
                },
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      find.text('2 invitations to conversations on other servers'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('federation-invitations-show')));
    await tester.pumpAndSettle();
    expect(find.text('Federated room 7'), findsOneWidget);
    expect(
      find.text('From Other Person on talk2.example.invalid'),
      findsNWidgets(2),
    );

    await tester.tap(find.byKey(const Key('federation-invitation-decline-8')));
    await tester.pumpAndSettle();
    expect(decisions, ['8:false']);
    // Declined rows leave the sheet; the sheet itself stays for the rest.
    expect(find.text('Federated room 8'), findsNothing);
    expect(find.text('Federated room 7'), findsOneWidget);
    expect(find.text('declined'), findsOneWidget);

    await tester.tap(find.byKey(const Key('federation-invitation-accept-7')));
    await tester.pumpAndSettle();
    expect(decisions, ['8:false', '7:true']);
    // Accepting closes the sheet: the shell is opening the room.
    expect(find.byKey(const Key('federation-invitation-7')), findsNothing);
  });

  testWidgets('an empty list renders nothing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: FederationInvitationStrip(
            invitations: const [],
            onDecide: (_, {required accept}) async => '',
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('federation-invitation-strip')), findsNothing);
  });

  test(
    'the provider asks the server only once the sync reported a count',
    () async {
      final database = openTestDatabase();
      addTearDown(database.close);
      final accounts = AccountRepository(database);
      final vault = MemoryCredentialVault();
      final account = await accounts.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://shared.example.invalid',
        loginName: 'me',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026),
      );
      vault.values[account.id] = 'secret';
      final requests = <String>[];
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          if (request.url.path.endsWith('/federation/invitation')) {
            return http.Response(_ocs([_invitation(7)]), 200);
          }
          if (request.url.path.endsWith('/federation/invitation/7')) {
            return http.Response(_ocs({'token': 'localtok7', 'type': 2}), 200);
          }
          return http.Response('', 404);
        }),
      );
      addTearDown(api.close);
      final counter = FederationInviteCounter();
      final service = FederationInvitationService(
        accounts: accounts,
        credentials: vault,
        api: api,
      );
      final container = ProviderContainer(
        overrides: [
          federationInviteCounterProvider.overrideWithValue(counter),
          federationInvitationServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);

      expect(
        await container.read(federationInvitationsProvider(account.id).future),
        isEmpty,
      );
      expect(requests, isEmpty);

      counter.record(account.id, 1);
      await Future<void>.delayed(Duration.zero);
      final pending = await container.read(
        federationInvitationsProvider(account.id).future,
      );
      expect(pending.map((invitation) => invitation.id), [7]);
      expect(requests, [
        'GET /ocs/v2.php/apps/spreed/api/v1/federation/invitation',
      ]);

      final token = await service.accept(
        accountId: account.id,
        invitationId: 7,
      );
      expect(token.value, 'localtok7');
      expect(
        requests.last,
        'POST /ocs/v2.php/apps/spreed/api/v1/federation/invitation/7',
      );
    },
  );
}
