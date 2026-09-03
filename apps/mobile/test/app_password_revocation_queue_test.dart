import 'dart:convert';
import 'dart:io';

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
