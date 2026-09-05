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

final class _StalledConnector implements ClientPushConnector {
  final entered = Completer<void>();
  final connection = Completer<ClientPushSocket>();

  @override
  Future<ClientPushSocket> connect(Uri endpoint) {
    entered.complete();
    return connection.future;
  }
}

final class _CloseableSocket implements ClientPushSocket {
  _CloseableSocket({required this.authenticate});

  final bool authenticate;
  final controller = StreamController<String>.broadcast();
  final handshakeSent = Completer<void>();
  bool closed = false;

  @override
  Stream<String> get frames => controller.stream;

  @override
  void send(String frame) {
    if (!handshakeSent.isCompleted) {
      handshakeSent.complete();
    }
    if (authenticate && !controller.isClosed) {
      controller.add('authenticated');
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!controller.isClosed) {
      await controller.close();
    }
  }
}

final class _ImmediateConnector implements ClientPushConnector {
  _ImmediateConnector(this.socket);

  final _CloseableSocket socket;

  @override
  Future<ClientPushSocket> connect(Uri endpoint) async => socket;
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
        resolve: (accountId, cancellation) async {
          resolves++;
          throw const NextcloudApiException(NextcloudApiError.timeout);
        },
        fetchToken: (accountId, endpoints, cancellation) async => 'unused',
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

  test(
    'disposing an open channel finishes and stays out of the zone',
    () async {
      // The last suspect left from NKS-TALK-8: every teardown call site runs
      // behind `unawaited`, so a dispose that failed would reach the zone. This
      // used to hang instead of finishing, which is its own way of being wrong.
      final unhandled = <Object>[];
      final connector = _UncloseableConnector();
      await runZonedGuarded(() async {
        final coordinator = ClientPushCoordinator(
          resolve: (accountId, cancellation) async => ClientPushEndpoints(
            websocket: Uri.parse('wss://cloud.example.invalid/notify'),
            preAuth: Uri.parse('https://cloud.example.invalid/preauth'),
            carriesNotifications: true,
          ),
          fetchToken: (accountId, endpoints, cancellation) async => 'token',
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
    },
  );

  test('a failure outside the retry loop stays out of the zone', () async {
    // The suspects above are all inside the loop's own catch. The wait between
    // attempts is NOT: it sits after the catch, and nothing awaits the run
    // loop's future until `stop()`, which a running app may never call. So an
    // error there had no listener at all and reached the platform handler as a
    // fatal crash — the shape NKS-TALK-8 was reported in, and the one hole the
    // earlier tests could not have caught. The injected wait stands in for it
    // because it is the only step out there that a test can make fail.
    final unhandled = <Object>[];
    var waits = 0;
    await runZonedGuarded(() async {
      final coordinator = ClientPushCoordinator(
        resolve: (accountId, cancellation) async {
          throw const NextcloudApiException(NextcloudApiError.timeout);
        },
        fetchToken: (accountId, endpoints, cancellation) async => 'unused',
        connector: const _NeverConnects(),
        onWakeUp: (_) {},
        firstRetry: const Duration(milliseconds: 5),
        maximumRetry: const Duration(milliseconds: 5),
        delay: (_) async {
          waits++;
          throw StateError('the wait itself failed');
        },
      );
      coordinator.follow('account-a');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await coordinator.dispose().timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('teardown must finish, not hang'),
      );
    }, (error, stack) => unhandled.add(error));
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(waits, greaterThan(0), reason: 'the loop really reached the wait');
    expect(unhandled, isEmpty);
  });

  test('disposing cancels a stalled socket connection', () async {
    final unhandled = <Object>[];
    final connector = _StalledConnector();
    await runZonedGuarded(() async {
      final coordinator = ClientPushCoordinator(
        resolve: (accountId, cancellation) async => ClientPushEndpoints(
          websocket: Uri.parse('wss://cloud.example.invalid/notify'),
          preAuth: Uri.parse('https://cloud.example.invalid/preauth'),
          carriesNotifications: true,
        ),
        fetchToken: (accountId, endpoints, cancellation) async => 'token',
        connector: connector,
        onWakeUp: (_) {},
      );

      coordinator.follow('account-a');
      await connector.entered.future;
      await coordinator.dispose().timeout(const Duration(seconds: 1));
    }, (error, stack) => unhandled.add(error));
    final lateSocket = _CloseableSocket(authenticate: false);
    connector.connection.complete(lateSocket);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(lateSocket.closed, isTrue);
    expect(unhandled, isEmpty);
  });

  test('disposing cancels a connected socket during handshake', () async {
    final unhandled = <Object>[];
    final socket = _CloseableSocket(authenticate: false);
    final connector = _ImmediateConnector(socket);
    await runZonedGuarded(() async {
      final coordinator = ClientPushCoordinator(
        resolve: (accountId, cancellation) async => ClientPushEndpoints(
          websocket: Uri.parse('wss://cloud.example.invalid/notify'),
          preAuth: Uri.parse('https://cloud.example.invalid/preauth'),
          carriesNotifications: true,
        ),
        fetchToken: (accountId, endpoints, cancellation) async => 'token',
        connector: connector,
        onWakeUp: (_) {},
      );

      coordinator.follow('account-a');
      await socket.handshakeSent.future;
      await coordinator.dispose().timeout(const Duration(seconds: 1));
    }, (error, stack) => unhandled.add(error));
    await Future<void>.delayed(Duration.zero);

    expect(socket.closed, isTrue);
    expect(unhandled, isEmpty);
  });
}
