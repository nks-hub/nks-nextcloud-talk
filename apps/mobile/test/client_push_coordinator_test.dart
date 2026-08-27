import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/push/client_push_coordinator.dart';
import 'package:nextcloudtalk/features/push/client_push_session.dart';
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
      resolve: (_) async => _endpoints(),
      fetchToken: (_, _) async => 'token',
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
      resolve: (_) async => null,
      fetchToken: (_, _) async => 'token',
      connector: connector,
      onWakeUp: woken.add,
    );

    coordinator.follow('account-a');
    await _settle();

    expect(connector.sockets, isEmpty);
    expect(woken, isEmpty);
    await coordinator.dispose();
  });

  test('a dropped socket is reconnected', () async {
    final connector = _Connector();
    final woken = <String>[];
    final coordinator = ClientPushCoordinator(
      resolve: (_) async => _endpoints(),
      fetchToken: (_, _) async => 'token',
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
      resolve: (_) async => _endpoints(),
      fetchToken: (_, _) async => 'token',
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
}
