import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_shell.dart';
import 'package:nextcloudtalk/features/conversations/conversation_sync_service.dart';
import 'package:nextcloudtalk/features/conversations/unread_badge.dart';
import 'package:nextcloudtalk/features/onboarding/onboarding_screen.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'test_support.dart';

void main() {
  _registerVisibleListPaceTest();
  testWidgets(
    'a hidden list keeps the failure backoff',
    _verifyHiddenListBackoff,
  );
  testWidgets('manual refresh queues a full sync during foreground progress', (
    tester,
  ) async {
    // The expanded shell folds its list below 620 px of conversation width,
    // so the default 800x600 surface hides the header these tests reach for.
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    final vault = MemoryCredentialVault();
    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    vault.values[account.id] = 'fixture-app-password-never-use';

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
      client: _CallbackClient((request) async {
        if (request is! http.Abortable) {
          throw StateError('Conversation requests must be abortable.');
        }
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return _response(jsonEncode(capabilitiesJson()), 200);
        }
        if (request.url.path.endsWith('/apps/spreed/api/v4/room')) {
          conversationRequests++;
          modifiedSinceValues.add(request.url.queryParameters['modifiedSince']);
          if (conversationRequests == 2) {
            incrementalStarted.complete();
            await releaseIncremental.future;
          }
          return _response(
            jsonEncode(
              readFixtureJson(
                'conversation-list/fixtures/'
                'conversations-full.response.json',
              ),
            ),
            200,
            headers: <String, String>{
              'X-Nextcloud-Talk-Hash': 'fixture-hash-$conversationRequests',
              'X-Nextcloud-Talk-Modified-Before':
                  '${1724300000 + conversationRequests}',
              'X-Nextcloud-Talk-Federation-Invites': '0',
            },
          );
        }
        if (request.url.path.contains('/avatar')) {
          return _response('', 404);
        }
        return _response('', 404);
      }),
    );
    addTearDown(api.close);
    final service = ConversationSyncService(
      accounts: accounts,
      credentials: vault,
      api: api,
    );
    await tester.runAsync(() => service.sync(account.id));
    final selectedAccounts = StreamController<StoredAccount?>();
    addTearDown(selectedAccounts.close);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          // Push owns separate call-chain coverage; this test only exercises
          // conversation sync and must not open its unrelated Drift watcher.
          clientPushEnabledProvider.overrideWithValue(false),
          credentialVaultProvider.overrideWithValue(vault),
          nextcloudApiProvider.overrideWithValue(api),
          conversationSyncServiceProvider.overrideWithValue(service),
          accountsProvider.overrideWith((ref) => Stream.value([account])),
          selectedAccountProvider.overrideWith(
            (ref) => selectedAccounts.stream,
          ),
          unreadCountsProvider.overrideWith(
            (ref) => Stream.value(const <String, int>{}),
          ),
          conversationsProvider.overrideWith(
            (ref, accountId) => Stream.value(const <CachedConversation>[]),
          ),
        ],
        child: localizedTestApp(home: const ConversationShell()),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    selectedAccounts.add(account);
    await _pumpUntil(
      tester,
      () => find.byType(RefreshIndicator).evaluate().isNotEmpty,
    );
    await _pumpUntil(tester, () => incrementalStarted.isCompleted);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    final manualRefresh = tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show();
    await tester.pump();
    releaseIncremental.complete();
    await _pumpUntil(tester, () => conversationRequests == 3);
    await manualRefresh;

    expect(modifiedSinceValues, [null, '1724300001', null]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'conversation list sync restarts for the selected account on resume',
    (tester) => _verifyLifecycleSync(tester, desktop: false),
  );

  testWidgets(
    'desktop keeps conversation sync while inactive and hidden',
    (tester) => _verifyLifecycleSync(tester, desktop: true),
  );
}

void _registerVisibleListPaceTest() {
  testWidgets(
    'a visible list syncs every 5 s and the other accounts about '
    'once a minute',
    _verifyVisibleListPace,
  );
}

