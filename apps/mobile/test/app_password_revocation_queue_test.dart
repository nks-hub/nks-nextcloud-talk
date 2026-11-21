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

  test('the queue is bounded by count, attempts and age', () async {
    final q = queue(
      MockClient((request) async => throw const SocketException('offline')),
    );
    for (
      var index = 0;
      index < AppPasswordRevocationQueue.maximumEntries + 2;
      index++
    ) {
      await q.record(server: server, loginName: 'me', appPassword: 'pw$index');
    }
    expect(await q.pendingCount(), AppPasswordRevocationQueue.maximumEntries);
    expect(vault.pendingRevocations, isNot(contains('pw0')));
    expect(vault.pendingRevocations, contains('pw6'));

    for (
      var attempt = 0;
      attempt < AppPasswordRevocationQueue.maximumAttempts;
      attempt++
    ) {
      await q.drain();
    }
    expect(await q.pendingCount(), 0, reason: 'given up after the attempt cap');

    await q.record(server: server, loginName: 'me', appPassword: 'old');
    clock = clock.add(AppPasswordRevocationQueue.maximumAge);
    await q.drain();
    expect(await q.pendingCount(), 0, reason: 'given up after the age cap');
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
