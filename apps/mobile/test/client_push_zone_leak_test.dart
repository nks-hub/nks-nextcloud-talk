import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/push/client_push_coordinator.dart';
import 'package:nextcloudtalk/features/push/client_push_session.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

final class _NeverConnects implements ClientPushConnector {
  const _NeverConnects();

  @override
  Future<ClientPushSocket> connect(Uri endpoint) async =>
      throw StateError('the run loop never gets this far');
}

/// Accepts the handshake, stays open, and refuses to close.
final class _UncloseableSocket implements ClientPushSocket {
  _UncloseableSocket();

  final _controller = StreamController<String>();
  var closeAttempted = false;

  @override
  Stream<String> get frames => _controller.stream;

  @override
  void send(String frame) {
    if (!_controller.isClosed) {
      _controller.add('authenticated');
    }
  }

  @override
  Future<void> close() async {
    closeAttempted = true;
    throw StateError('socket already gone');
  }
}

final class _UncloseableConnector implements ClientPushConnector {
  _UncloseableConnector();

  final sockets = <_UncloseableSocket>[];

  @override
  Future<ClientPushSocket> connect(Uri endpoint) async {
    final socket = _UncloseableSocket();
    sockets.add(socket);
    return socket;
  }
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

  test('disposing an open channel finishes and stays out of the zone', () async {
    // The last suspect left from NKS-TALK-8: every teardown call site runs
    // behind `unawaited`, so a dispose that failed would reach the zone. This
    // used to hang instead of finishing, which is its own way of being wrong.
    final unhandled = <Object>[];
    final connector = _UncloseableConnector();
    await runZonedGuarded(() async {
      final coordinator = ClientPushCoordinator(
        resolve: (accountId) async => ClientPushEndpoints(
          websocket: Uri.parse('wss://cloud.example.invalid/notify'),
          preAuth: Uri.parse('https://cloud.example.invalid/preauth'),
          carriesNotifications: true,
        ),
        fetchToken: (accountId, endpoints) async => 'token',
        connector: connector,
        onWakeUp: (_) {},
        firstRetry: const Duration(milliseconds: 5),
        maximumRetry: const Duration(milliseconds: 5),
      );
      coordinator.follow('account-a');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await coordinator.dispose().timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('teardown must finish, not hang'),
      );
    }, (error, stack) => unhandled.add(error));
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(
      connector.sockets.single.closeAttempted,
      isTrue,
      reason: 'the teardown really had an open socket to close',
    );
    expect(unhandled, isEmpty);
  });
}