Future<void> _verifyHiddenListBackoff(WidgetTester tester) async {
  // A phone: once a room is selected the list is not on screen.
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final database = openTestDatabase();
  addTearDown(database.close);
  final accounts = AccountRepository(database);
  final vault = MemoryCredentialVault();
  final account = await accounts.upsertAccount(
    accountId: 'account-a',
    serverUrl: 'https://cloud.example.invalid',
    loginName: 'fixture-user',
    serverProductName: 'Nextcloud',
    createdAt: DateTime.utc(2026, 1, 1),
  );
  vault.values[account.id] = 'fixture-app-password-never-use';
  await database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: account.id,
          token: 'roomhidden',
          displayName: 'Hidden list room',
          description: '',
          lastActivity: 1724300000,
          unreadMessages: 0,
          favorite: false,
          rawJson: '{}',
        ),
      );

  var attempts = 0;
  final api = HttpNextcloudApi(
    client: _CallbackClient((request) async {
      if (request.url.path.endsWith('/cloud/capabilities')) {
        attempts++;
      }
      return _response('', 503);
    }),
  );
  addTearDown(api.close);
  final service = ConversationSyncService(
    accounts: accounts,
    credentials: vault,
    api: api,
  );

  Future<void> advance(Duration duration) async {
    for (var second = 0; second < duration.inSeconds; second++) {
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
    }
  }

  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        clientPushEnabledProvider.overrideWithValue(false),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(api),
        conversationSyncServiceProvider.overrideWithValue(service),
        accountsProvider.overrideWith((ref) => Stream.value([account])),
        selectedAccountProvider.overrideWith((ref) => Stream.value(account)),
        // The room is selected but not listed, so no chat pane is built.
        unreadCountsProvider.overrideWith(
          (ref) => Stream.value(const <String, int>{}),
        ),
        conversationsProvider.overrideWith(
          (ref, accountId) => Stream.value(const <CachedConversation>[]),
        ),
      ],
      child: localizedTestApp(home: const ConversationShell()),
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  await _pumpUntil(tester, () => attempts >= 1);
  final workspace = find.byType(ConversationWorkspace);
  tester.widget<ConversationWorkspace>(workspace).onOpenCreatedConversation!(
    'roomhidden',
  );
  await _pumpUntil(
    tester,
    () =>
        tester
            .widget<ConversationWorkspace>(workspace)
            .selectedConversationToken ==
        'roomhidden',
  );

  // Long enough for the backoff to reach its 30 s ceiling.
  await advance(const Duration(seconds: 80));
  final before = attempts;
  await advance(const Duration(seconds: 90));

  // 24 to 30 s apart at the ceiling. Skipped rounds that count as successes
  // would bring a request about every 12 s.
  expect(attempts - before, inInclusiveRange(2, 5));
  expect(tester.takeException(), isNull);
}

Future<void> _verifyVisibleListPace(WidgetTester tester) async {
  final database = openTestDatabase();
  addTearDown(database.close);
  final accounts = AccountRepository(database);
  final vault = MemoryCredentialVault();
  final other = await accounts.upsertAccount(
    accountId: 'account-b',
    serverUrl: 'https://other.example.invalid',
    loginName: 'other-user',
    serverProductName: 'Nextcloud',
    createdAt: DateTime.utc(2026, 1, 1),
  );
  final account = await accounts.upsertAccount(
    accountId: 'account-a',
    serverUrl: 'https://cloud.example.invalid',
    loginName: 'fixture-user',
    serverProductName: 'Nextcloud',
    createdAt: DateTime.utc(2026, 1, 2),
  );
  vault.values[account.id] = 'fixture-app-password-never-use';
  vault.values[other.id] = 'fixture-app-password-never-use';

  final listRequests = <String, int>{};
  final api = HttpNextcloudApi(
    client: _CallbackClient((request) async {
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return _response(jsonEncode(capabilitiesJson()), 200);
      }
      if (request.url.path.endsWith('/apps/spreed/api/v4/room')) {
        final count = listRequests.update(
          request.url.host,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
        final response =
            jsonDecode(
                  jsonEncode(
                    readFixtureJson(
                      'conversation-list/fixtures/'
                      'conversations-full.response.json',
                    ),
                  ),
                )!
                as Map<String, Object?>;
        if (count > 1) {
          (response['ocs']! as Map<String, Object?>)['data'] = <Object?>[];
        }
        return _response(
          jsonEncode(response),
          200,
          headers: <String, String>{
            'X-Nextcloud-Talk-Hash': 'fixture-hash-$count',
            'X-Nextcloud-Talk-Modified-Before': '${1724300000 + count}',
            'X-Nextcloud-Talk-Federation-Invites': '0',
          },
        );
      }
      return _response('', 404);
    }),
  );
  addTearDown(api.close);
  final service = ConversationSyncService(
    accounts: accounts,
    credentials: vault,
    api: api,
  );
  final selectedAccounts = StreamController<StoredAccount?>();
  addTearDown(selectedAccounts.close);

  int selectedRequests() => listRequests['cloud.example.invalid'] ?? 0;
  int otherRequests() => listRequests['other.example.invalid'] ?? 0;

  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        clientPushEnabledProvider.overrideWithValue(false),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(api),
        conversationSyncServiceProvider.overrideWithValue(service),
        accountsProvider.overrideWith((ref) => Stream.value([account, other])),
        selectedAccountProvider.overrideWith((ref) => selectedAccounts.stream),
        unreadCountsProvider.overrideWith(
          (ref) => Stream.value(const <String, int>{}),
        ),
        conversationsProvider.overrideWith(
          (ref, accountId) => Stream.value(const <CachedConversation>[]),
        ),
      ],
      child: localizedTestApp(home: const ConversationShell()),
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  selectedAccounts.add(account);
  await _pumpUntil(tester, () => selectedRequests() == 1);

  // No conversation is open, so the list is on screen: one round per 5 s.
  await tester.pump(const Duration(seconds: 5));
  await _pumpUntil(tester, () => selectedRequests() == 2);
  expect(otherRequests(), 0);

  // The twelfth round, about a minute in, also refreshes the other account.
  for (var round = 2; round < 12; round++) {
    await tester.pump(const Duration(seconds: 5));
    await _pumpUntil(tester, () => selectedRequests() == round + 1);
  }
  await _pumpUntil(tester, () => otherRequests() == 1);
  expect(selectedRequests(), 12);
  expect(tester.takeException(), isNull);
}

