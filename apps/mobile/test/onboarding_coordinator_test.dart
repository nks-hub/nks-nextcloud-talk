import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'package:nextcloudtalk/features/settings/app_password_revocation_queue.dart';
import 'package:nextcloudtalk/network/account_http_client.dart';
import 'package:talk_protocol/talk_protocol.dart';
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

  Future<void> failNextAccountCommit() async {
    final interceptor = _FailNextCommitInterceptor();
    await database.close();
    database = AppDatabase.forTesting(
      NativeDatabase.memory().interceptWith(interceptor),
    );
    await database.customSelect('SELECT 1').get();
    interceptor.failNextCommit = true;
    repository = AccountRepository(database);
  }

  test('external login polls without the app ever being hidden', () async {
    var polls = 0;
    final api = _onboardingApi(
      withTalk: true,
      onPoll: () {
        // The first poll fails the way a socket iOS suspended does.
        if (polls++ == 0) {
          throw http.ClientException('connection lost');
        }
      },
    );
    addTearDown(api.close);
    final coordinator = OnboardingCoordinator(
      api: api,
      accounts: repository,
      credentials: vault,
      launcher: ExternalLoginPageLauncher(opener: (_) async => true),
      pollInterval: Duration.zero,
    );

    final pending = await coordinator.start('https://cloud.example.invalid');
    final account = await coordinator.completeLogin(
      pending,
      CancellationSignal(),
    );

    expect(account.loginName, 'fixture-user');
    expect(polls, 2);
  });

  for (final heldPhase in const ['status', 'initialize']) {
    test('cancellation aborts held $heldPhase request', () async {
      final client = _HeldOnboardingRequestClient(heldPhase);
      final api = HttpNextcloudApi(
        client: client,
        requestTimeout: const Duration(seconds: 20),
      );
      addTearDown(api.close);
      final coordinator = OnboardingCoordinator(
        api: api,
        accounts: repository,
        credentials: vault,
        launcher: launcher,
      );
      final cancellation = CancellationSignal();

      final result = coordinator.start(
        'https://cloud.example.invalid',
        cancellation: cancellation,
      );
      await client.requestStarted.future;
      cancellation.cancel();

      await expectLater(
        result.timeout(const Duration(seconds: 1)),
        throwsA(isA<OnboardingCancelled>()),
      );
    });
  }

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
      final account = await coordinator.completeLogin(
        pending,
        CancellationSignal(),
      );

      expect(launcher.openedUri, pending.initialization.loginUri);
      expect(launcher.closeCount, greaterThanOrEqualTo(1));
      expect(account.loginName, 'fixture-user');
      expect(vault.values[account.id], 'fixture-app-password-never-use');
      expect((await repository.watchAccounts().first), hasLength(1));
    },
  );

  test('no poll leaves while the app is in the background', () async {
    var polls = 0;
    final api = _onboardingApi(withTalk: true, onPoll: () => polls++);
    addTearDown(api.close);
    var background = true;
    final coordinator = OnboardingCoordinator(
      api: api,
      accounts: repository,
      credentials: vault,
      launcher: launcher,
      pollInterval: const Duration(milliseconds: 5),
      inBackground: () => background,
    );
    final pending = await coordinator.start('https://cloud.example.invalid');
    final waiting = coordinator.completeLogin(pending, CancellationSignal());

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(polls, 0, reason: 'the one-time answer must not be asked for yet');

    background = false;
    final account = await waiting;
    expect(account.loginName, isNotEmpty);
    expect(polls, greaterThan(0));
  });

  test('the in-app login page is closed when the login is cancelled', () async {
    final api = _onboardingApi(withTalk: true, onPoll: () {});
    addTearDown(api.close);
    final coordinator = OnboardingCoordinator(
      api: api,
      accounts: repository,
      credentials: vault,
      launcher: launcher,
      pollInterval: Duration.zero,
    );
    final pending = await coordinator.start('https://cloud.example.invalid');
    final cancellation = CancellationSignal()..cancel();

    await expectLater(
      coordinator.completeLogin(pending, cancellation),
      throwsA(isA<OnboardingCancelled>()),
    );
    expect(launcher.closeCount, 1);
  });

  test(
    'late browser open after cancellation closes once without polling',
    () async {
      var polls = 0;
      final api = _onboardingApi(withTalk: true, onPoll: () => polls++);
      addTearDown(api.close);
      final blockedLauncher = _BlockedLoginPageLauncher();
      final coordinator = OnboardingCoordinator(
        api: api,
        accounts: repository,
        credentials: vault,
        launcher: blockedLauncher,
        pollInterval: Duration.zero,
      );
      final pending = await coordinator.start('https://cloud.example.invalid');
      final cancellation = CancellationSignal();

      final result = coordinator.completeLogin(pending, cancellation);
      await blockedLauncher.openStarted.future;
      cancellation.cancel();
      blockedLauncher.releaseOpen.complete(true);

      await expectLater(result, throwsA(isA<OnboardingCancelled>()));
      expect(blockedLauncher.closeCount, 1);
      expect(polls, 0);
    },
  );

  test('the external launcher delegates opening and closing', () async {
    final calls = <String>[];
    final launcher = ExternalLoginPageLauncher(
      opener: (uri) async {
        calls.add('open ${uri.host}');
        return true;
      },
      closer: () async => calls.add('close'),
    );

    await launcher.open(Uri.parse('https://cloud.example.invalid/login'));
    await launcher.close();

    expect(calls, ['open cloud.example.invalid', 'close']);
  });

  test(
    'an unverified certificate blocks the server check until confirmed',
    () async {
      // The transport only reports a handshake failure, so the gate is what
      // tells the user which fingerprint they are being asked about.
      final trust = CertificateTrustGate()
        ..lastEncounter = CertificateEncounter(
          host: 'cloud.example.invalid',
          fingerprint: 'ab12',
          outcome: CertificateTrustOutcome.ask(),
        );
      final api = HttpNextcloudApi(
        client: MockClient(
          (_) => throw const HandshakeException('certificate refused'),
        ),
      );
      addTearDown(api.close);
      final coordinator = OnboardingCoordinator(
        api: api,
        accounts: repository,
        credentials: vault,
        launcher: launcher,
        trust: trust,
        pollInterval: Duration.zero,
      );

      await expectLater(
        coordinator.start('https://cloud.example.invalid'),
        throwsA(
          isA<OnboardingFailure>()
              .having(
                (failure) => failure.code,
                'code',
                OnboardingFailureCode.untrustedCertificate,
              )
              .having(
                (failure) => failure.certificate?.fingerprint,
                'fingerprint',
                'ab12',
              ),
        ),
      );
    },
  );

  test(
    'a confirmed certificate is stored with the account it belongs to',
    () async {
      final trust = CertificateTrustGate(
        loadStoredPins: repository.readCertificatePins,
      )..confirm(host: 'cloud.example.invalid', fingerprint: 'f' * 64);
      final api = _onboardingApi(withTalk: true);
      addTearDown(api.close);
      final coordinator = OnboardingCoordinator(
        api: api,
        accounts: repository,
        credentials: vault,
        launcher: launcher,
        trust: trust,
        pollInterval: Duration.zero,
      );

      final pending = await coordinator.start('https://cloud.example.invalid');
      final account = await coordinator.completeLogin(
        pending,
        CancellationSignal(),
      );

      expect(await repository.readCertificatePins(), {
        'cloud.example.invalid': {'f' * 64},
      });
      expect(trust.confirmedFor('cloud.example.invalid'), null);

      // Removing the account must take its trust with it.
      await repository.purgeAccount(account.id);
      await trust.refresh();
      expect(await repository.readCertificatePins(), isEmpty);
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
    final account = await coordinator.completeLogin(
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
        coordinator.completeLogin(
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

  test('cancelled login poll retires a late one-time response', () async {
    final client = _LateGeneratedCredentialClient.loginPoll();
    final api = HttpNextcloudApi(
      client: client,
      requestTimeout: const Duration(seconds: 20),
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

    final result = coordinator.completeLogin(pending, cancellation);
    await client.requestStarted.future;
    cancellation.cancel();

    await expectLater(
      result.timeout(const Duration(seconds: 1)),
      throwsA(isA<OnboardingCancelled>()),
    );
    expect(launcher.closeCount, 1);
    expect(vault.values, isEmpty);
    expect(await repository.watchAccounts().first, isEmpty);

    client.releaseResponse();
    final queue = AppPasswordRevocationQueue(store: vault, api: api);
    await _waitForPendingRevocations(queue, 1);
    expect(client.revokedPassword, null);
  });

  test(
    'late credential survives a full queue, failed write and restart',
    () async {
      final client = _LateGeneratedCredentialClient.loginPoll(
        revokeOffline: true,
      );
      final api = HttpNextcloudApi(
        client: client,
        requestTimeout: const Duration(seconds: 20),
      );
      addTearDown(api.close);
      final pendingStore = _FailOncePendingStore(vault);
      final queue = AppPasswordRevocationQueue(store: pendingStore, api: api);
      final coordinator = OnboardingCoordinator(
        api: api,
        accounts: repository,
        credentials: vault,
        launcher: launcher,
        pendingRevocations: queue,
        pollInterval: Duration.zero,
      );
      final pending = await coordinator.start('https://cloud.example.invalid');
      final cancellation = CancellationSignal();

      final result = coordinator.completeLogin(pending, cancellation);
      await client.requestStarted.future;
      expect(await queue.unresolvedReservationCount(), 1);
      cancellation.cancel();
      await expectLater(result, throwsA(isA<OnboardingCancelled>()));

      for (var index = 0; index < 4; index++) {
        await queue.record(
          server: pending.server,
          loginName: 'queued-user-$index',
          appPassword: 'queued-password-$index',
        );
      }
      pendingStore.failNextUpdate = true;
      client.releaseResponse();
      await client.revoked.future.timeout(const Duration(seconds: 1));
      await _waitForPendingRevocations(queue, 5);
      expect(await queue.unresolvedReservationCount(), 0);

      var exchanges = 0;
      final restartedApi = _onboardingApi(
        withTalk: true,
        onOneTimeExchange: () => exchanges++,
        oneTimeAppPassword: 'unused-password',
      );
      addTearDown(restartedApi.close);
      final restarted = OnboardingCoordinator(
        api: restartedApi,
        accounts: repository,
        credentials: vault,
        launcher: launcher,
        pendingRevocations: AppPasswordRevocationQueue(
          store: pendingStore,
          api: restartedApi,
        ),
      );
      final payload =
          parseQrLoginPayload(
                'nc://onetime-login/user:fixture-user'
                '&server:https%3A//cloud.example.invalid'
                '&password:single-use-token',
              )!
              as QrLoginCredentials;

      await expectLater(
        restarted.commitScannedLogin(payload, CancellationSignal()),
        throwsA(
          isA<OnboardingFailure>()
              .having(
                (error) => error.code,
                'code',
                OnboardingFailureCode.localPersistence,
              )
              .having(
                (error) => error.cleanupIncomplete,
                'cleanupIncomplete',
                isTrue,
              ),
        ),
      );
      expect(exchanges, 0);
    },
  );

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

      final result = coordinator.completeLogin(pending, cancellation);
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
        coordinator.completeLogin(pending, CancellationSignal()),
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
        coordinator.completeLogin(pending, CancellationSignal()),
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
      coordinator.completeLogin(pending, CancellationSignal()),
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

  test('cancellation after a slow credential write rolls it back', () async {
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    final faultingVault = _FaultingCredentialVault(
      onWrite: writeStarted.complete,
      writeGate: releaseWrite.future,
    );
    var revokeCalls = 0;
    final api = _onboardingApi(withTalk: true, onRevoke: () => revokeCalls++);
    addTearDown(api.close);
    addTearDown(() {
      if (!releaseWrite.isCompleted) {
        releaseWrite.complete();
      }
    });
    final coordinator = OnboardingCoordinator(
      api: api,
      accounts: repository,
      credentials: faultingVault,
      launcher: launcher,
      pollInterval: Duration.zero,
    );
    final pending = await coordinator.start('https://cloud.example.invalid');
    final cancellation = CancellationSignal();

    final result = coordinator.completeLogin(pending, cancellation);
    await writeStarted.future;
    cancellation.cancel();
    releaseWrite.complete();

    await expectLater(result, throwsA(isA<OnboardingCancelled>()));
    expect(faultingVault.deleteCalls, 1);
    expect(faultingVault.values, isEmpty);
    expect(await repository.watchAccounts().first, isEmpty);
    expect(revokeCalls, 0);
    final queue = AppPasswordRevocationQueue(store: faultingVault, api: api);
    expect(await queue.pendingRevocationCount(), 1);
  });

  test('restart queues a generated password left before vault write', () async {
    final api = _onboardingApi(withTalk: true);
    addTearDown(api.close);
    final server = ServerBase.parse('https://cloud.example.invalid');
    final setupQueue = AppPasswordRevocationQueue(store: vault, api: api);
    final reservation = await setupQueue.reserve();
    await setupQueue.holdCredential(
      reservation: reservation,
      server: server,
      loginName: 'restart-user',
      appPassword: 'restart-app-password-never-use',
    );
    await setupQueue.updateHeldCredentialPhase(
      reservation: reservation,
      phase: AppPasswordCredentialPhase.prepared,
      accountId: 'restart-account',
    );
    await setupQueue.recoverHeldCredentials(
      accounts: repository,
      credentials: vault,
    );
    expect(
      await setupQueue.pendingRevocationCount(),
      0,
      reason: 'an active login is not mistaken for a crashed process',
    );

    final restartedQueue = AppPasswordRevocationQueue(
      store: vault,
      api: api,
      accounts: repository,
      credentials: vault,
    );
    final restarted = OnboardingCoordinator(
      api: api,
      accounts: repository,
      credentials: vault,
      launcher: launcher,
      pendingRevocations: restartedQueue,
    );
    await restarted.start('https://cloud.example.invalid');

    expect(await restartedQueue.pendingRevocationCount(), 1);
    expect(await vault.readAppPassword('restart-account'), null);
    expect(await repository.getAccount('restart-account'), null);
  });

  test('restart removes an orphan left between vault and database', () async {
    final api = _onboardingApi(withTalk: true);
    addTearDown(api.close);
    final server = ServerBase.parse('https://cloud.example.invalid');
    final setupQueue = AppPasswordRevocationQueue(store: vault, api: api);
    final reservation = await setupQueue.reserve();
    await setupQueue.holdCredential(
      reservation: reservation,
      server: server,
      loginName: 'restart-user',
      appPassword: 'restart-app-password-never-use',
    );
    await setupQueue.updateHeldCredentialPhase(
      reservation: reservation,
      phase: AppPasswordCredentialPhase.prepared,
      accountId: 'restart-account',
    );
    await vault.writeAppPassword(
      'restart-account',
      'restart-app-password-never-use',
    );
    await setupQueue.updateHeldCredentialPhase(
      reservation: reservation,
      phase: AppPasswordCredentialPhase.vaultWritten,
      accountId: 'restart-account',
    );

    final restartedQueue = AppPasswordRevocationQueue(
      store: vault,
      api: api,
      accounts: repository,
      credentials: vault,
    );
    final restarted = OnboardingCoordinator(
      api: api,
      accounts: repository,
      credentials: vault,
      launcher: launcher,
      pendingRevocations: restartedQueue,
    );
    await restarted.start('https://cloud.example.invalid');

    expect(await restartedQueue.pendingRevocationCount(), 1);
    expect(await vault.readAppPassword('restart-account'), null);
    expect(await repository.getAccount('restart-account'), null);
  });

  test('restart keeps a completed account before held release', () async {
    final api = _onboardingApi(withTalk: true);
    addTearDown(api.close);
    final server = ServerBase.parse('https://cloud.example.invalid');
    final setupQueue = AppPasswordRevocationQueue(store: vault, api: api);
    final reservation = await setupQueue.reserve();
    await setupQueue.holdCredential(
      reservation: reservation,
      server: server,
      loginName: 'restart-user',
      appPassword: 'restart-app-password-never-use',
    );
    await setupQueue.updateHeldCredentialPhase(
      reservation: reservation,
      phase: AppPasswordCredentialPhase.prepared,
      accountId: 'restart-account',
    );
    await vault.writeAppPassword(
      'restart-account',
      'restart-app-password-never-use',
    );
    await setupQueue.updateHeldCredentialPhase(
      reservation: reservation,
      phase: AppPasswordCredentialPhase.vaultWritten,
      accountId: 'restart-account',
    );
    await repository.upsertAccount(
      accountId: 'restart-account',
      serverUrl: server.value,
      loginName: 'restart-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 11, 21),
    );
    await setupQueue.updateHeldCredentialPhase(
      reservation: reservation,
      phase: AppPasswordCredentialPhase.accountCommitted,
      accountId: 'restart-account',
    );

    final restartedQueue = AppPasswordRevocationQueue(
      store: vault,
      api: api,
      accounts: repository,
      credentials: vault,
    );
    final restarted = OnboardingCoordinator(
      api: api,
      accounts: repository,
      credentials: vault,
      launcher: launcher,
      pendingRevocations: restartedQueue,
    );
    await restarted.start('https://cloud.example.invalid');

    expect(await restartedQueue.pendingCount(), 0);
    expect(await vault.readAppPassword('restart-account'), isA<String>());
    expect(
      await repository.getAccount('restart-account'),
      isA<StoredAccount>(),
    );
  });

  test('revokes a new login password when the database commit fails', () async {
    await failNextAccountCommit();
    final faultingVault = _FaultingCredentialVault();
    var revokeCalls = 0;
    final api = _onboardingApi(withTalk: true, onRevoke: () => revokeCalls++);
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
      coordinator.completeLogin(pending, CancellationSignal()),
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
    expect(revokeCalls, 1);
    expect(await repository.watchAccounts().first, isEmpty);
  });

  test('revokes a one-time QR password after a database failure', () async {
    await failNextAccountCommit();
    var revokeCalls = 0;
    final api = _onboardingApi(
      withTalk: true,
      oneTimeAppPassword: 'exchanged-app-password-never-use',
      onRevoke: () => revokeCalls++,
    );
    addTearDown(api.close);
    final coordinator = OnboardingCoordinator(
      api: api,
      accounts: repository,
      credentials: vault,
      launcher: launcher,
      pollInterval: Duration.zero,
    );
    final payload =
        parseQrLoginPayload(
              'nc://onetime-login/user:fixture-user'
              '&server:https%3A//cloud.example.invalid'
              '&password:single-use-token',
            )!
            as QrLoginCredentials;

    await expectLater(
      coordinator.commitScannedLogin(payload, CancellationSignal()),
      throwsA(isA<OnboardingFailure>()),
    );

    expect(revokeCalls, 1);
    expect(vault.values, isEmpty);
  });

  test('never revokes a shared QR password after a database failure', () async {
    await failNextAccountCommit();
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
    final payload =
        parseQrLoginPayload(
              'nc://login/user:fixture-user'
              '&server:https%3A//cloud.example.invalid'
              '&password:shared-app-password-never-use',
            )!
            as QrLoginCredentials;

    await expectLater(
      coordinator.commitScannedLogin(payload, CancellationSignal()),
      throwsA(isA<OnboardingFailure>()),
    );

    expect(revokeCalls, 0);
    expect(vault.values, isEmpty);
  });

  test('queues a new password when immediate revocation fails', () async {
    await failNextAccountCommit();
    final api = _onboardingApi(
      withTalk: true,
      revokeFailure: http.ClientException('offline'),
    );
    addTearDown(api.close);
    final pendingStore = MemoryCredentialVault();
    final queue = AppPasswordRevocationQueue(store: pendingStore, api: api);
    final coordinator = OnboardingCoordinator(
      api: api,
      accounts: repository,
      credentials: vault,
      launcher: launcher,
      pendingRevocations: queue,
      pollInterval: Duration.zero,
    );
    final pending = await coordinator.start('https://cloud.example.invalid');

    await expectLater(
      coordinator.completeLogin(pending, CancellationSignal()),
      throwsA(isA<OnboardingFailure>()),
    );

    expect(await queue.pendingCount(), 1);
    expect(vault.values, isEmpty);
  });

  test('a full cleanup queue blocks another generated password', () async {
    var polls = 0;
    final api = _onboardingApi(withTalk: true, onPoll: () => polls++);
    addTearDown(api.close);
    final pendingStore = MemoryCredentialVault();
    final queue = AppPasswordRevocationQueue(store: pendingStore, api: api);
    final server = ServerBase.parse('https://cloud.example.invalid');
    for (
      var index = 0;
      index < AppPasswordRevocationQueue.maximumEntries;
      index++
    ) {
      await queue.record(
        server: server,
        loginName: 'old-user-$index',
        appPassword: 'old-password-$index',
      );
    }
    final coordinator = OnboardingCoordinator(
      api: api,
      accounts: repository,
      credentials: vault,
      launcher: launcher,
      pendingRevocations: queue,
      pollInterval: Duration.zero,
    );
    final pending = await coordinator.start('https://cloud.example.invalid');

    await expectLater(
      coordinator.completeLogin(pending, CancellationSignal()),
      throwsA(
        isA<OnboardingFailure>()
            .having(
              (error) => error.code,
              'code',
              OnboardingFailureCode.localPersistence,
            )
            .having(
              (error) => error.cleanupIncomplete,
              'cleanupIncomplete',
              isTrue,
            ),
      ),
    );

    expect(polls, 0);
    expect(launcher.openedUri, null);
    expect(
      await queue.pendingCount(),
      AppPasswordRevocationQueue.maximumEntries,
    );
  });

  test('a corrupt cleanup queue blocks one-time credential creation', () async {
    const corrupt = 'not json';
    vault.pendingRevocations = corrupt;
    var exchanges = 0;
    final api = _onboardingApi(
      withTalk: true,
      onOneTimeExchange: () => exchanges++,
      oneTimeAppPassword: 'unused-password',
    );
    addTearDown(api.close);
    final coordinator = OnboardingCoordinator(
      api: api,
      accounts: repository,
      credentials: vault,
      launcher: launcher,
    );
    final payload =
        parseQrLoginPayload(
              'nc://onetime-login/user:fixture-user'
              '&server:https%3A//cloud.example.invalid'
              '&password:single-use-token',
            )!
            as QrLoginCredentials;

    await expectLater(
      coordinator.commitScannedLogin(payload, CancellationSignal()),
      throwsA(
        isA<OnboardingFailure>()
            .having(
              (error) => error.code,
              'code',
              OnboardingFailureCode.localPersistence,
            )
            .having(
              (error) => error.cleanupIncomplete,
              'cleanupIncomplete',
              isTrue,
            ),
      ),
    );

    expect(exchanges, 0);
    expect(vault.pendingRevocations, corrupt);
  });

  test('reports an incomplete local rollback instead of hiding it', () async {
    await failNextAccountCommit();
    final faultingVault = _FaultingCredentialVault(deleteFailuresRemaining: 1);
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
      coordinator.completeLogin(pending, CancellationSignal()),
      throwsA(
        isA<OnboardingFailure>().having(
          (error) => error.cleanupIncomplete,
          'cleanupIncomplete',
          isTrue,
        ),
      ),
    );

    expect(faultingVault.values, isNotEmpty);
  });

  test(
    'a scanned app password creates the account without any polling',
    () async {
      var polls = 0;
      final api = _onboardingApi(withTalk: true, onPoll: () => polls++);
      final coordinator = OnboardingCoordinator(
        api: api,
        accounts: repository,
        credentials: vault,
        launcher: launcher,
        pollInterval: Duration.zero,
      );

      final payload =
          parseQrLoginPayload(
                'nc://login/user:fixture-user'
                '&server:https%3A//cloud.example.invalid'
                '&password:fixture-app-password-never-use',
              )!
              as QrLoginCredentials;
      final account = await coordinator.commitScannedLogin(
        payload,
        CancellationSignal(),
      );

      expect(polls, 0);
      expect(launcher.openedUri, null);
      expect(account.loginName, 'fixture-user');
      expect(account.serverUrl, 'https://cloud.example.invalid');
      expect(
        await vault.readAppPassword(account.id),
        'fixture-app-password-never-use',
      );
    },
  );

  test('one-time exchange starts only after durable reservation', () async {
    var exchanges = 0;
    final api = _onboardingApi(
      withTalk: true,
      onOneTimeExchange: () {
        expect(vault.pendingRevocations, isA<String>());
        exchanges++;
      },
      oneTimeAppPassword: 'exchanged-app-password-never-use',
    );
    final coordinator = OnboardingCoordinator(
      api: api,
      accounts: repository,
      credentials: vault,
      launcher: launcher,
      pollInterval: Duration.zero,
    );

    final payload =
        parseQrLoginPayload(
              'nc://onetime-login/user:fixture-user'
              '&server:https%3A//cloud.example.invalid'
              '&password:single-use-token',
            )!
            as QrLoginCredentials;
    final account = await coordinator.commitScannedLogin(
      payload,
      CancellationSignal(),
    );

    expect(exchanges, 1);
    expect(
      await vault.readAppPassword(account.id),
      'exchanged-app-password-never-use',
    );
  });

  test('cancelled QR exchange retires its late app password', () async {
    final client = _LateGeneratedCredentialClient.oneTimeExchange();
    final api = HttpNextcloudApi(
      client: client,
      requestTimeout: const Duration(seconds: 20),
    );
    addTearDown(api.close);
    final coordinator = OnboardingCoordinator(
      api: api,
      accounts: repository,
      credentials: vault,
      launcher: launcher,
      pollInterval: Duration.zero,
    );
    final payload =
        parseQrLoginPayload(
              'nc://onetime-login/user:fixture-user'
              '&server:https%3A//cloud.example.invalid'
              '&password:single-use-token',
            )!
            as QrLoginCredentials;
    final cancellation = CancellationSignal();

    final result = coordinator.commitScannedLogin(payload, cancellation);
    await client.requestStarted.future;
    cancellation.cancel();

    await expectLater(
      result.timeout(const Duration(seconds: 1)),
      throwsA(isA<OnboardingCancelled>()),
    );
    expect(vault.values, isEmpty);
    expect(await repository.watchAccounts().first, isEmpty);

    client.releaseResponse();
    final queue = AppPasswordRevocationQueue(store: vault, api: api);
    await _waitForPendingRevocations(queue, 1);
    expect(client.revokedPassword, null);
  });

  test('a spent one-time token fails without storing anything', () async {
    final api = _onboardingApi(withTalk: true);
    final coordinator = OnboardingCoordinator(
      api: api,
      accounts: repository,
      credentials: vault,
      launcher: launcher,
      pollInterval: Duration.zero,
    );

    final payload =
        parseQrLoginPayload(
              'nc://onetime-login/user:fixture-user'
              '&server:https%3A//cloud.example.invalid'
              '&password:already-spent-token',
            )!
            as QrLoginCredentials;

    await expectLater(
      coordinator.commitScannedLogin(payload, CancellationSignal()),
      throwsA(
        isA<OnboardingFailure>().having(
          (error) => error.code,
          'code',
          OnboardingFailureCode.scannedLoginRejected,
        ),
      ),
    );
    expect(vault.values, isEmpty);
    expect(await repository.watchAccounts().first, isEmpty);
  });

  test(
    'a refused scanned password is named, not blamed on the server',
    () async {
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path == '/status.php') {
            return http.Response(jsonEncode(readyStatusJson()), 200);
          }
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response('', 401);
          }
          return http.Response('', 404);
        }),
      );
      final coordinator = OnboardingCoordinator(
        api: api,
        accounts: repository,
        credentials: vault,
        launcher: launcher,
        pollInterval: Duration.zero,
      );

      final payload =
          parseQrLoginPayload(
                'nc://login/user:fixture-user'
                '&server:https%3A//cloud.example.invalid'
                '&password:already-revoked-password',
              )!
              as QrLoginCredentials;

      await expectLater(
        coordinator.commitScannedLogin(payload, CancellationSignal()),
        throwsA(
          isA<OnboardingFailure>().having(
            (error) => error.code,
            'code',
            OnboardingFailureCode.scannedLoginRejected,
          ),
        ),
      );
      expect(vault.values, isEmpty);
      expect(await repository.watchAccounts().first, isEmpty);
    },
  );

  test('a scanned account without Talk is refused', () async {
    final api = _onboardingApi(withTalk: false);
    final coordinator = OnboardingCoordinator(
      api: api,
      accounts: repository,
      credentials: vault,
      launcher: launcher,
      pollInterval: Duration.zero,
    );

    final payload =
        parseQrLoginPayload(
              'nc://login/user:fixture-user'
              '&server:https%3A//cloud.example.invalid'
              '&password:fixture-app-password-never-use',
            )!
            as QrLoginCredentials;

    await expectLater(
      coordinator.commitScannedLogin(payload, CancellationSignal()),
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
  });
}

