import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/credential_vault.dart';
import 'package:nextcloudtalk/features/onboarding/onboarding_coordinator.dart';
import 'package:nextcloudtalk/features/settings/app_password_revocation_queue.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  test(
    'late browser cancellation frees expired capacity after restarts',
    () async {
      final database = openTestDatabase();
      addTearDown(database.close);
      var now = DateTime.utc(2026);
      var polls = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          return switch (request.url.path) {
            '/status.php' => http.Response(jsonEncode(readyStatusJson()), 200),
            '/index.php/login/v2' => http.Response(
              jsonEncode(loginInitializationJson()),
              200,
            ),
            '/index.php/login/v2/poll' => (() {
              polls++;
              return http.Response('', 404);
            })(),
            _ => throw StateError('Unexpected test request'),
          };
        }),
      );
      addTearDown(api.close);
      final accounts = AccountRepository(database);
      String? durable;
      for (var iteration = 0; iteration < 6; iteration++) {
        final vault = MemoryCredentialVault()..pendingRevocations = durable;
        final queue = AppPasswordRevocationQueue(
          store: vault,
          api: api,
          accounts: accounts,
          credentials: vault,
          now: () => now,
        );
        final browser = _BlockedBrowser();
        final coordinator = OnboardingCoordinator(
          api: api,
          accounts: accounts,
          credentials: vault,
          launcher: browser,
          pendingRevocations: queue,
        );
        final pending = await coordinator.start(
          'https://cloud.example.invalid',
        );
        final cancel = CancellationSignal();
        final complete = coordinator.completeLogin(pending, cancel);
        final assertion = expectLater(
          complete,
          throwsA(isA<OnboardingCancelled>()),
        );
        await browser.started.future.timeout(const Duration(seconds: 2));
        cancel.cancel();
        browser.finish.complete(true);
        await assertion;
        expect(browser.closes, 1);
        durable = await vault.readPendingRevocations();
        now = now.add(const Duration(minutes: 25));
      }
      expect(polls, 0);
    },
  );
  test('a definitely unlaunched browser releases its owned slot', () async {
    final f = _RecoveryFixture();
    addTearDown(f.close);
    final browser = _BlockedBrowser();
    final coordinator = f.coordinator(browser);
    final pending = await coordinator.start(_origin);
    final cancellation = CancellationSignal();
    final result = expectLater(
      coordinator.completeLogin(pending, cancellation),
      throwsA(isA<OnboardingFailure>()),
    );
    await browser.started.future;
    expect(await f.queue.unresolvedReservationCount(), 1);
    browser.finish.complete(false);
    await result;
    expect(browser.closes, 1);
    expect(await f.queue.unresolvedReservationCount(), 0);
    expect(f.polls, 0);
  });

  test(
    'poll coordinates survive a restart before the launcher answers',
    () async {
      final f = _RecoveryFixture();
      addTearDown(f.close);
      final browser = _BlockedBrowser();
      final flow = f.coordinator(browser);
      final pending = await flow.start(_origin);
      final cancellation = CancellationSignal();
      final opening = expectLater(
        flow.completeLogin(pending, cancellation),
        throwsA(isA<OnboardingFailure>()),
      );
      await browser.started.future;
      final recoveredVault = f.restartedVault();
      final recovery = f.createQueue(recoveredVault);
      f.pollReply = () async =>
          http.Response(jsonEncode(loginSuccessJson()), 200);
      expect(await f.queue.recoverBrowserLogins(canPoll: () => true), isFalse);
      expect(f.polls, 0);
      browser.finish.complete(false);
      await opening;
      expect(await recovery.recoverBrowserLogins(canPoll: () => true), isTrue);
      expect(await recovery.pendingRevocationCount(), 1);
      expect(await f.accounts.watchAccounts().first, isEmpty);
    },
  );

  test(
    'a launch failure with unknown dispatch retains only recovery state',
    () async {
      final f = _RecoveryFixture();
      addTearDown(f.close);
      final browser = _BlockedBrowser();
      final flow = f.coordinator(browser);
      final pending = await flow.start(_origin);
      final failure = StateError('launcher returned no reliable disposition');
      final opening = expectLater(
        flow.completeLogin(pending, CancellationSignal()),
        throwsA(same(failure)),
      );
      await browser.started.future;
      browser.finish.completeError(failure);
      await opening;
      expect(browser.closes, 1);
      expect(await f.queue.unresolvedReservationCount(), 1);
      expect(f.polls, 0);
      f.now = f.now.add(const Duration(minutes: 25));
      await f.queue.recoverBrowserLogins(canPoll: () => true);
      expect(await f.queue.unresolvedReservationCount(), 0);
      expect(f.polls, 0);
    },
  );

  test(
    'v1 unclaimed empty reservations are removed without deleting owned data',
    () async {
      final f = _RecoveryFixture();
      addTearDown(f.close);
      final live = await f.queue.reserve();
      final entries = jsonDecode(f.vault.pendingRevocations!) as List<Object?>;
      await f.vault.writePendingRevocations(
        jsonEncode([
          ...entries,
          {
            'kind': 'reservation',
            'id': 'abandoned-v1',
            'since': f.now.toIso8601String(),
          },
        ]),
      );
      await f.queue.record(
        server: ServerBase.parse(_origin),
        loginName: 'other',
        appPassword: 'synthetic-only',
      );
      await f.createQueue(f.vault).recoverBrowserLogins(canPoll: () => true);
      expect(await f.queue.pendingRevocationCount(), 1);
      expect(await f.queue.unresolvedReservationCount(), 1);
      await f.queue.releaseReservation(live);
      expect(await f.queue.unresolvedReservationCount(), 0);
      expect(f.polls, 0);
    },
  );

  test(
    'late launch is recoverable after restart, and retires a newly received password',
    () async {
      final f = _RecoveryFixture();
      addTearDown(f.close);
      await f.cancelLateLaunch();
      expect(f.polls, 0);
      expect(f.vault.pendingRevocations, isNot(contains('/login/v2/flow/')));
      final queue = f.createQueue(f.restartedVault());
      expect(await queue.recoverBrowserLogins(canPoll: () => false), isFalse);
      expect(await queue.recoverBrowserLogins(canPoll: () => true), isFalse);
      expect(await queue.unresolvedReservationCount(), 1);
      f.pollReply = () async =>
          http.Response(jsonEncode(loginSuccessJson()), 200);
      expect(await queue.recoverBrowserLogins(canPoll: () => true), isTrue);
      expect(await queue.pendingRevocationCount(), 1);
      expect(await queue.unresolvedReservationCount(), 0);
      expect(await f.accounts.watchAccounts().first, isEmpty);
      await queue.drain();
      expect(f.revokes, 1);
      expect(await queue.pendingCount(), 0);
    },
  );

  test(
    'recovering a late result never revokes the password owned by an existing account',
    () async {
      final f = _RecoveryFixture();
      addTearDown(f.close);
      final reply = loginSuccessJson();
      await f.accounts.upsertAccount(
        accountId: 'known-account',
        serverUrl: _origin,
        loginName: reply['loginName']! as String,
        serverProductName: 'Nextcloud',
        talkFeatures: const {},
        createdAt: f.now,
      );
      await f.vault.writeAppPassword(
        'known-account',
        reply['appPassword']! as String,
      );
      await f.cancelLateLaunch();
      final vault = f.restartedVault();
      final queue = f.createQueue(vault);
      f.pollReply = () async => http.Response(jsonEncode(reply), 200);
      expect(await queue.recoverBrowserLogins(canPoll: () => true), isTrue);
      await queue.drain();
      expect(f.revokes, 0);
      expect(
        await vault.readAppPassword('known-account'),
        reply['appPassword'],
      );
      expect(await queue.pendingCount(), 0);
    },
  );

  test('a live one-time poll retains its claim even past expiry', () async {
    final f = _RecoveryFixture();
    addTearDown(f.close);
    final pollStarted = Completer<void>();
    final heldPoll = Completer<http.Response>();
    f.pollReply = () {
      pollStarted.complete();
      return heldPoll.future;
    };
    final browser = RecordingLoginPageLauncher();
    final coordinator = f.coordinator(browser);
    final pending = await coordinator.start(_origin);
    final cancellation = CancellationSignal();
    final result = expectLater(
      coordinator.completeLogin(pending, cancellation),
      throwsA(isA<OnboardingCancelled>()),
    );
    await pollStarted.future;
    cancellation.cancel();
    await result;
    expect(browser.closeCount, 1);
    f.now = f.now.add(const Duration(minutes: 25));
    final recovery = f.createQueue(f.vault);
    expect(await recovery.recoverBrowserLogins(canPoll: () => true), isFalse);
    expect(await recovery.unresolvedReservationCount(), 1);
    expect(f.polls, 1);
    heldPoll.complete(http.Response(jsonEncode(loginSuccessJson()), 200));
    for (var attempt = 0; attempt < 20; attempt++) {
      if (await recovery.pendingRevocationCount() == 1) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(await recovery.pendingRevocationCount(), 1);
    expect(await recovery.unresolvedReservationCount(), 0);
    expect(await f.accounts.watchAccounts().first, isEmpty);
  });

  test(
    'browser UI deadline precedes retirement of a delayed one-shot response',
    () async {
      final f = _RecoveryFixture(
        requestTimeout: const Duration(milliseconds: 120),
      );
      addTearDown(f.close);
      final started = Completer<void>();
      final response = Completer<http.Response>();
      f.pollReply = () {
        started.complete();
        return response.future;
      };
      final coordinator = f.coordinator(
        RecordingLoginPageLauncher(),
        loginTimeout: const Duration(milliseconds: 150),
      );
      final pending = await coordinator.start(_origin);
      final run = expectLater(
        coordinator.completeLogin(pending, CancellationSignal()),
        throwsA(
          isA<OnboardingFailure>().having(
            (e) => e.code,
            'code',
            OnboardingFailureCode.loginTimedOut,
          ),
        ),
      );
      await started.future;
      await run;
      expect(await f.queue.unresolvedReservationCount(), 1);
      response.complete(http.Response(jsonEncode(loginSuccessJson()), 200));
      await _waitForRetirement(f.queue);
      expect(await f.accounts.watchAccounts().first, isEmpty);
      expect(f.polls, 1);
    },
  );

  for (final cancel in [true, false]) {
    test('browser ${cancel ? 'cancel' : 'deadline'} returns while the known '
        'credential is still being stored', () async {
      final f = _RecoveryFixture(blockFirstHold: true);
      final writer = f.store!;
      addTearDown(f.close);
      addTearDown(writer.unblock);
      f.pollReply = () async =>
          http.Response(jsonEncode(loginSuccessJson()), 200);
      final browser = RecordingLoginPageLauncher();
      final coordinator = f.coordinator(
        browser,
        loginTimeout: cancel
            ? const Duration(minutes: 15)
            : const Duration(milliseconds: 350),
      );
      final pending = await coordinator.start(_origin);
      final cancellation = CancellationSignal();
      final result = coordinator.completeLogin(pending, cancellation);
      final outcome = result.then<Object>(
        (value) => value,
        onError: (Object e) => e,
      );
      await writer.started.future.timeout(const Duration(seconds: 2));
      if (cancel) cancellation.cancel();

      final early = await outcome.timeout(
        const Duration(seconds: 2),
        onTimeout: () => TimeoutException('Foreground is waiting on the vault'),
      );
      expect(
        early,
        cancel
            ? isA<OnboardingCancelled>()
            : isA<OnboardingFailure>().having(
                (e) => e.code,
                'code',
                OnboardingFailureCode.loginTimedOut,
              ),
      );
      expect(browser.closeCount, 1);
      expect(await f.queue.unresolvedReservationCount(), 1);
      expect(await f.queue.recoverBrowserLogins(canPoll: () => true), isFalse);
      expect(f.polls, 1);
      expect(await f.accounts.watchAccounts().first, isEmpty);

      writer.unblock();
      await _waitForRetirement(f.queue);
      expect(writer.writes, 1);
      expect(await f.queue.unresolvedReservationCount(), 0);
      await f.queue.drain();
      expect(f.revokes, 1);
      expect(await f.queue.pendingRevocationCount(), 0);
      expect(await f.accounts.watchAccounts().first, isEmpty);
    });
  }

  test(
    'browser retirement preserves a later shared QR owner after restart',
    () async {
      final f = _RecoveryFixture();
      addTearDown(f.close);
      await f.queueLateBrowserCredential();
      final coordinator = f.coordinator(RecordingLoginPageLauncher());
      final started = Completer<void>();
      final capabilityGate = Completer<void>();
      addTearDown(() {
        if (!capabilityGate.isCompleted) capabilityGate.complete();
      });
      f.onCapabilities = () async {
        started.complete();
        await capabilityGate.future;
      };
      final admission = coordinator.commitScannedLogin(
        _sharedBrowserCredential,
        CancellationSignal(),
      );
      await started.future.timeout(const Duration(seconds: 2));
      await f.queue.drain();
      expect(f.revokes, 0);
      expect(await f.queue.pendingRevocationCount(), 1);

      capabilityGate.complete();
      final account = await admission;
      final restarted = f.createQueue(f.restartedVault());
      await restarted.drain();
      expect(f.revokes, 0);
      expect(await restarted.pendingCount(), 0);
      expect(await f.accounts.getAccount(account.id), isNotNull);
      expect(
        await f.vault.readAppPassword(account.id),
        loginSuccessJson()['appPassword'],
      );
    },
  );

  test(
    'browser DELETE and ambiguous outcome prevent adopting its credential',
    () async {
      final f = _RecoveryFixture();
      addTearDown(f.close);
      await f.queueLateBrowserCredential();
      final started = Completer<void>();
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      f.onRevoke = () async {
        started.complete();
        await gate.future;
        throw http.ClientException('synthetic ambiguous timeout');
      };
      final drain = f.queue.drain();
      await started.future.timeout(const Duration(seconds: 2));
      await expectLater(
        f
            .coordinator(RecordingLoginPageLauncher())
            .commitScannedLogin(_sharedBrowserCredential, CancellationSignal())
            .timeout(const Duration(seconds: 2)),
        throwsA(isA<OnboardingFailure>()),
      );
      gate.complete();
      await drain;
      final restarted = f.restartedVault();
      final secondCoordinator = f.coordinator(
        RecordingLoginPageLauncher(),
        useVault: restarted,
      );
      await expectLater(
        secondCoordinator.commitScannedLogin(
          _sharedBrowserCredential,
          CancellationSignal(),
        ),
        throwsA(isA<OnboardingFailure>()),
      );
      expect(await f.accounts.watchAccounts().first, isEmpty);
      expect(await f.createQueue(restarted).pendingRevocationCount(), 1);
      expect(f.revokes, 1);
    },
  );

  test('explicit removal still sends its intentional revocation', () async {
    final f = _RecoveryFixture();
    addTearDown(f.close);
    final account = await f
        .coordinator(RecordingLoginPageLauncher())
        .commitScannedLogin(_sharedBrowserCredential, CancellationSignal());
    final reservation = await f.queue.reserveCredentialForRemoval(
      server: ServerBase.parse(account.serverUrl),
      loginName: account.loginName,
      appPassword: loginSuccessJson()['appPassword']! as String,
      accountId: account.id,
    );
    await f.queue.queueCredential(
      reservation: reservation,
      server: ServerBase.parse(account.serverUrl),
      loginName: account.loginName,
      appPassword: loginSuccessJson()['appPassword']! as String,
    );
    await f.queue.drain();
    expect(f.revokes, 1);
    expect(await f.queue.pendingCount(), 0);
  });

  test(
    'cancelled nonresponsive transport relinquishes claim at its hard bound',
    () async {
      final f = _RecoveryFixture(
        requestTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(f.close);
      final started = Completer<void>();
      final abort = Completer<void>();
      f.onPoll = (request) {
        final transport = request as http.AbortableRequest;
        unawaited(transport.abortTrigger!.then((_) => abort.complete()));
      };
      f.pollReply = () {
        started.complete();
        return Completer<http.Response>().future;
      };
      final coordinator = f.coordinator(RecordingLoginPageLauncher());
      final pending = await coordinator.start(_origin);
      final cancellation = CancellationSignal();
      final run = expectLater(
        coordinator.completeLogin(pending, cancellation),
        throwsA(isA<OnboardingCancelled>()),
      );
      await started.future;
      cancellation.cancel();
      await run;
      f.now = f.now.add(const Duration(minutes: 25));
      await f.queue.recoverBrowserLogins(canPoll: () => true);
      expect(await f.queue.unresolvedReservationCount(), 1);
      await abort.future.timeout(const Duration(seconds: 2));
      for (var attempt = 0; attempt < 20; attempt++) {
        await f.queue.recoverBrowserLogins(canPoll: () => true);
        if (await f.queue.unresolvedReservationCount() == 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await f.queue.unresolvedReservationCount(), 0);
      expect(f.polls, 1);
      expect(f.revokes, 0);
    },
  );

  test('recovery rechecks exact origin and poll route', () async {
    final f = _RecoveryFixture();
    addTearDown(f.close);
    await f.cancelLateLaunch();
    for (final tampered in [
      'https://other.example.invalid/index.php/login/v2/poll',
      'https://cloud.example.invalid/elsewhere/login/v2/poll',
    ]) {
      final vault = f.restartedVault();
      final oldEndpoint = '$_origin/index.php/login/v2/poll';
      vault.pendingRevocations = vault.pendingRevocations!.replaceFirst(
        oldEndpoint,
        tampered,
      );
      final queue = f.createQueue(vault);
      expect(await queue.recoverBrowserLogins(canPoll: () => true), isFalse);
      expect(await queue.unresolvedReservationCount(), 1);
    }
    expect(f.polls, 0);
  });
}

Future<void> _waitForRetirement(AppPasswordRevocationQueue queue) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (await queue.pendingRevocationCount() == 1) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(await queue.pendingRevocationCount(), 1);
}

QrLoginCredentials get _sharedBrowserCredential =>
    parseQrLoginPayload(
          'nc://login/user:${loginSuccessJson()['loginName']}'
          '&server:https%3A//CLOUD.example.invalid:443/'
          '&password:${loginSuccessJson()['appPassword']}',
        )!
        as QrLoginCredentials;

const _origin = 'https://cloud.example.invalid';

final class _RecoveryFixture {
  _RecoveryFixture({
    Duration requestTimeout = const Duration(seconds: 20),
    bool blockFirstHold = false,
  }) {
    store = blockFirstHold ? _BlockedHeldWrite(vault) : null;
    api = HttpNextcloudApi(
      requestTimeout: requestTimeout,
      client: MockClient.streaming((request, body) async {
        await body.drain<void>();
        final response = await _respond(request);
        return http.StreamedResponse(
          Stream.value(response.bodyBytes),
          response.statusCode,
        );
      }),
    );
    queue = createQueue(vault);
  }

  Future<http.Response> _respond(http.BaseRequest request) async {
    expect(request.url.host, 'cloud.example.invalid');
    switch (request.url.path) {
      case '/status.php':
        return http.Response(jsonEncode(readyStatusJson()), 200);
      case '/index.php/login/v2':
        return http.Response(jsonEncode(loginInitializationJson()), 200);
      case '/index.php/login/v2/poll':
        expect(request.method, 'POST');
        expect(request.followRedirects, isFalse);
        polls++;
        onPoll?.call(request);
        return pollReply();
      case '/ocs/v2.php/cloud/capabilities':
        await onCapabilities?.call();
        return http.Response(jsonEncode(capabilitiesJson(withTalk: true)), 200);
      case '/ocs/v2.php/core/apppassword':
        expect(request.method, 'DELETE');
        revokes++;
        await onRevoke?.call();
        return http.Response(
          jsonEncode({
            'ocs': {
              'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
              'data': {},
            },
          }),
          200,
        );
      default:
        throw StateError('Unexpected test request');
    }
  }

  final database = openTestDatabase();
  late final accounts = AccountRepository(database);
  final vault = MemoryCredentialVault();
  late final _BlockedHeldWrite? store;
  late final HttpNextcloudApi api;
  late final AppPasswordRevocationQueue queue;
  DateTime now = DateTime.utc(2026);
  int polls = 0;
  int revokes = 0;
  void Function(http.BaseRequest)? onPoll;
  Future<void> Function()? onRevoke;
  Future<void> Function()? onCapabilities;
  Future<http.Response> Function() pollReply = () async =>
      http.Response('', 404);

  AppPasswordRevocationQueue createQueue(MemoryCredentialVault store) =>
      AppPasswordRevocationQueue(
        store: identical(store, vault) ? this.store ?? store : store,
        api: api,
        accounts: accounts,
        credentials: store,
        now: () => now,
      );
  MemoryCredentialVault restartedVault() => MemoryCredentialVault()
    ..pendingRevocations = vault.pendingRevocations
    ..values.addAll(vault.values);
  OnboardingCoordinator coordinator(
    LoginPageLauncher browser, {
    Duration loginTimeout = const Duration(minutes: 15),
    MemoryCredentialVault? useVault,
  }) => OnboardingCoordinator(
    loginTimeout: loginTimeout,
    api: api,
    accounts: accounts,
    credentials: useVault ?? vault,
    launcher: browser,
    pendingRevocations: useVault == null ? queue : createQueue(useVault),
  );
  Future<void> queueLateBrowserCredential() async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    pollReply = () {
      started.complete();
      return response.future;
    };
    final flow = coordinator(RecordingLoginPageLauncher());
    final pending = await flow.start(_origin);
    final cancel = CancellationSignal();
    final outcome = expectLater(
      flow.completeLogin(pending, cancel),
      throwsA(isA<OnboardingCancelled>()),
    );
    await started.future;
    cancel.cancel();
    await outcome;
    response.complete(http.Response(jsonEncode(loginSuccessJson()), 200));
    await _waitForRetirement(queue);
  }

  Future<void> cancelLateLaunch() async {
    final browser = _BlockedBrowser();
    final flow = coordinator(browser);
    final pending = await flow.start(_origin);
    final cancellation = CancellationSignal();
    final result = expectLater(
      flow.completeLogin(pending, cancellation),
      throwsA(isA<OnboardingCancelled>()),
    );
    await browser.started.future;
    cancellation.cancel();
    browser.finish.complete(true);
    await result;
    expect(browser.closes, 1);
  }

  Future<void> close() async {
    api.close();
    await database.close();
  }
}

