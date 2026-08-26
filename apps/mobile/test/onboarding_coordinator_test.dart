import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/credential_vault.dart';
import 'package:nextcloudtalk/features/onboarding/onboarding_coordinator.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository repository;
  late MemoryCredentialVault vault;
  late RecordingLoginPageLauncher launcher;

  setUp(() {
    database = openTestDatabase();
    repository = AccountRepository(database);
    vault = MemoryCredentialVault();
    launcher = RecordingLoginPageLauncher();
  });

  tearDown(() => database.close());

  testWidgets(
    'external login waits for the mobile app to return before polling',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );

        final opened = Completer<void>();
        final launcher = ExternalLoginPageLauncher(
          opener: (_) async {
            opened.complete();
            return true;
          },
        );

        var completed = false;
        final launch = launcher
            .open(Uri.parse('https://cloud.example.invalid/index.php/login/v2'))
            .then((value) {
              completed = true;
              return value;
            });
        await opened.future;
        await tester.pump();
        expect(completed, isFalse);

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(completed, isFalse);

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();

        expect(await launch, isTrue);
        expect(completed, isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  test(
    'persists credentials and account only after Talk is confirmed',
    () async {
      final api = _onboardingApi(withTalk: true);
      addTearDown(api.close);
      final coordinator = OnboardingCoordinator(
        api: api,
        accounts: repository,
        credentials: vault,
        launcher: launcher,
        pollInterval: Duration.zero,
      );

      final pending = await coordinator.start('https://cloud.example.invalid');
      await coordinator.openLoginPage(pending);
      final account = await coordinator.waitForAccount(
        pending,
        CancellationSignal(),
      );

      expect(launcher.openedUri, pending.initialization.loginUri);
      expect(account.loginName, 'fixture-user');
      expect(vault.values[account.id], 'fixture-app-password-never-use');
      expect((await repository.watchAccounts().first), hasLength(1));
    },
  );

  test('reauthenticates only the requested stored account identity', () async {
    await repository.upsertAccount(
      accountId: 'existing-account',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    await repository.recordSyncError(
      'existing-account',
      'reauthenticationRequired',
    );
    vault.values['existing-account'] = 'expired-app-password';
    final api = _onboardingApi(withTalk: true);
    addTearDown(api.close);
    final coordinator = OnboardingCoordinator(
      api: api,
      accounts: repository,
      credentials: vault,
      launcher: launcher,
      pollInterval: Duration.zero,
    );

    final pending = await coordinator.start('https://cloud.example.invalid');
    final account = await coordinator.waitForAccount(
      pending,
      CancellationSignal(),
      expectedAccountId: 'existing-account',
    );

    expect(account.id, 'existing-account');
    expect(account.lastSyncError, null);
    expect(vault.values['existing-account'], 'fixture-app-password-never-use');
    expect(await repository.watchAccounts().first, hasLength(1));
  });

  test(
    'wrong reauthentication identity never replaces the credential',
    () async {
      await repository.upsertAccount(
        accountId: 'existing-account',
        serverUrl: 'https://cloud.example.invalid',
        loginName: 'different-user',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      await repository.recordSyncError(
        'existing-account',
        'reauthenticationRequired',
      );
      vault.values['existing-account'] = 'expired-app-password';
      var revokeCalls = 0;
      final api = _onboardingApi(withTalk: true, onRevoke: () => revokeCalls++);
      addTearDown(api.close);
      final coordinator = OnboardingCoordinator(
        api: api,
        accounts: repository,
        credentials: vault,
        launcher: launcher,
        pollInterval: Duration.zero,
      );

      final pending = await coordinator.start('https://cloud.example.invalid');
      await expectLater(
        coordinator.waitForAccount(
          pending,
          CancellationSignal(),
          expectedAccountId: 'existing-account',
        ),
        throwsA(
          isA<OnboardingFailure>().having(
            (error) => error.code,
            'code',
            OnboardingFailureCode.accountIdentityMismatch,
          ),
        ),
      );

      expect(vault.values['existing-account'], 'expired-app-password');
      final account = await repository.getAccount('existing-account');
      expect(account?.lastSyncError, 'reauthenticationRequired');
      expect(await repository.watchAccounts().first, hasLength(1));
      expect(revokeCalls, 1);
    },
  );

  test('cancellation during login poll does not persist the account', () async {
    final pollStarted = Completer<void>();
    final releasePoll = Completer<void>();
    final api = _onboardingApi(
      withTalk: true,
      onPoll: pollStarted.complete,
      pollGate: releasePoll.future,
    );
    addTearDown(api.close);
    final coordinator = OnboardingCoordinator(
      api: api,
      accounts: repository,
      credentials: vault,
      launcher: launcher,
      pollInterval: Duration.zero,
    );
    final pending = await coordinator.start('https://cloud.example.invalid');
    final cancellation = CancellationSignal();

    final result = coordinator.waitForAccount(pending, cancellation);
    await pollStarted.future;
    cancellation.cancel();
    releasePoll.complete();

    await expectLater(result, throwsA(isA<OnboardingCancelled>()));
    expect(vault.values, isEmpty);
    expect(await repository.watchAccounts().first, isEmpty);
  });

  test(
    'cancellation during capabilities does not persist the account',
    () async {
      final capabilitiesStarted = Completer<void>();
      final releaseCapabilities = Completer<void>();
      final api = _onboardingApi(
        withTalk: true,
        onCapabilities: capabilitiesStarted.complete,
        capabilitiesGate: releaseCapabilities.future,
      );
      addTearDown(api.close);
      final coordinator = OnboardingCoordinator(
        api: api,
        accounts: repository,
        credentials: vault,
        launcher: launcher,
        pollInterval: Duration.zero,
      );
      final pending = await coordinator.start('https://cloud.example.invalid');
      final cancellation = CancellationSignal();

      final result = coordinator.waitForAccount(pending, cancellation);
      await capabilitiesStarted.future;
      cancellation.cancel();
      releaseCapabilities.complete();

      await expectLater(result, throwsA(isA<OnboardingCancelled>()));
      expect(vault.values, isEmpty);
      expect(await repository.watchAccounts().first, isEmpty);
    },
  );

  test(
    'does not persist a login when the server has no Talk capability',
    () async {
      final api = _onboardingApi(withTalk: false);
      addTearDown(api.close);
      final coordinator = OnboardingCoordinator(
        api: api,
        accounts: repository,
        credentials: vault,
        launcher: launcher,
        pollInterval: Duration.zero,
      );

      final pending = await coordinator.start('https://cloud.example.invalid');
      await expectLater(
        coordinator.waitForAccount(pending, CancellationSignal()),
        throwsA(
          isA<OnboardingFailure>().having(
            (error) => error.code,
            'code',
            OnboardingFailureCode.talkUnavailable,
          ),
        ),
      );

      expect(vault.values, isEmpty);
      expect(await repository.watchAccounts().first, isEmpty);
    },
  );

  test(
    'does not delete an existing credential when reading it fails',
    () async {
      await repository.upsertAccount(
        accountId: 'existing-account',
        serverUrl: 'https://cloud.example.invalid',
        loginName: 'fixture-user',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final faultingVault = _FaultingCredentialVault(
        values: {'existing-account': 'existing-app-password'},
        readFailure: StateError('credential read failed'),
      );
      final api = _onboardingApi(withTalk: true);
      addTearDown(api.close);
      final coordinator = OnboardingCoordinator(
        api: api,
        accounts: repository,
        credentials: faultingVault,
        launcher: launcher,
        pollInterval: Duration.zero,
      );

      final pending = await coordinator.start('https://cloud.example.invalid');
      await expectLater(
        coordinator.waitForAccount(pending, CancellationSignal()),
        throwsA(
          isA<OnboardingFailure>().having(
            (error) => error.code,
            'code',
            OnboardingFailureCode.localPersistence,
          ),
        ),
      );

      expect(faultingVault.values['existing-account'], 'existing-app-password');
      expect(faultingVault.deleteCalls, 0);
      expect(faultingVault.writeCalls, 0);
    },
  );

  test('does not compensate a credential write that never happened', () async {
    final faultingVault = _FaultingCredentialVault(writeFailuresRemaining: 1);
    final api = _onboardingApi(withTalk: true);
    addTearDown(api.close);
    final coordinator = OnboardingCoordinator(
      api: api,
      accounts: repository,
      credentials: faultingVault,
      launcher: launcher,
      pollInterval: Duration.zero,
    );

    final pending = await coordinator.start('https://cloud.example.invalid');
    await expectLater(
      coordinator.waitForAccount(pending, CancellationSignal()),
      throwsA(
        isA<OnboardingFailure>().having(
          (error) => error.code,
          'code',
          OnboardingFailureCode.localPersistence,
        ),
      ),
    );

    expect(faultingVault.values, isEmpty);
    expect(faultingVault.writeCalls, 1);
    expect(faultingVault.deleteCalls, 0);
    expect(await repository.watchAccounts().first, isEmpty);
  });

  test(
    'rolls back a written credential when the database commit fails',
    () async {
      final interceptor = _FailNextCommitInterceptor();
      await database.close();
      database = AppDatabase.forTesting(
        NativeDatabase.memory().interceptWith(interceptor),
      );
      await database.customSelect('SELECT 1').get();
      interceptor.failNextCommit = true;
      repository = AccountRepository(database);
      final faultingVault = _FaultingCredentialVault();
      final api = _onboardingApi(withTalk: true);
      addTearDown(api.close);
      final coordinator = OnboardingCoordinator(
        api: api,
        accounts: repository,
        credentials: faultingVault,
        launcher: launcher,
        pollInterval: Duration.zero,
      );

      final pending = await coordinator.start('https://cloud.example.invalid');
      await expectLater(
        coordinator.waitForAccount(pending, CancellationSignal()),
        throwsA(
          isA<OnboardingFailure>().having(
            (error) => error.code,
            'code',
            OnboardingFailureCode.localPersistence,
          ),
        ),
      );

      expect(faultingVault.writeCalls, 1);
      expect(faultingVault.deleteCalls, 1);
      expect(faultingVault.values, isEmpty);
      expect(await repository.watchAccounts().first, isEmpty);
    },
  );
}

HttpNextcloudApi _onboardingApi({
  required bool withTalk,
  VoidCallback? onPoll,
  Future<void>? pollGate,
  VoidCallback? onCapabilities,
  Future<void>? capabilitiesGate,
  VoidCallback? onRevoke,
}) {
  return HttpNextcloudApi(
    client: MockClient((request) async {
      if (request.url.path == '/status.php') {
        return http.Response(jsonEncode(readyStatusJson()), 200);
      }
      if (request.url.path.endsWith('/login/v2')) {
        return http.Response(jsonEncode(loginInitializationJson()), 200);
      }
      if (request.url.path.endsWith('/login/v2/poll')) {
        onPoll?.call();
        await pollGate;
        return http.Response(jsonEncode(loginSuccessJson()), 200);
      }
      if (request.url.path.endsWith('/cloud/capabilities')) {
        onCapabilities?.call();
        await capabilitiesGate;
        expect(request.headers['Authorization'], startsWith('Basic '));
        return http.Response(
          jsonEncode(capabilitiesJson(withTalk: withTalk)),
          200,
        );
      }
      if (request.method == 'DELETE' &&
          request.url.path.endsWith('/core/apppassword')) {
        onRevoke?.call();
        return http.Response(
          jsonEncode(<String, Object?>{
            'ocs': <String, Object?>{
              'meta': <String, Object?>{
                'status': 'ok',
                'statuscode': 200,
                'message': 'OK',
              },
              'data': <String, Object?>{},
            },
          }),
          200,
        );
      }
      return http.Response('', 404);
    }),
  );
}

final class _FaultingCredentialVault implements CredentialVault {
  _FaultingCredentialVault({
    Map<String, String> values = const {},
    this.readFailure,
    this.writeFailuresRemaining = 0,
  }) : values = Map.of(values);

  final Map<String, String> values;
  final Object? readFailure;
  int writeFailuresRemaining;
  int writeCalls = 0;
  int deleteCalls = 0;

  @override
  Future<void> deleteAppPassword(String accountId) async {
    deleteCalls++;
    values.remove(accountId);
  }

  @override
  Future<String?> readAppPassword(String accountId) async {
    final failure = readFailure;
    if (failure != null) {
      throw failure;
    }
    return values[accountId];
  }

  @override
  Future<void> writeAppPassword(String accountId, String appPassword) async {
    writeCalls++;
    if (writeFailuresRemaining > 0) {
      writeFailuresRemaining--;
      throw StateError('credential write failed');
    }
    values[accountId] = appPassword;
  }
}

final class _FailNextCommitInterceptor extends QueryInterceptor {
  bool failNextCommit = false;

  @override
  Future<void> commitTransaction(TransactionExecutor inner) {
    if (failNextCommit) {
      failNextCommit = false;
      throw StateError('database commit failed');
    }
    return super.commitTransaction(inner);
  }
}
