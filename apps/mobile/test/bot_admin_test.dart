import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/bots/bot_admin_screen.dart';
import 'package:nextcloudtalk/features/bots/bot_admin_service.dart';
import 'package:nextcloudtalk/features/settings/settings_screen.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;
  late StoredAccount account;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault()..values['account-a'] = 'fixture-password';
    account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-admin',
      serverProductName: 'Nextcloud',
      talkFeatures: const {'bots-v1'},
      createdAt: DateTime.utc(2026, 1, 1),
    );
  });

  tearDown(() => database.close());

  /// A service whose server answers the bot route with [botRoute] and
  /// publishes [talkFeatures] as its Talk capabilities.
  BotAdminService service({
    required Future<http.Response> Function(http.Request request) botRoute,
    List<String> talkFeatures = const <String>['bots-v1'],
    List<String>? requestLog,
  }) {
    return BotAdminService(
      accounts: accounts,
      credentials: vault,
      api: HttpNextcloudApi(
        client: MockClient((request) async {
          requestLog?.add(request.url.path);
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(capabilitiesJson(talkFeatures: talkFeatures)),
              200,
            );
          }
          return botRoute(request);
        }),
      ),
    );
  }

  BotAdminService answering(int statusCode, [String? body]) => service(
    botRoute: (_) async =>
        http.Response(body ?? _ocs(const <Object?>[]), statusCode),
  );

  group('BotAdminService', () {
    test('reads the shape the server really answers with', () async {
      final listing = await answering(
        200,
        _liveList,
      ).listBots(accountId: account.id);

      expect(listing.truncated, isFalse);
      expect(listing.bots.map((bot) => bot.name), <String>[
        'Echo bot',
        'Broken bot',
        'App bot',
      ]);
      expect(listing.bots[0].state, BotState.enabled);
      expect(listing.bots[1].state, BotState.disabled);
      // Measured live: a bot behind a disabled app is state 3, and Talk
      // substitutes an error count of one and "App disabled" for it.
      expect(listing.bots[2].state, BotState.unavailable);
      expect(listing.bots[2].errorCount, 1);
      expect(listing.bots[2].lastErrorMessage, 'App disabled');
      // The webhook address itself never leaves the decoder.
      expect(listing.bots[0].urlHost, 'bots.example.invalid');
    });

    test('the administrator route is the one that gets asked', () async {
      final log = <String>[];
      await service(
        botRoute: (_) async => http.Response(_ocs(const <Object?>[]), 200),
        requestLog: log,
      ).listBots(accountId: account.id);

      expect(log, contains('/ocs/v2.php/apps/spreed/api/v1/bot/admin'));
    });

    test('an ordinary account is told it is not an administrator', () async {
      // Not a fault: upstream answers every non-admin this way.
      await expectLater(
        answering(
          403,
          '{"ocs":{"meta":{"status":"failure","statuscode":403,'
          '"message":"Logged in account must be an admin"},"data":[]}}',
        ).listBots(accountId: account.id),
        throwsA(
          isA<BotAdminException>().having(
            (error) => error.code,
            'code',
            BotAdminError.notAdministrator,
          ),
        ),
      );
    });

    test('maps every other answer the endpoint can give', () async {
      const expected = <int, BotAdminError>{
        401: BotAdminError.reauthenticationRequired,
        404: BotAdminError.unsupported,
        429: BotAdminError.rateLimited,
        500: BotAdminError.serviceUnavailable,
        502: BotAdminError.serviceUnavailable,
        503: BotAdminError.serviceUnavailable,
      };
      for (final entry in expected.entries) {
        await expectLater(
          answering(entry.key).listBots(accountId: account.id),
          throwsA(
            isA<BotAdminException>().having(
              (error) => error.code,
              'code ${entry.key}',
              entry.value,
            ),
          ),
          reason: 'status ${entry.key}',
        );
      }
    });

    test('a server without bots-v1 is never asked at all', () async {
      final log = <String>[];
      await expectLater(
        service(
          botRoute: (_) async => http.Response(_ocs(const <Object?>[]), 200),
          talkFeatures: const <String>['chat-v2'],
          requestLog: log,
        ).listBots(accountId: account.id),
        throwsA(
          isA<BotAdminException>().having(
            (error) => error.code,
            'code',
            BotAdminError.unsupported,
          ),
        ),
      );
      expect(log.where((path) => path.contains('/bot/admin')), isEmpty);
    });

    test('a signed-out account and a missing credential differ', () async {
      await expectLater(
        answering(200).listBots(accountId: 'account-unknown'),
        throwsA(
          isA<BotAdminException>().having(
            (error) => error.code,
            'code',
            BotAdminError.accountMissing,
          ),
        ),
      );
      vault.values.remove(account.id);
      await expectLater(
        answering(200).listBots(accountId: account.id),
        throwsA(
          isA<BotAdminException>().having(
            (error) => error.code,
            'code',
            BotAdminError.credentialMissing,
          ),
        ),
      );
    });

    test('an unreadable body and an offline server differ', () async {
      await expectLater(
        answering(200, 'not json').listBots(accountId: account.id),
        throwsA(
          isA<BotAdminException>().having(
            (error) => error.code,
            'code',
            BotAdminError.invalidResponse,
          ),
        ),
      );
      await expectLater(
        service(
          // What `IOClient` really raises for an unreachable server; a bare
          // SocketException never reaches the transport in production.
          botRoute: (request) async =>
              throw http.ClientException('offline', request.url),
        ).listBots(accountId: account.id),
        throwsA(
          isA<BotAdminException>().having(
            (error) => error.code,
            'code',
            BotAdminError.network,
          ),
        ),
      );
    });

    test('a status nothing documents is refused, not shown', () async {
      await expectLater(
        answering(418).listBots(accountId: account.id),
        throwsA(
          isA<BotAdminException>().having(
            (error) => error.code,
            'code',
            BotAdminError.invalidResponse,
          ),
        ),
      );
    });

    test('the entry point is offered on the capability alone', () async {
      final log = <String>[];
      expect(
        await service(
          botRoute: (_) async => http.Response(_ocs(const <Object?>[]), 200),
          requestLog: log,
        ).supportsBotAdmin(accountId: account.id),
        isTrue,
      );
      // Asking whether to show the entry must not cost the list itself.
      expect(log.where((path) => path.contains('/bot/admin')), isEmpty);
      expect(
        await service(
          botRoute: (_) async => http.Response(_ocs(const <Object?>[]), 200),
          talkFeatures: const <String>['chat-v2'],
        ).supportsBotAdmin(accountId: account.id),
        isFalse,
      );
      // A server that cannot be reached is not a server that offers it.
      expect(
        await service(
          // What `IOClient` really raises for an unreachable server; a bare
          // SocketException never reaches the transport in production.
          botRoute: (request) async =>
              throw http.ClientException('offline', request.url),
          talkFeatures: const <String>['bots-v1'],
        ).supportsBotAdmin(accountId: 'account-unknown'),
        isFalse,
      );
    });
  });

  group('BotAdminScreen', () {
    Future<void> pumpScreen(
      WidgetTester tester, {
      required Future<http.Response> Function(http.Request request) botRoute,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            botAdminServiceProvider.overrideWithValue(
              service(botRoute: botRoute),
            ),
          ],
          child: localizedTestApp(home: BotAdminScreen(accountId: account.id)),
        ),
      );
      await _settleRealAsync(tester);
    }

    testWidgets('a healthy bot shows no error area at all', (tester) async {
      await pumpScreen(
        tester,
        botRoute: (_) async => http.Response(_ocs(<Object?>[_echoBot]), 200),
      );

      expect(find.byKey(const Key('bot-admin-row-1')), findsOneWidget);
      expect(find.text('Echo bot'), findsOneWidget);
      expect(find.text('Enabled'), findsOneWidget);
      expect(find.text('Webhook host: bots.example.invalid'), findsOneWidget);
      expect(find.byKey(const Key('bot-admin-failure-1')), findsNothing);
    });

    testWidgets('a failing bot names the count, the moment and the reason', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        botRoute: (_) async => http.Response(_ocs(<Object?>[_appBot]), 200),
      );

      expect(find.byKey(const Key('bot-admin-failure-3')), findsOneWidget);
      expect(find.text('1 failure'), findsOneWidget);
      expect(find.text('App disabled'), findsOneWidget);
      expect(find.textContaining('Last failure'), findsOneWidget);
      // The synthesized state is its own label, not "disabled".
      expect(find.text('Unavailable, its app is not enabled'), findsOneWidget);
      expect(find.text('Webhook host: no-such-app'), findsOneWidget);
    });

    testWidgets('403 says what is true about the account', (tester) async {
      await pumpScreen(
        tester,
        botRoute: (_) async => http.Response(_ocs(const <Object?>[]), 403),
      );

      expect(
        find.byKey(const Key('bot-admin-not-administrator')),
        findsOneWidget,
      );
      expect(
        find.text('This account is not an administrator of this server.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('bot-admin-load-failed')), findsNothing);
    });

    testWidgets('a server with no bots is not a failure', (tester) async {
      await pumpScreen(
        tester,
        botRoute: (_) async => http.Response(_ocs(const <Object?>[]), 200),
      );

      expect(find.byKey(const Key('bot-admin-empty')), findsOneWidget);
    });
  });

  group('settings entry point', () {
    Future<void> pumpSettings(
      WidgetTester tester, {
      required List<String> talkFeatures,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            // The relay switch would otherwise wait on the live database.
            callRelayOfferedProvider.overrideWith((ref) async => false),
            accountRepositoryProvider.overrideWithValue(accounts),
            accountsProvider.overrideWith(
              (ref) => Stream.value(<StoredAccount>[account]),
            ),
            botAdminServiceProvider.overrideWithValue(
              service(
                botRoute: (_) async =>
                    http.Response(_ocs(const <Object?>[]), 200),
                talkFeatures: talkFeatures,
              ),
            ),
          ],
          child: localizedTestApp(home: const SettingsScreen()),
        ),
      );
      await _settleRealAsync(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    }

    testWidgets('a server without bots-v1 offers no bot entry', (tester) async {
      await pumpSettings(tester, talkFeatures: const <String>['chat-v2']);

      expect(find.byKey(const Key('settings-open-bot-admin')), findsNothing);
      expect(find.text('Bots'), findsNothing);
    });

    testWidgets('a server with bots-v1 offers it', (tester) async {
      await pumpSettings(tester, talkFeatures: const <String>['bots-v1']);

      expect(find.byKey(const Key('settings-open-bot-admin')), findsOneWidget);
      expect(find.text('Installed bots'), findsOneWidget);
    });
  });
}

