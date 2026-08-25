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
import 'package:nextcloudtalk/features/calls/call_banner.dart';
import 'package:nextcloudtalk/features/calls/call_transport_service.dart';
import 'package:nextcloudtalk/features/conversations/conversation_list_actions.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

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
  }) {
    return ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(vault),
        callTransportProvider.overrideWith((ref, key) async => transport),
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
    await tester.pumpWidget(
      banner(
        room: conversation(hasCall: false),
        transport: CallTransport.internal,
        now: () => callStart,
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('call-banner')), findsNothing);
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

  testWidgets('a resolved transport offers an explicitly disabled join', (
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

    final join = find.byKey(const Key('call-banner-join'));
    expect(join, findsOneWidget);
    expect(
      tester.widget<FilledButton>(join).onPressed,
      isNull,
      reason: 'media is not implemented, so the button must not pretend',
    );
    expect(
      find.text('Joining is not implemented yet (external HPB signalling).'),
      findsOneWidget,
    );
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

    expect(
      find.byKey(const Key('conversation-call-rooma123')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('conversation-call-roomquiet')),
      findsNothing,
    );
    expect(
      tester
          .getSemantics(find.byKey(const Key('conversation-tile-rooma123')))
          .value,
      contains('Call in progress'),
      reason: 'the icon alone says nothing to assistive technology',
    );
    handle.dispose();
  });
}
