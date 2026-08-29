import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/push/client_push_coordinator.dart';
import 'package:nextcloudtalk/features/push/client_push_session.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

final class _NeverConnects implements ClientPushConnector {
  const _NeverConnects();

  @override
  Future<ClientPushSocket> connect(Uri endpoint) async =>
      throw StateError('the run loop never gets this far');
}

void main() {
  test('a failing resolve never reaches the zone handler', () async {
    // NKS-TALK-8 arrived from a shipped build as an unhandled fatal with this
    // exact chain: the coordinator's run loop, the provider closure that reads
    // capabilities, and a transport timeout underneath. The loop catches
    // everything, so this pins down whether the catch really holds.
    final unhandled = <Object>[];
    var resolves = 0;
    await runZonedGuarded(() async {
      final coordinator = ClientPushCoordinator(
        resolve: (accountId) async {
          resolves++;
          throw const NextcloudApiException(NextcloudApiError.timeout);
        },
        fetchToken: (accountId, endpoints) async => 'unused',
        connector: const _NeverConnects(),
        onWakeUp: (_) {},
        firstRetry: const Duration(milliseconds: 5),
        maximumRetry: const Duration(milliseconds: 5),
      );
      coordinator.follow('account-a');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await coordinator.dispose();
    }, (error, stack) => unhandled.add(error));
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(resolves, greaterThan(1), reason: 'the loop retried');
    expect(unhandled, isEmpty);
  });
}