final class _BlockedBrowser implements LoginPageLauncher {
  final started = Completer<void>();
  final finish = Completer<bool>();
  int closes = 0;

  @override
  Future<bool> open(Uri uri) {
    started.complete();
    return finish.future;
  }

  @override
  Future<void> close() async => closes++;
}

final class _BlockedHeldWrite implements PendingRevocationStore {
  _BlockedHeldWrite(this.delegate);

  final PendingRevocationStore delegate;
  final started = Completer<void>();
  final gate = Completer<void>();
  int writes = 0;

  void unblock() {
    if (!gate.isCompleted) gate.complete();
  }

  @override
  Future<String?> readPendingRevocations() => delegate.readPendingRevocations();

  @override
  Future<void> writePendingRevocations(String? value) =>
      delegate.writePendingRevocations(value);

  @override
  Future<void> updatePendingRevocations(
    String? Function(String? current) update,
  ) async {
    final oldValue = await delegate.readPendingRevocations();
    final next = update(oldValue);
    if (oldValue != null &&
        oldValue.contains('"kind":"reservation"') &&
        (next?.contains('"kind":"held"') ?? false)) {
      writes++;
      if (!started.isCompleted) started.complete();
      await gate.future;
    }
    await delegate.updatePendingRevocations(update);
  }
}