/// Real async work (Drift plus a mocked round trip) needs genuine event-loop
/// turns, which `testWidgets`' fake clock never grants. `pumpAndSettle` is
/// deliberately unused: it budgets in fake time and would spin for minutes.
Future<void> _settleRealAsync(WidgetTester tester, {int rounds = 24}) async {
  for (var round = 0; round < rounds; round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

String _ocs(List<Object?> data) => jsonEncode(<String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': data,
  },
});

const Map<String, Object?> _echoBot = <String, Object?>{
  'id': 1,
  'name': 'Echo bot',
  'url': 'https://bots.example.invalid/echo',
  'url_hash': '949e5cc22b97d3e5a8f228330773abfc40819002',
  'description': 'Repeats what it hears',
  'error_count': 0,
  'last_error_date': 0,
  'last_error_message': null,
  'state': 1,
  'features': 3,
};

const Map<String, Object?> _brokenBot = <String, Object?>{
  'id': 2,
  'name': 'Broken bot',
  'url': 'https://bots.example.invalid/broken',
  'url_hash': '6dc861c4d7d2cd1df8057183e672d1d0aae2b17b',
  'description': 'A bot whose endpoint is gone',
  'error_count': 0,
  'last_error_date': 0,
  'last_error_message': null,
  'state': 0,
  'features': 3,
};

/// A bot provided by an app that is not enabled, as Talk 22.0.17 reports it.
const Map<String, Object?> _appBot = <String, Object?>{
  'id': 3,
  'name': 'App bot',
  'url': 'nextcloudapp://no-such-app/bot',
  'url_hash': 'f389b0ebf7f44b07ae2e97eb5bca54176f4fa9ae',
  'description': 'A bot backed by an app that is not enabled',
  'error_count': 1,
  'last_error_date': 1788965389,
  'last_error_message': 'App disabled',
  'state': 3,
  'features': 4,
};

final String _liveList = _ocs(<Object?>[_echoBot, _brokenBot, _appBot]);
