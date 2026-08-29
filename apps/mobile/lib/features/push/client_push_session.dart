import 'dart:async';
import 'dart:io';

import 'package:talk_protocol/talk_protocol.dart';

/// One authenticated Client Push socket.
///
/// `notify_push` is Nextcloud's own live channel: the server pushes
/// `notify_notification` the moment a notification appears, so the client does
/// not have to poll. It reaches every platform the app runs on for as long as
/// the app is running.
abstract interface class ClientPushSocket {
  Stream<String> get frames;

  void send(String frame);

  Future<void> close();
}

abstract interface class ClientPushConnector {
  Future<ClientPushSocket> connect(Uri endpoint);
}

/// Connects with `dart:io`, refusing anything but `wss`.
///
/// A plain `ws` endpoint would carry the pre-auth token in the clear, and the
/// token is enough to read this account's notification stream.
final class IoClientPushConnector implements ClientPushConnector {
  const IoClientPushConnector();

  @override
  Future<ClientPushSocket> connect(Uri endpoint) async {
    if (endpoint.scheme != 'wss') {
      throw const ClientPushException(ClientPushFailure.endpoint);
    }
    try {
      final socket = await WebSocket.connect(endpoint.toString());
      socket.pingInterval = const Duration(seconds: 30);
      return _IoClientPushSocket(socket);
    } on Object {
      throw const ClientPushException(ClientPushFailure.connection);
    }
  }
}

final class _IoClientPushSocket implements ClientPushSocket {
  _IoClientPushSocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<String> get frames => _socket.map((event) => event is String ? event : '');

  @override
  void send(String frame) => _socket.add(frame);

  @override
  Future<void> close() async {
    try {
      await _socket.close();
    } on Object {
      // Closing a socket that is already gone is not a failure worth raising.
    }
  }
}

enum ClientPushFailure { endpoint, connection, rejected }

final class ClientPushException implements Exception {
  const ClientPushException(this.failure);

  final ClientPushFailure failure;

  @override
  String toString() => 'ClientPushException(${failure.name})';
}

/// Performs the handshake and turns frames into events.
///
/// The credentials never reach the socket: the caller obtains a single-use
/// pre-auth token over the authenticated HTTPS API and only that token is
/// sent, which is exactly the flow `notify_push` documents.
final class ClientPushSession {
  ClientPushSession._(this._socket, this.events);

  final ClientPushSocket _socket;

  /// Events after the server accepted the handshake.
  final Stream<ClientPushEvent> events;

  static Future<ClientPushSession> open({
    required ClientPushConnector connector,
    required ClientPushEndpoints endpoints,
    required String preAuthToken,
    Duration handshakeTimeout = const Duration(seconds: 15),
  }) async {
    if (!endpoints.carriesNotifications) {
      // Holding a socket that only ever reports file changes would look like a
      // working live channel while no message could ever arrive on it.
      throw const ClientPushException(ClientPushFailure.endpoint);
    }
    final socket = await connector.connect(endpoints.websocket);
    final controller = StreamController<ClientPushEvent>.broadcast();
    final authenticated = Completer<void>();
    late final StreamSubscription<String> subscription;

    subscription = socket.frames.listen(
      (frame) {
        final event = parseClientPushFrame(frame);
        if (event == null) {
          return;
        }
        if (event == ClientPushEvent.authenticated) {
          if (!authenticated.isCompleted) {
            authenticated.complete();
          }
          return;
        }
        if (!authenticated.isCompleted) {
          // Anything before the acceptance means the server never took the
          // token; treating it as data would report a live channel that is not.
          return;
        }
        controller.add(event);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!authenticated.isCompleted) {
          authenticated.completeError(
            const ClientPushException(ClientPushFailure.connection),
            stackTrace,
          );
        }
        controller.addError(
          const ClientPushException(ClientPushFailure.connection),
        );
      },
      onDone: () {
        if (!authenticated.isCompleted) {
          authenticated.completeError(
            const ClientPushException(ClientPushFailure.rejected),
          );
        }
        controller.close();
      },
    );

    for (final frame in clientPushHandshake(preAuthToken: preAuthToken)) {
      socket.send(frame);
    }

    try {
      await authenticated.future.timeout(handshakeTimeout);
    } on Object {
      await _release(subscription, socket);
      await controller.close();
      throw const ClientPushException(ClientPushFailure.rejected);
    }

    unawaited(controller.done.then((_) => _release(subscription, socket)));
    return ClientPushSession._(socket, controller.stream);
  }

  Future<void> close() => _release(null, _socket);

  /// Lets go of a socket, whatever state it is in.
  ///
  /// Every caller is tearing down: the frame stream ended, the handshake was
  /// refused, or the account is going away. A close that fails at that point
  /// fails because the handle is already gone, which is the ordinary end of
  /// a connection and nothing anybody can act on. It used to escape instead:
  /// the teardown after the stream ends runs behind `unawaited`, so the
  /// failure reached the zone and was filed as a crash.
  static Future<void> _release(
    StreamSubscription<String>? subscription,
    ClientPushSocket socket,
  ) async {
    try {
      await subscription?.cancel();
    } on Object {
      // Cancelling twice, or after the stream already ended, is not a fault.
    }
    try {
      await socket.close();
    } on Object {
      // See above: the handle is gone, which is what we wanted anyway.
    }
  }
}
