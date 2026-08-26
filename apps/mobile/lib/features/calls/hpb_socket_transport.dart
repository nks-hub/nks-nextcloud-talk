import 'dart:async';
import 'dart:io';

import 'package:talk_protocol/talk_protocol.dart';

enum HpbSocketFailure { connection, invalidFrame }

final class HpbSocketException implements Exception {
  const HpbSocketException(this.code);

  final HpbSocketFailure code;

  @override
  String toString() => 'HpbSocketException(${code.name})';
}

abstract interface class HpbSocketConnection {
  Stream<String> get frames;

  Future<void> send(String frame);

  Future<void> close(HpbCloseReason reason);
}

abstract interface class HpbSocketConnector {
  Future<HpbSocketConnection> connect(HpbEndpoint endpoint);
}

/// Native Flutter HPB WebSocket adapter. It never forwards Nextcloud cookies,
/// Basic authentication or app passwords to the separately validated HPB
/// origin.
final class IoHpbSocketConnector implements HpbSocketConnector {
  const IoHpbSocketConnector();

  @override
  Future<HpbSocketConnection> connect(HpbEndpoint endpoint) async {
    if (endpoint.socketUri.scheme != 'wss') {
      throw const HpbSocketException(HpbSocketFailure.connection);
    }
    try {
      final socket = await WebSocket.connect(
        endpoint.socketUri.toString(),
        compression: CompressionOptions.compressionOff,
      );
      socket.pingInterval = const Duration(seconds: 20);
      return _IoHpbSocketConnection(socket);
    } on Object {
      throw const HpbSocketException(HpbSocketFailure.connection);
    }
  }
}

final class _IoHpbSocketConnection implements HpbSocketConnection {
  _IoHpbSocketConnection(this._socket) {
    _frames = _socket.transform<String>(
      StreamTransformer<Object?, String>.fromHandlers(
        handleData: (event, sink) {
          if (event is String) {
            sink.add(event);
          } else {
            sink.addError(
              const HpbSocketException(HpbSocketFailure.invalidFrame),
            );
          }
        },
        handleError: (_, _, sink) {
          sink.addError(const HpbSocketException(HpbSocketFailure.connection));
        },
      ),
    );
  }

  final WebSocket _socket;
  late final Stream<String> _frames;

  @override
  Stream<String> get frames => _frames;

  @override
  Future<void> send(String frame) async {
    try {
      _socket.add(frame);
    } on Object {
      throw const HpbSocketException(HpbSocketFailure.connection);
    }
  }

  @override
  Future<void> close(HpbCloseReason reason) async {
    final closeCode = switch (reason) {
      HpbCloseReason.release ||
      HpbCloseReason.staleConnection => WebSocketStatus.goingAway,
      HpbCloseReason.protocolFailure => WebSocketStatus.protocolError,
    };
    try {
      await _socket.close(closeCode);
    } on Object {
      // Closing is best-effort; the runtime state already owns the transition.
    }
  }
}
