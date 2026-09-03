import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('parseQrLoginPayload accepts what upstream accepts', () {
    test('all three parameters', () {
      final payload = parseQrLoginPayload(
        'nc://login/user:testuser&server:https%3A//example.com'
        '&password:testpass',
      );
      expect(payload, isA<QrLoginCredentials>());
      final credentials = payload! as QrLoginCredentials;
      expect(credentials.server.value, 'https://example.com');
      expect(credentials.loginName, 'testuser');
      expect(credentials.secret, 'testpass');
      expect(credentials.isOneTime, isFalse);
    });

    test('mixed parameter order', () {
      final payload = parseQrLoginPayload(
        'nc://login/password:testpass&user:testuser'
        '&server:https%3A//example.com',
      );
      final credentials = payload! as QrLoginCredentials;
      expect(credentials.server.value, 'https://example.com');
      expect(credentials.loginName, 'testuser');
      expect(credentials.secret, 'testpass');
    });

    test('URL encoding, including a percent-encoded separator', () {
      final payload = parseQrLoginPayload(
        'nc://login/user:test%40user.com&server:https%3A//example.com%3A8080'
        '&password:test%26pass',
      );
      final credentials = payload! as QrLoginCredentials;
      expect(credentials.loginName, 'test@user.com');
      expect(credentials.server.value, 'https://example.com:8080');
      expect(credentials.secret, 'test&pass');
    });

    test('a plus decodes to a space, as java.net.URLDecoder does', () {
      final payload = parseQrLoginPayload(
        'nc://login/user:first+last&server:https%3A//example.com'
        '&password:one+two',
      );
      final credentials = payload! as QrLoginCredentials;
      expect(credentials.loginName, 'first last');
      expect(credentials.secret, 'one two');
    });

    test('one-time prefix keeps the token separate from an app password', () {
      final payload = parseQrLoginPayload(
        'nc://onetime-login/user:testuser&server:https%3A//example.com'
        '&password:onetimetoken',
      );
      final credentials = payload! as QrLoginCredentials;
      expect(credentials.isOneTime, isTrue);
      expect(credentials.secret, 'onetimetoken');
    });

    test('a scheme-less server is upgraded to https, as ServerBase does', () {
      final payload = parseQrLoginPayload(
        'nc://login/user:u&server:example.com&password:p',
      );
      expect((payload! as QrLoginCredentials).server.value,
          'https://example.com');
    });

    test('the server is canonicalized exactly as ServerBase.parse does', () {
      final payload = parseQrLoginPayload(
        'nc://login/user:u&server:HTTPS%3A//Example.COM%3A443/nextcloud/'
        '&password:p',
      );
      final credentials = payload! as QrLoginCredentials;
      expect(
        credentials.server,
        ServerBase.parse('https://example.com/nextcloud'),
      );
    });
  });

  group('parseQrLoginPayload rejects', () {
    test('an invalid prefix', () {
      expect(
        parseQrLoginPayload(
          'invalid://login/user:testuser&server:https://example.com',
        ),
        isNull,
      );
    });

    test('more than three elements', () {
      expect(
        parseQrLoginPayload(
          'nc://login/user:test&server:https%3A//example.com'
          '&password:pass&extra:value',
        ),
        isNull,
      );
    });

    test('empty data', () {
      expect(parseQrLoginPayload('nc://login/'), isNull);
    });

    test('a malformed body without key prefixes', () {
      expect(
        parseQrLoginPayload('nc://login/malformed&data&without'),
        isNull,
      );
    });

    test('a present but empty value', () {
      expect(parseQrLoginPayload('nc://login/user:testuser&server:'), isNull);
    });

    test('an unknown key alongside a server', () {
      expect(
        parseQrLoginPayload('nc://login/server:https%3A//example.com&x:1'),
        isNull,
      );
    });

    test('a repeated key', () {
      expect(
        parseQrLoginPayload(
          'nc://login/server:https%3A//example.com'
          '&server:https%3A//other.example&user:u',
        ),
        isNull,
      );
    });

    test('an identity without a secret', () {
      expect(
        parseQrLoginPayload(
          'nc://login/user:testuser&server:https%3A//example.com',
        ),
        isNull,
      );
    });

    test('a secret without an identity', () {
      expect(
        parseQrLoginPayload(
          'nc://login/password:testpass&server:https%3A//example.com',
        ),
        isNull,
      );
    });

    test('a server that is not a usable address at all', () {
      expect(
        parseQrLoginPayload(
          'nc://login/user:u&server:https%3A///&password:p',
        ),
        isNull,
      );
    });

    test('a server with userinfo in the authority', () {
      expect(
        parseQrLoginPayload(
          'nc://login/user:u&server:https%3A//a%40evil.example&password:p',
        ),
        isNull,
      );
    });

    test('a plaintext HTTP server under the production policy', () {
      expect(
        parseQrLoginPayload(
          'nc://login/user:u&server:http%3A//example.com&password:p',
        ),
        isNull,
      );
    });

    test('a broken percent escape', () {
      expect(
        parseQrLoginPayload('nc://login/server:https%3A//example.com&user:%zz'),
        isNull,
      );
    });

    test('a payload longer than a QR code can carry', () {
      final long = 'a' * 4096;
      expect(
        parseQrLoginPayload(
          'nc://login/user:$long&server:https%3A//example.com&password:p',
        ),
        isNull,
      );
    });

    test('a one-time prefix that carries no token', () {
      expect(
        parseQrLoginPayload('nc://onetime-login/server:https%3A//example.com'),
        isNull,
      );
    });
  });

  group('parseQrLoginPayload server-only divergence', () {
    // Upstream Android returns null here. We keep it so the caller can fall
    // back to Login Flow v2 against that server; no secret is involved.
    test('a bare server address is reported as such', () {
      final payload = parseQrLoginPayload(
        'nc://login/server:https%3A//example.com',
      );
      expect(payload, isA<QrLoginServerOnly>());
      expect(payload!.server.value, 'https://example.com');
    });
  });

  test('a scanned payload never prints its secret', () {
    final payload = parseQrLoginPayload(
      'nc://login/user:testuser&server:https%3A//example.com'
      '&password:supersecret',
    )!;
    expect(payload.toString(), isNot(contains('supersecret')));
    expect(
      (payload as QrLoginCredentials).toLoginFlowCredentials().toString(),
      isNot(contains('supersecret')),
    );
  });

  test('a scanned payload reuses the Login Flow credential shape', () {
    final payload =
        parseQrLoginPayload(
              'nc://login/user:testuser&server:https%3A//example.com'
              '&password:testpass',
            )!
            as QrLoginCredentials;
    final credentials = payload.toLoginFlowCredentials();
    expect(credentials.server, payload.server);
    expect(credentials.loginName, 'testuser');
    expect(credentials.appPassword, 'testpass');
  });
}
