import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/credential_vault.dart';
import 'package:nextcloudtalk/features/push/client_push_coordinator.dart';
import 'package:nextcloudtalk/features/push/client_push_session.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

final class _FakeSocket implements ClientPushSocket {
  final _controller = StreamController<String>.broadcast();
  bool closed = false;

  @override
  Stream<String> get frames => _controller.stream;

  @override
  void send(String frame) {}

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  void emit(String frame) {
    if (!_controller.isClosed) {
      _controller.add(frame);
    }
  }
}

final class _Connector implements ClientPushConnector {
  final sockets = <_FakeSocket>[];

  @override
  Future<ClientPushSocket> connect(Uri endpoint) async {
    final socket = _FakeSocket();
    sockets.add(socket);
    // The server accepts once the session has attached its listener; a
    // microtask would race that subscription.
    Timer(const Duration(milliseconds: 1), () => socket.emit('authenticated'));
    return socket;
  }
}

final class _BlockingSocket implements ClientPushSocket {
  final controller = StreamController<String>.broadcast();
  final closeStarted = Completer<void>();
  final releaseClose = Completer<void>();

  @override
  Stream<String> get frames => controller.stream;

  @override
  void send(String frame) {}

  @override
  Future<void> close() async {
    if (!closeStarted.isCompleted) {
      closeStarted.complete();
    }
    await releaseClose.future;
    if (!controller.isClosed) {
      await controller.close();
    }
  }

  void emit(String frame) {
    if (!controller.isClosed) {
      controller.add(frame);
    }
  }
}

final class _TwoAccountConnector implements ClientPushConnector {
  final first = _BlockingSocket();
  final second = _FakeSocket();

  @override
  Future<ClientPushSocket> connect(Uri endpoint) async {
    if (endpoint.path.endsWith('/account-a')) {
      Timer(const Duration(milliseconds: 1), () => first.emit('authenticated'));
      return first;
    }
    Timer(const Duration(milliseconds: 1), () => second.emit('authenticated'));
    return second;
  }
}

ClientPushEndpoints _endpoints({bool notifications = true}) =>
    ClientPushEndpoints(
      websocket: Uri.parse('wss://cloud.example.invalid/push/ws'),
      preAuth: Uri.parse('https://cloud.example.invalid/push/pre_auth'),
      carriesNotifications: notifications,
    );