Future<void> _verifyLifecycleSync(
  WidgetTester tester, {
  required bool desktop,
}) async {
  final previousPlatform = debugDefaultTargetPlatformOverride;
  debugDefaultTargetPlatformOverride = desktop
      ? TargetPlatform.windows
      : TargetPlatform.android;
  // Reset inside the body, not in addTearDown: the framework verifies that
  // no foundation debug variable is still set BEFORE tear-downs run, so a
  // reset scheduled there arrives too late and fails the test it cleaned up
  // after.
  try {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    final vault = MemoryCredentialVault();
    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    vault.values[account.id] = 'fixture-app-password-never-use';

    var conversationRequests = 0;
    final api = HttpNextcloudApi(
      client: _CallbackClient((request) async {
        expect(request, isA<http.Abortable>());
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return _response(jsonEncode(capabilitiesJson()), 200);
        }
        if (request.url.path.endsWith('/apps/spreed/api/v4/room')) {
          conversationRequests++;
          final response =
              jsonDecode(
                    jsonEncode(
                      readFixtureJson(
                        'conversation-list/fixtures/'
                        'conversations-full.response.json',
                      ),
                    ),
                  )!
                  as Map<String, Object?>;
          if (conversationRequests > 1) {
            final ocs = response['ocs']! as Map<String, Object?>;
            ocs['data'] = <Object?>[];
          }
          return _response(
            jsonEncode(response),
            200,
            headers: <String, String>{
              'X-Nextcloud-Talk-Hash': 'fixture-hash-$conversationRequests',
              'X-Nextcloud-Talk-Modified-Before':
                  '${1724300000 + conversationRequests}',
              'X-Nextcloud-Talk-Federation-Invites': '0',
            },
          );
        }
        if (request.url.path.contains('/avatar')) {
          return _response('', 404);
        }
        return _response('', 404);
      }),
    );
    addTearDown(api.close);
    final service = ConversationSyncService(
      accounts: accounts,
      credentials: vault,
      api: api,
    );
    final selectedAccounts = StreamController<StoredAccount?>();
    addTearDown(selectedAccounts.close);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          // Push owns separate call-chain coverage; this test only exercises
          // conversation sync and must not open its unrelated Drift watcher.
          clientPushEnabledProvider.overrideWithValue(false),
          credentialVaultProvider.overrideWithValue(vault),
          nextcloudApiProvider.overrideWithValue(api),
          conversationSyncServiceProvider.overrideWithValue(service),
          accountsProvider.overrideWith((ref) => Stream.value([account])),
          selectedAccountProvider.overrideWith(
            (ref) => selectedAccounts.stream,
          ),
          unreadCountsProvider.overrideWith(
            (ref) => Stream.value(const <String, int>{}),
          ),
          conversationsProvider.overrideWith(
            (ref, accountId) => Stream.value(const <CachedConversation>[]),
          ),
        ],
        child: localizedTestApp(home: const ConversationShell()),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    selectedAccounts.add(account);
    await _pumpUntil(
      tester,
      () =>
          find
              .byKey(const Key('conversation-shell-expanded'))
              .evaluate()
              .isNotEmpty ||
          find
              .byKey(const Key('conversation-shell-compact'))
              .evaluate()
              .isNotEmpty,
    );
    await _pumpUntil(tester, () => conversationRequests == 1);

    if (desktop) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 16));
      await _pumpUntil(tester, () => conversationRequests == 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump(const Duration(seconds: 16));
      await _pumpUntil(tester, () => conversationRequests == 3);
    }
    final requestsBeforePause = desktop ? 3 : 1;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    expect(conversationRequests, requestsBeforePause);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await _pumpUntil(
      tester,
      () => conversationRequests == requestsBeforePause + 1,
    );
    expect(tester.takeException(), isNull);

    selectedAccounts.add(null);
    await _pumpUntil(
      tester,
      () => find.byType(OnboardingScreen).evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(seconds: 16));
    expect(conversationRequests, requestsBeforePause + 1);
  } finally {
    debugDefaultTargetPlatformOverride = previousPlatform;
  }
}

typedef _RequestHandler =
    Future<http.StreamedResponse> Function(http.BaseRequest request);

final class _CallbackClient extends http.BaseClient {
  _CallbackClient(this.handler);

  final _RequestHandler handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return handler(request);
  }
}

http.StreamedResponse _response(
  String body,
  int statusCode, {
  Map<String, String> headers = const <String, String>{},
}) {
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body)),
    statusCode,
    headers: headers,
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    if (condition()) {
      return;
    }
  }
  fail('Condition was not reached');
}
