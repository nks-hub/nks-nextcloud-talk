import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/push/client_push_session.dart';
import 'package:talk_protocol/talk_protocol.dart';

final class _FakeSocket implements ClientPushSocket {
  final _controller = StreamController<String>.broadcast();
  final sent = <String>[];
  bool closed = false;

  @override
  Stream<String> get frames => _controller.stream;

  @override
  void send(String frame) => sent.add(frame);

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  void emit(String frame) => _controller.add(frame);
}

final class _FakeConnector implements ClientPushConnector {
  _FakeConnector(this.socket);

  final _FakeSocket socket;
  Uri? requested;

  @override
  Future<ClientPushSocket> connect(Uri endpoint) async {
    requested = endpoint;
    return socket;
  }
}

ClientPushEndpoints _endpoints({bool notifications = true}) =>
    ClientPushEndpoints(
      websocket: Uri.parse('wss://cloud.example.invalid/push/ws'),
      preAuth: Uri.parse('https://cloud.example.invalid/push/pre_auth'),
      carriesNotifications: notifications,
    );

void main() {
  test('sends an empty username and the token, then reports events', () async {
    final socket = _FakeSocket();
    final connector = _FakeConnector(socket);
    final opening = ClientPushSession.open(
      connector: connector,
      endpoints: _endpoints(),
      preAuthToken: 'token-abc',
    );
    await Future<void>.delayed(Duration.zero);
    socket.emit('authenticated');
    final session = await opening;

    expect(socket.sent, <String>['', 'token-abc']);
    expect(connector.requested.toString(), contains('/push/ws'));

    final received = <ClientPushEvent>[];
    final subscription = session.events.listen(received.add);
    socket.emit('notify_notification');
    socket.emit('notify_file');
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();
    await session.close();

    expect(received, contains(ClientPushEvent.notification));
  });

  test('a server that never accepts the token is a failure', () async {
    final socket = _FakeSocket();
    await expectLater(
      ClientPushSession.open(
        connector: _FakeConnector(socket),
        endpoints: _endpoints(),
        preAuthToken: 'token-abc',
        handshakeTimeout: const Duration(milliseconds: 30),
      ),
      throwsA(isA<ClientPushException>()),
    );
    expect(socket.closed, isTrue);
  });

  test('events before the handshake are not reported', () async {
    final socket = _FakeSocket();
    final opening = ClientPushSession.open(
      connector: _FakeConnector(socket),
      endpoints: _endpoints(),
      preAuthToken: 'token-abc',
    );
    await Future<void>.delayed(Duration.zero);
    // A frame that arrives before acceptance must not look like a live channel.
    socket.emit('notify_notification');
    socket.emit('authenticated');
    final session = await opening;

    final received = <ClientPushEvent>[];
    final subscription = session.events.listen(received.add);
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();
    await session.close();

    expect(received, isEmpty);
  });

  test('a server that carries only files is refused', () async {
    await expectLater(
      ClientPushSession.open(
        connector: _FakeConnector(_FakeSocket()),
        endpoints: _endpoints(notifications: false),
        preAuthToken: 'token-abc',
      ),
      throwsA(isA<ClientPushException>()),
    );
  });
}