Future<void> _waitForPendingRevocations(
  AppPasswordRevocationQueue queue,
  int expected,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (await queue.pendingRevocationCount() == expected) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Pending revocation did not become durable');
}

HttpNextcloudApi _onboardingApi({
  required bool withTalk,
  VoidCallback? onPoll,
  Future<void>? pollGate,
  VoidCallback? onCapabilities,
  Future<void>? capabilitiesGate,
  VoidCallback? onRevoke,
  Object? revokeFailure,
  VoidCallback? onOneTimeExchange,
  String? oneTimeAppPassword,
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
      if (request.url.path.endsWith('/core/getapppassword-onetime')) {
        onOneTimeExchange?.call();
        if (oneTimeAppPassword == null) {
          return http.Response('', 401);
        }
        expect(request.headers['Authorization'], startsWith('Basic '));
        return http.Response(
          jsonEncode(<String, Object?>{
            'ocs': <String, Object?>{
              'meta': <String, Object?>{
                'status': 'ok',
                'statuscode': 200,
                'message': 'OK',
              },
              'data': <String, Object?>{'apppassword': oneTimeAppPassword},
            },
          }),
          200,
        );
      }
      if (request.method == 'DELETE' &&
          request.url.path.endsWith('/core/apppassword')) {
        onRevoke?.call();
        if (revokeFailure != null) {
          throw revokeFailure;
        }
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

final class _FaultingCredentialVault
    implements CredentialVault, PendingRevocationStore {
  _FaultingCredentialVault({
    Map<String, String> values = const {},
    this.readFailure,
    this.onWrite,
    this.writeGate,
    this.writeFailuresRemaining = 0,
    this.deleteFailuresRemaining = 0,
  }) : values = Map.of(values);

  final Map<String, String> values;
  final Object? readFailure;
  final VoidCallback? onWrite;
  final Future<void>? writeGate;
  int writeFailuresRemaining;
  int deleteFailuresRemaining;
  int writeCalls = 0;
  int deleteCalls = 0;
  String? pendingRevocations;
  Future<void> _pendingMutationTail = Future<void>.value();

  @override
  Future<void> deleteAppPassword(String accountId) async {
    deleteCalls++;
    if (deleteFailuresRemaining > 0) {
      deleteFailuresRemaining--;
      throw StateError('credential delete failed');
    }
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
    onWrite?.call();
    await writeGate;
    if (writeFailuresRemaining > 0) {
      writeFailuresRemaining--;
      throw StateError('credential write failed');
    }
    values[accountId] = appPassword;
  }

  @override
  Future<String?> readPendingRevocations() async => pendingRevocations;

  @override
  Future<void> updatePendingRevocations(
    String? Function(String? current) update,
  ) {
    final result = _pendingMutationTail.then((_) {
      pendingRevocations = update(pendingRevocations);
    });
    _pendingMutationTail = result.catchError((Object _) {});
    return result;
  }

  @override
  Future<void> writePendingRevocations(String? json) async {
    await updatePendingRevocations((_) => json);
  }
}

final class _FailOncePendingStore implements PendingRevocationStore {
  _FailOncePendingStore(this._inner);

  final PendingRevocationStore _inner;
  var failNextUpdate = false;

  @override
  Future<String?> readPendingRevocations() => _inner.readPendingRevocations();

  @override
  Future<void> updatePendingRevocations(
    String? Function(String? current) update,
  ) async {
    if (failNextUpdate) {
      failNextUpdate = false;
      throw const FileSystemException('pending queue write failed');
    }
    await _inner.updatePendingRevocations(update);
  }

  @override
  Future<void> writePendingRevocations(String? json) =>
      _inner.writePendingRevocations(json);
}

final class _LateGeneratedCredentialClient extends http.BaseClient {
  _LateGeneratedCredentialClient._(
    this._heldPath,
    this._responseBody, {
    this.revokeOffline = false,
  });

  factory _LateGeneratedCredentialClient.loginPoll({
    bool revokeOffline = false,
  }) => _LateGeneratedCredentialClient._(
    '/index.php/login/v2/poll',
    loginSuccessJson(),
    revokeOffline: revokeOffline,
  );

  factory _LateGeneratedCredentialClient.oneTimeExchange() =>
      _LateGeneratedCredentialClient._(
        '/ocs/v2.php/core/getapppassword-onetime',
        <String, Object?>{
          'ocs': <String, Object?>{
            'meta': <String, Object?>{
              'status': 'ok',
              'statuscode': 200,
              'message': 'OK',
            },
            'data': <String, Object?>{
              'apppassword': 'late-qr-app-password-never-use',
            },
          },
        },
      );

  final String _heldPath;
  final Object _responseBody;
  final bool revokeOffline;
  final StreamController<List<int>> _body = StreamController<List<int>>();
  final Completer<void> requestStarted = Completer<void>();
  final Completer<void> revoked = Completer<void>();
  String? revokedPassword;
  var _released = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path == '/status.php') {
      return _streamedResponse(readyStatusJson());
    }
    if (request.method == 'DELETE' &&
        request.url.path.endsWith('/core/apppassword')) {
      final authorization = request.headers['Authorization']!;
      final credential = utf8.decode(
        base64Decode(authorization.substring('Basic '.length)),
      );
      revokedPassword = credential.substring(credential.indexOf(':') + 1);
      if (!revoked.isCompleted) {
        revoked.complete();
      }
      if (revokeOffline) {
        throw const SocketException('offline');
      }
      return _streamedResponse(<String, Object?>{
        'ocs': <String, Object?>{
          'meta': <String, Object?>{
            'status': 'ok',
            'statuscode': 200,
            'message': 'OK',
          },
          'data': <String, Object?>{},
        },
      });
    }
    if (request.url.path == _heldPath) {
      expect(request, isNot(isA<http.Abortable>()));
      if (!requestStarted.isCompleted) {
        requestStarted.complete();
      }
      return http.StreamedResponse(_body.stream, 200);
    }
    if (request.url.path.endsWith('/login/v2')) {
      return _streamedResponse(loginInitializationJson());
    }
    return http.StreamedResponse(const Stream<List<int>>.empty(), 404);
  }

  void releaseResponse() {
    if (_released) return;
    _released = true;
    _body.add(utf8.encode(jsonEncode(_responseBody)));
    unawaited(_body.close());
  }

  @override
  void close() {
    if (!_released) {
      _released = true;
      unawaited(_body.close());
    }
    super.close();
  }

  http.StreamedResponse _streamedResponse(Object body) {
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
      200,
    );
  }
}

