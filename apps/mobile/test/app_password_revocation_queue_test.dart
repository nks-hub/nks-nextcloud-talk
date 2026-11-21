import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/features/settings/app_password_revocation_queue.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

String _okOcs() => jsonEncode({
  'ocs': {
    'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
    'data': <Object?>[],
  },
});

void main() {
  final server = ServerBase.parse('https://cloud.example.invalid');
  late MemoryCredentialVault vault;
  late DateTime clock;

  setUp(() {
    vault = MemoryCredentialVault();
    clock = DateTime.utc(2026, 9, 3, 12);
  });

  AppPasswordRevocationQueue queue(http.Client client) =>
      AppPasswordRevocationQueue(
        store: vault,
        api: HttpNextcloudApi(client: client),
        now: () => clock,
      );

  test('an unreachable server keeps the revocation until it answers', () async {
    var reachable = false;
    final requests = <String>[];
    final q = queue(
      MockClient((request) async {
        requests.add('${request.method} ${request.url.path}');
        if (!reachable) {
          throw const SocketException('offline');
        }
        return http.Response(_okOcs(), 200);
      }),
    );
    await q.record(server: server, loginName: 'me', appPassword: 'secret');
    expect(await q.pendingCount(), 1);
    // The secret lives only in the vault, never anywhere it could be logged.
    expect(vault.pendingRevocations, contains('secret'));

    await q.drain();
    expect(await q.pendingCount(), 1, reason: 'still offline');

    reachable = true;
    await q.drain();
    expect(await q.pendingCount(), 0);
    expect(vault.pendingRevocations, isNull);
    expect(requests.last, 'DELETE /ocs/v2.php/core/apppassword');
  });

  test(
    'a password the server no longer knows is finished, not retried',
    () async {
      final q = queue(MockClient((request) async => http.Response('{}', 401)));
      await q.record(server: server, loginName: 'me', appPassword: 'gone');
      await q.drain();
      expect(await q.pendingCount(), 0);
    },
  );

  test('a drain revokes at most three passwords concurrently', () async {
    const entryCount = AppPasswordRevocationQueue.maximumEntries;
    final gates = <Completer<void>>[];
    final firstRequestStarted = Completer<void>();
    var inFlight = 0;
    var peakInFlight = 0;
    final q = queue(
      MockClient((request) async {
        final gate = Completer<void>();
        gates.add(gate);
        if (!firstRequestStarted.isCompleted) {
          firstRequestStarted.complete();
        }
        inFlight++;
        peakInFlight = max(peakInFlight, inFlight);
        await gate.future;
        inFlight--;
        return http.Response(_okOcs(), 200);
      }),
    );
    for (var index = 0; index < entryCount; index++) {
      await q.record(
        server: server,
        loginName: 'user-$index',
        appPassword: 'secret-$index',
      );
    }
    final drain = q.drain();

    Future<void> releaseAll() async {
      while (gates.length < entryCount) {
        for (final gate in gates) {
          if (!gate.isCompleted) {
            gate.complete();
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      for (final gate in gates) {
        if (!gate.isCompleted) {
          gate.complete();
        }
      }
      await drain;
    }

    addTearDown(releaseAll);
    await firstRequestStarted.future;
    for (var turn = 0; turn < 20 && gates.length < 3; turn++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(gates, hasLength(3));
    expect(peakInFlight, 3);

    gates.first.complete();
    for (var turn = 0; turn < 20 && gates.length < 4; turn++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(gates, hasLength(4));
    expect(peakInFlight, 3);

    await releaseAll();
    expect(gates, hasLength(entryCount));
    expect(await q.pendingCount(), 0);
  });

  test('another queue instance can record safely during a drain', () async {
    final requestStarted = Completer<void>();
    final releaseRequest = Completer<void>();
    final drainingQueue = queue(
      MockClient((request) async {
        if (!requestStarted.isCompleted) {
          requestStarted.complete();
        }
        await releaseRequest.future;
        return http.Response(_okOcs(), 200);
      }),
    );
    final recordingQueue = queue(
      MockClient((request) async => throw StateError('unexpected request')),
    );
    await drainingQueue.record(
      server: server,
      loginName: 'first-user',
      appPassword: 'first-secret',
    );
    final draining = drainingQueue.drain();
    Future<void>? recording;
    addTearDown(() async {
      if (!releaseRequest.isCompleted) {
        releaseRequest.complete();
      }
      await Future.wait(<Future<void>>[draining, ?recording]);
    });
    await requestStarted.future;

    recording = recordingQueue.record(
      server: server,
      loginName: 'second-user',
      appPassword: 'second-secret',
    );
    await recording;
    releaseRequest.complete();
    await draining;

    expect(await drainingQueue.pendingCount(), 1);
    expect(vault.pendingRevocations, contains('second-secret'));
    expect(vault.pendingRevocations, isNot(contains('first-secret')));
  });

  test('a full queue keeps every unverified revocation', () async {
    var reachable = false;
    final q = queue(
      MockClient((request) async {
        if (!reachable) {
          throw const SocketException('offline');
        }
        return http.Response(_okOcs(), 200);
      }),
    );
    for (
      var index = 0;
      index < AppPasswordRevocationQueue.maximumEntries;
      index++
    ) {
      await q.record(server: server, loginName: 'me', appPassword: 'pw$index');
    }
    await expectLater(
      q.record(server: server, loginName: 'me', appPassword: 'pw5'),
      throwsA(isA<AppPasswordRevocationQueueFull>()),
    );
    await expectLater(
      q.ensureCapacity(),
      throwsA(isA<AppPasswordRevocationQueueFull>()),
    );
    expect(await q.pendingCount(), AppPasswordRevocationQueue.maximumEntries);
    for (
      var index = 0;
      index < AppPasswordRevocationQueue.maximumEntries;
      index++
    ) {
      expect(vault.pendingRevocations, contains('pw$index'));
    }
    expect(vault.pendingRevocations, isNot(contains('pw5')));

    for (var attempt = 0; attempt < 25; attempt++) {
      await q.drain();
    }
    expect(
      await q.pendingCount(),
      AppPasswordRevocationQueue.maximumEntries,
      reason: 'failed revocations are not discarded after repeated attempts',
    );
    expect(vault.pendingRevocations, contains('"attempts":25'));

    clock = clock.add(const Duration(days: 30));
    await q.drain();
    expect(
      await q.pendingCount(),
      AppPasswordRevocationQueue.maximumEntries,
      reason: 'age does not prove that a server password was revoked',
    );

    reachable = true;
    await q.drain();
    expect(await q.pendingCount(), 0);
    await q.ensureCapacity();
    await q.record(server: server, loginName: 'me', appPassword: 'pw5');
    expect(await q.pendingCount(), 1);
  });

  test(
    'a corrupt store is treated as empty instead of crashing the drain',
    () async {
      vault.pendingRevocations = 'not json';
      final q = queue(
        MockClient((request) async => http.Response(_okOcs(), 200)),
      );
      await q.drain();
      expect(await q.pendingCount(), 0);
    },
  );
}