Future<void> _settle() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  test('every pushed notification wakes the account up', () async {
    final connector = _Connector();
    final woken = <String>[];
    final coordinator = ClientPushCoordinator(
      resolve: (_, _) async => _endpoints(),
      fetchToken: (_, _, _) async => 'token',
      connector: connector,
      onWakeUp: woken.add,
    );

    coordinator.follow('account-a');
    await _settle();
    // Connecting itself wakes once: anything missed while the socket was down
    // is only caught by syncing.
    expect(woken, <String>['account-a']);

    connector.sockets.single.emit('notify_notification');
    connector.sockets.single.emit('notify_file');
    await _settle();
    expect(woken, <String>['account-a', 'account-a']);

    await coordinator.dispose();
  });

  test('a server without the live channel is left alone', () async {
    final connector = _Connector();
    final woken = <String>[];
    final coordinator = ClientPushCoordinator(
      resolve: (_, _) async => null,
      fetchToken: (_, _, _) async => 'token',
      connector: connector,
      onWakeUp: woken.add,
    );

    coordinator.follow('account-a');
    await _settle();

    expect(connector.sockets, isEmpty);
    expect(woken, isEmpty);
    await coordinator.dispose();
  });

  test('a capability timeout stays inside the retry loop', () async {
    final connector = _Connector();
    final secondRetryStarted = Completer<void>();
    final blockedRetry = Completer<void>();
    final uncaught = <Object>[];
    var resolves = 0;
    var delays = 0;
    final coordinator = ClientPushCoordinator(
      resolve: (_, _) async {
        resolves++;
        throw const NextcloudApiException(NextcloudApiError.timeout);
      },
      fetchToken: (_, _, _) async => 'token',
      connector: connector,
      onWakeUp: (_) {},
      delay: (_) async {
        delays++;
        if (delays == 2) {
          secondRetryStarted.complete();
          await blockedRetry.future;
        }
      },
    );

    runZonedGuarded(
      () => coordinator.follow('account-a'),
      (error, _) => uncaught.add(error),
    );
    await secondRetryStarted.future.timeout(const Duration(seconds: 1));

    expect(connector.sockets, isEmpty);
    expect(uncaught, isEmpty);
    expect(resolves, 2);
    await coordinator.dispose().timeout(const Duration(seconds: 1));
    await _settle();
    expect(resolves, 2);
    expect(uncaught, isEmpty);
  });

  test('dispose waits for an in-flight capability resolve', () async {
    final resolveStarted = Completer<void>();
    final resolveCancelled = Completer<void>();
    final uncaught = <Object>[];
    final coordinator = ClientPushCoordinator(
      resolve: (_, cancellation) async {
        resolveStarted.complete();
        await cancellation;
        resolveCancelled.complete();
        throw const NextcloudApiException(NextcloudApiError.cancelled);
      },
      fetchToken: (_, _, _) async => 'unused',
      connector: _Connector(),
      onWakeUp: (_) {},
    );

    await runZonedGuarded(() async {
      coordinator.follow('account-a');
      await resolveStarted.future;
      await coordinator.dispose();
    }, (error, stack) => uncaught.add(error));
    await Future<void>.delayed(Duration.zero);

    expect(resolveCancelled.isCompleted, isTrue);
    expect(uncaught, isEmpty);
  });

  test('a temporary credential lock stays inside the retry loop', () async {
    final connector = _Connector();
    final uncaught = <Object>[];
    var resolves = 0;
    final coordinator = ClientPushCoordinator(
      resolve: (_, _) async {
        resolves++;
        if (resolves == 1) {
          throw const CredentialVaultTemporarilyUnavailable();
        }
        return _endpoints();
      },
      fetchToken: (_, _, _) async => 'token',
      connector: connector,
      onWakeUp: (_) {},
      delay: (_) async {},
    );

    runZonedGuarded(
      () => coordinator.follow('account-a'),
      (error, _) => uncaught.add(error),
    );
    await _settle();

    expect(resolves, greaterThanOrEqualTo(2));
    expect(connector.sockets, hasLength(1));
    expect(uncaught, isEmpty);
    await coordinator.dispose();
  });

  test('a dropped socket is reconnected', () async {
    final connector = _Connector();
    final woken = <String>[];
    final coordinator = ClientPushCoordinator(
      resolve: (_, _) async => _endpoints(),
      fetchToken: (_, _, _) async => 'token',
      connector: connector,
      onWakeUp: woken.add,
      delay: (_) async {},
    );

    coordinator.follow('account-a');
    await _settle();
    expect(connector.sockets, hasLength(1));

    await connector.sockets.first.close();
    await _settle();

    expect(
      connector.sockets.length,
      greaterThan(1),
      reason: 'the coordinator has to come back after a drop',
    );
    await coordinator.dispose();
  });

  test('a removed account stops holding a socket', () async {
    final connector = _Connector();
    final coordinator = ClientPushCoordinator(
      resolve: (_, _) async => _endpoints(),
      fetchToken: (_, _, _) async => 'token',
      connector: connector,
      onWakeUp: (_) {},
    );

    coordinator.follow('account-a');
    await _settle();
    await coordinator.unfollow('account-a');
    await _settle();

    expect(connector.sockets.first.closed, isTrue);
    await coordinator.dispose();
  });

  test(
    'dispose signals every account before awaiting socket teardown',
    () async {
      final connector = _TwoAccountConnector();
      final woken = <String>[];
      final coordinator = ClientPushCoordinator(
        resolve: (accountId, cancellation) async => ClientPushEndpoints(
          websocket: Uri.parse('wss://cloud.example.invalid/push/$accountId'),
          preAuth: Uri.parse(
            'https://cloud.example.invalid/preauth/$accountId',
          ),
          carriesNotifications: true,
        ),
        fetchToken: (accountId, endpoints, cancellation) async => 'token',
        connector: connector,
        onWakeUp: woken.add,
      );

      coordinator.follow('account-a');
      coordinator.follow('account-b');
      await _settle();
      expect(woken, containsAll(<String>['account-a', 'account-b']));

      final disposal = coordinator.dispose();
      await connector.first.closeStarted.future;
      await Future<void>.delayed(Duration.zero);
      expect(connector.second.closed, isTrue);

      connector.first.releaseClose.complete();
      await disposal;
    },
  );
}