final class _BlockedLoginPageLauncher implements LoginPageLauncher {
  final Completer<void> openStarted = Completer<void>();
  final Completer<bool> releaseOpen = Completer<bool>();
  int closeCount = 0;

  @override
  Future<bool> open(Uri uri) {
    openStarted.complete();
    return releaseOpen.future;
  }

  @override
  Future<void> close() async => closeCount++;
}

final class _HeldOnboardingRequestClient extends http.BaseClient {
  _HeldOnboardingRequestClient(this.heldPhase);

  final String heldPhase;
  final Completer<void> requestStarted = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final held = heldPhase == 'status'
        ? request.url.path == '/status.php'
        : request.url.path.endsWith('/login/v2');
    if (held) {
      expect(request, isA<http.Abortable>());
      requestStarted.complete();
      await (request as http.Abortable).abortTrigger;
      throw http.RequestAbortedException(request.url);
    }
    if (request.url.path == '/status.php') {
      return _streamedResponse(readyStatusJson());
    }
    if (request.url.path.endsWith('/login/v2')) {
      return _streamedResponse(loginInitializationJson());
    }
    return http.StreamedResponse(const Stream<List<int>>.empty(), 404);
  }

  http.StreamedResponse _streamedResponse(Object body) {
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
      200,
    );
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
