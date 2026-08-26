import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/calls/hpb_socket_transport.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  test('native connector rejects a cleartext HPB endpoint', () async {
    final endpoint = HpbEndpoint.parse(
      'ws://127.0.0.1:18080',
      policy: SignalingEndpointPolicy.debug,
    );

    await expectLater(
      const IoHpbSocketConnector().connect(endpoint),
      throwsA(
        isA<HpbSocketException>().having(
          (error) => error.code,
          'code',
          HpbSocketFailure.connection,
        ),
      ),
    );
  });

  test(
    'TLS handshake failures are redacted to a generic socket error',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((socket) {
        socket.write('synthetic non-TLS response');
        socket.destroy();
      });
      final endpoint = HpbEndpoint.parse(
        'https://127.0.0.1:${server.port}/signaling',
      );

      Object? observed;
      try {
        await const IoHpbSocketConnector().connect(endpoint);
      } on Object catch (error) {
        observed = error;
      }

      expect(observed, isA<HpbSocketException>());
      expect(
        (observed! as HpbSocketException).code,
        HpbSocketFailure.connection,
      );
      expect(observed.toString(), isNot(contains('127.0.0.1')));
      expect(observed.toString(), isNot(contains(server.port.toString())));
    },
  );
}
