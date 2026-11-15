import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

const _message = 'Synthetic message that must not be duplicated';

void main() {
  Future<NextcloudApiException> failedSend(
    HttpNextcloudApi api, {
    String server = 'https://cloud.example.invalid',
  }) async {
    try {
      await api.sendChat(
        chatRequest: _sendRequest(server),
        loginName: 'fixture-user',
        appPassword: 'fixture-app-password-never-use',
      );
    } on NextcloudApiException catch (error) {
      return error;
    }
    fail('The send was expected to fail');
  }

  test('a failure before the body is asked for is provably unsent', () async {
    final api = HttpNextcloudApi(client: _NeverConnectsClient());
    addTearDown(api.close);

    final error = await failedSend(api);

    expect(error.code, NextcloudApiError.network);
    expect(error.requestNotSent, isTrue);
  });

  test('a failure after the body was read may have been stored', () async {
    final api = HttpNextcloudApi(
      client: MockClient(
        (request) => throw http.ClientException('reset', request.url),
      ),
    );
    addTearDown(api.close);

    final error = await failedSend(api);

    expect(error.code, NextcloudApiError.network);
    expect(error.requestNotSent, isFalse);
  });

  for (final (statusCode, contentLength, code) in const [
    (302, null, NextcloudApiError.unexpectedStatus),
    (201, 1 << 30, NextcloudApiError.responseTooLarge),
  ]) {
    test(
      'a rejected $statusCode answer with an endless body still ends',
      () async {
        final body = StreamController<List<int>>();
        final trickle = Timer.periodic(
          const Duration(milliseconds: 20),
          (_) => body.add(const [0x20]),
        );
        addTearDown(trickle.cancel);
        final api = HttpNextcloudApi(
          requestTimeout: const Duration(milliseconds: 300),
          client: MockClient.streaming((request, sent) async {
            await sent.drain<void>();
            return http.StreamedResponse(
              body.stream,
              statusCode,
              contentLength: contentLength,
            );
          }),
        );
        addTearDown(api.close);

        final error = await failedSend(api).timeout(const Duration(seconds: 5));

        expect(error.code, code);
        // The status line settled it, whatever the body went on to do.
        expect(error.requestNotSent, isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(body.hasListener, isFalse);
      },
    );
  }

  test('a refused connection is provably unsent on a real socket', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = probe.port;
    await probe.close();
    final api = HttpNextcloudApi(
      client: IOClient(
        HttpClient()
          ..connectionFactory = (_, _, _) =>
              Socket.startConnect(InternetAddress.loopbackIPv4, closedPort),
      ),
    );
    addTearDown(api.close);

    final error = await failedSend(api);

    expect(error.code, NextcloudApiError.network);
    expect(error.requestNotSent, isTrue);
  });

  test('a failed TLS handshake is provably unsent', () async {
    // The peer answers the ClientHello with plain text, so the handshake
    // fails on a connection that never carried the request.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((socket) {
      socket.listen((_) {}, onError: (Object _) {});
      socket.write('not a TLS server\r\n');
      unawaited(socket.close().catchError((Object _) {}));
    });
    final api = HttpNextcloudApi(
      client: IOClient(
        HttpClient()
          ..connectionFactory = (_, _, _) => SecureSocket.startConnect(
            InternetAddress.loopbackIPv4,
            server.port,
          ),
      ),
    );
    addTearDown(api.close);

    final error = await failedSend(api);

    expect(error.code, NextcloudApiError.network);
    expect(error.requestNotSent, isTrue);
  });

  test('a connection that comes up after the timeout sends no body', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final received = BytesBuilder();
    final connected = Completer<void>();
    final sockets = <Socket>[];
    server.listen((socket) {
      sockets.add(socket);
      if (!connected.isCompleted) connected.complete();
      socket.listen(received.add, onError: (Object _) {});
    });
    addTearDown(() {
      for (final socket in sockets) {
        socket.destroy();
      }
    });
    final network = Completer<void>();
    final api = HttpNextcloudApi(
      requestTimeout: const Duration(milliseconds: 100),
      client: IOClient(
        HttpClient()
          ..connectionFactory = (_, _, _) async {
            await network.future;
            return Socket.startConnect(
              InternetAddress.loopbackIPv4,
              server.port,
            );
          },
      ),
    );
    addTearDown(api.close);

    final error = await failedSend(
      api,
      server: 'http://127.0.0.1:${server.port}',
    );
    expect(error.code, NextcloudApiError.timeout);
    expect(error.requestNotSent, isTrue);

    network.complete();
    await connected.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      latin1.decode(received.toBytes()),
      isNot(contains(Uri.encodeQueryComponent(_message))),
    );
  });

  test('a timeout after the body was written stays ambiguous', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final received = BytesBuilder();
    final sockets = <Socket>[];
    server.listen((socket) {
      sockets.add(socket);
      socket.listen(received.add, onError: (Object _) {});
    });
    addTearDown(() {
      for (final socket in sockets) {
        socket.destroy();
      }
    });
    final api = HttpNextcloudApi(
      requestTimeout: const Duration(milliseconds: 300),
      client: IOClient(HttpClient()),
    );
    addTearDown(api.close);

    final error = await failedSend(
      api,
      server: 'http://127.0.0.1:${server.port}',
    );

    expect(error.code, NextcloudApiError.timeout);
    expect(error.requestNotSent, isFalse);
    expect(
      latin1.decode(received.toBytes()),
      contains(Uri.encodeQueryComponent(_message)),
    );
  });
}

ChatSendRequest _sendRequest(String server) => ChatSendRequest.restored(
  accountId: AccountId.parse('fixture-account'),
  requestId: ChatRequestId.parse('fixture-send'),
  server: ServerBase.parse(server, policy: ServerOriginPolicy.debug),
  roomToken: ConversationToken.parse('rooma123', path: r'$.token'),
  operationId: ChatOperationId.parse('aaaaaaaa-0000-4000-8000-000000000001'),
  profile: ChatCapabilityProfile.fromTalkFeatures(const <String>[
    'chat-v2',
    'chat-reference-id',
  ], federated: false),
  message: _message,
  referenceId: ChatReferenceId.parse('11111111-1111-4111-8111-111111111111'),
);

/// A client that fails the way a refused connection does: without ever
/// listening to the request body.
final class _NeverConnectsClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.finalize();
    throw http.ClientException('Synthetic connection failure', request.url);
  }
}
