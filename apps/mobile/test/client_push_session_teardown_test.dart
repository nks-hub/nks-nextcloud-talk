import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/push/client_push_session.dart';
import 'package:talk_protocol/talk_protocol.dart';

/// Accepts the handshake, then ends its stream and refuses to close.
///
/// That is what a socket the OS already tore down behaves like: the frames
/// simply stop, and closing the handle afterwards fails.
final class _EndingSocket implements ClientPushSocket {
  _EndingSocket();

  final _controller = StreamController<String>();
  var closeAttempted = false;

  @override
  Stream<String> get frames => _controller.stream;

  @override
  void send(String frame) {
    if (_controller.isClosed) {
      return;
    }
    _controller.add('authenticated');
  }

  /// Ends the frame stream, the way a dropped connection does.
  Future<void> drop() => _controller.close();

  @override
  Future<void> close() async {
    closeAttempted = true;
    throw StateError('socket already gone');
  }
}

final class _FixedConnector implements ClientPushConnector {
  _FixedConnector(this.socket);

  final _EndingSocket socket;

  @override
  Future<ClientPushSocket> connect(Uri endpoint) async => socket;
}

void main() {
  test(
    'a socket that fails to close does not reach the zone handler',
    () async {
      // The teardown that runs when the frame stream ends sits behind
      // `unawaited`, so its failure has nobody to reach except the zone, where
      // it is filed as a crash. Losing a socket is not a crash: it is the
      // ordinary end of a connection, and the close only fails because the
      // handle is already gone.
      final unhandled = <Object>[];
      final socket = _EndingSocket();
      await runZonedGuarded(() async {
        final session = await ClientPushSession.open(
          connector: _FixedConnector(socket),
          endpoints: ClientPushEndpoints(
            websocket: Uri.parse('wss://cloud.example.invalid/notify'),
            preAuth: Uri.parse('https://cloud.example.invalid/preauth'),
            carriesNotifications: true,
          ),
          preAuthToken: 'token',
        );
        final drained = session.events.drain<void>();
        await socket.drop();
        await drained;
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }, (error, stack) => unhandled.add(error));
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(
        socket.closeAttempted,
        isTrue,
        reason: 'the teardown really tried to close the socket',
      );
      expect(unhandled, isEmpty);
    },
  );
}
