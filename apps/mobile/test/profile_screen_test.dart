import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/profile/profile_screen.dart';
import 'package:nextcloudtalk/features/settings/settings_screen.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'test_support.dart';

void main() {
  testWidgets('profile renders and updates only capability-backed status', (
    tester,
  ) async {
    final server = _ProfileServer(supportsBusy: false);
    final fixture = (await tester.runAsync(() => _Fixture.create(server)))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await fixture.dispose();
    });

    await tester.pumpWidget(fixture.profileApp());
    await tester.pump();
    await _settleRealAsync(tester);

    expect(find.byKey(const Key('profile-content')), findsOneWidget);
    expect(find.text('Alice Example'), findsOneWidget);
    expect(find.textContaining('alice@example.invalid'), findsOneWidget);
    expect(find.byKey(const Key('profile-status-busy')), findsNothing);
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('profile-status-online')))
          .selected,
      isTrue,
    );

    await tester.tap(find.byKey(const Key('profile-status-away')));
    await tester.pump();
    await _settleRealAsync(tester);

    expect(server.status, 'away');
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('profile-status-away')))
          .selected,
      isTrue,
    );

    await tester.enterText(find.byKey(const Key('profile-status-icon')), '🛠️');
    await tester.enterText(
      find.byKey(const Key('profile-status-message')),
      'In a workshop',
    );
    await tester.ensureVisible(find.byKey(const Key('profile-status-save')));
    await tester.tap(find.byKey(const Key('profile-status-save')));
    await tester.pump();
    await _settleRealAsync(tester);

    expect(server.icon, '🛠️');
    expect(server.message, 'In a workshop');

    await tester.ensureVisible(find.byKey(const Key('profile-status-clear')));
    await tester.tap(find.byKey(const Key('profile-status-clear')));
    await tester.pump();
    await _settleRealAsync(tester);

    expect(server.icon, isNull);
    expect(server.message, isNull);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('profile-status-message')))
          .controller
          ?.text,
      isEmpty,
    );
    final statusMethods = server.requests
        .where(
          (request) =>
              request.url.path.endsWith('/user_status/message') ||
              request.url.path.endsWith('/user_status'),
        )
        .map((request) => request.method)
        .toList();
    expect(statusMethods.sublist(statusMethods.length - 2), ['DELETE', 'GET']);
  });

  testWidgets('settings opens the active account profile', (tester) async {
    final server = _ProfileServer(supportsBusy: true);
    final fixture = (await tester.runAsync(() => _Fixture.create(server)))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await fixture.dispose();
    });

    await tester.pumpWidget(fixture.settingsApp());
    await tester.pump();
    await tester.pump();

    final profileTile = find.byKey(const Key('settings-open-profile'));
    expect(profileTile, findsOneWidget);
    await tester.ensureVisible(profileTile);
    await tester.tap(profileTile);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _settleRealAsync(tester);

    expect(find.byType(ProfileScreen), findsOneWidget);
    expect(find.text('Alice Example'), findsOneWidget);
    expect(
      server.requests.where(
        (request) => request.url.path.endsWith('/cloud/user'),
      ),
      hasLength(1),
    );
  });
}

Future<void> _settleRealAsync(WidgetTester tester, {int rounds = 16}) async {
  for (var round = 0; round < rounds; round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

final class _Fixture {
  const _Fixture({
    required this.database,
    required this.accounts,
    required this.account,
    required this.vault,
    required this.api,
  });

  static Future<_Fixture> create(_ProfileServer server) async {
    final database = openTestDatabase();
    final accounts = AccountRepository(database);
    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid/nextcloud',
      loginName: 'alice',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    final vault = MemoryCredentialVault()
      ..values[account.id] = 'fixture-password';
    return _Fixture(
      database: database,
      accounts: accounts,
      account: account,
      vault: vault,
      api: HttpNextcloudApi(client: MockClient(server.call)),
    );
  }

  final AppDatabase database;
  final AccountRepository accounts;
  final StoredAccount account;
  final MemoryCredentialVault vault;
  final HttpNextcloudApi api;

  Widget profileApp() {
    return ProviderScope(
      overrides: [
        accountRepositoryProvider.overrideWithValue(accounts),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(api),
      ],
      child: localizedTestApp(home: ProfileScreen(accountId: account.id)),
    );
  }

  Widget settingsApp() {
    return ProviderScope(
      overrides: [
        accountRepositoryProvider.overrideWithValue(accounts),
        accountsProvider.overrideWith((ref) => Stream.value([account])),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(api),
      ],
      child: localizedTestApp(home: const SettingsScreen()),
    );
  }

  Future<void> dispose() async {
    api.close();
    await database.close();
  }
}

final class _ProfileServer {
  _ProfileServer({required this.supportsBusy});

  final bool supportsBusy;
  final List<http.Request> requests = [];
  var status = 'online';
  String? message = 'Focusing';
  String? icon = '🎯';

  Future<http.Response> call(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (path.endsWith('/cloud/capabilities')) {
      return _jsonResponse(_capabilities(supportsBusy: supportsBusy));
    }
    if (path.endsWith('/cloud/user')) {
      return _ocsResponse({
        'id': 'alice',
        'displayname': 'Alice Example',
        'email': 'alice@example.invalid',
      });
    }
    if (path.endsWith('/user_status/status')) {
      status = Uri.splitQueryString(request.body)['statusType']!;
      return _ocsResponse(_status());
    }
    if (path.endsWith('/user_status/message/custom')) {
      final fields = Uri.splitQueryString(request.body);
      message = fields['message'];
      icon = fields['statusIcon'];
      return _ocsResponse(_status());
    }
    if (path.endsWith('/user_status/message')) {
      message = null;
      icon = null;
      return _ocsResponse(<Object?>[]);
    }
    if (path.endsWith('/user_status')) {
      return _ocsResponse(_status());
    }
    return http.Response('', 404);
  }

  Map<String, Object?> _status() => <String, Object?>{
    'userId': 'alice',
    'message': message,
    'messageId': null,
    'messageIsPredefined': false,
    'icon': icon,
    'clearAt': null,
    'status': status,
    'statusIsUserDefined': true,
  };
}

Map<String, Object?> _capabilities({required bool supportsBusy}) {
  return <String, Object?>{
    'ocs': {
      'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
      'data': {
        'version': {
          'major': 34,
          'minor': 0,
          'micro': 1,
          'string': '34.0.1',
          'edition': '',
          'extendedSupport': false,
        },
        'capabilities': {
          'spreed': {
            'features': ['conversation-v4'],
            'config': <String, Object?>{},
          },
          'user_status': {
            'enabled': true,
            'supports_emoji': true,
            'supports_busy': supportsBusy,
          },
        },
      },
    },
  };
}

http.Response _ocsResponse(Object? data) => _jsonResponse({
  'ocs': {
    'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
    'data': data,
  },
});

http.Response _jsonResponse(Object? data) => http.Response.bytes(
  utf8.encode(jsonEncode(data)),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
