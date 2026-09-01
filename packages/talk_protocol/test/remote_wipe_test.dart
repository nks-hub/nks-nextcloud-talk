import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  final server = ServerBase.parse('https://cloud.example.invalid');
  final subdirectory = ServerBase.parse(
    'https://host.example.invalid/nextcloud',
  );

  RemoteWipeRequest request({
    RemoteWipeStep step = RemoteWipeStep.check,
    ServerBase? base,
    String password = 'fixture-app-password-never-use',
  }) => RemoteWipeRequest(
    server: base ?? server,
    step: step,
    appPassword: password,
  );

  RemoteWipeResponse decode(
    RemoteWipeRequest source,
    int statusCode, [
    String body = '',
  ]) => decodeRemoteWipeResponse(
    request: source,
    statusCode: statusCode,
    body: Uint8List.fromList(utf8.encode(body)),
  );

  group('request', () {
    test('addresses the core wipe routes', () {
      expect(
        request().uri.toString(),
        'https://cloud.example.invalid/index.php/core/wipe/check',
      );
      expect(
        request(
          step: RemoteWipeStep.success,
          base: subdirectory,
        ).uri.toString(),
        'https://host.example.invalid/nextcloud/index.php/core/wipe/success',
      );
    });

    test('carries the token in the body, never in the URL or toString', () {
      final built = request(password: 'secret token/value');

      expect(utf8.decode(built.bodyBytes), 'token=secret+token%2Fvalue');
      expect(built.uri.toString(), isNot(contains('secret')));
      expect(built.toString(), isNot(contains('secret')));
    });

    test('refuses an empty or oversized token', () {
      expect(
        () => request(password: ''),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => request(password: 'a' * 513),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });

  group('check response', () {
    test('only an explicit wipe flag wipes the account', () {
      expect(
        decode(request(), 200, '{"wipe":true}').outcome,
        RemoteWipeOutcome.wipeRequested,
      );
      for (final body in const <String>[
        '{"wipe":false}',
        '{"wipe":"true"}',
        '{}',
        '',
      ]) {
        expect(
          decode(request(), 200, body).outcome,
          RemoteWipeOutcome.notRequested,
          reason: body,
        );
      }
    });

    test('an unknown or unmarked token is simply not a wipe', () {
      expect(decode(request(), 404).outcome, RemoteWipeOutcome.notRequested);
    });

    test('a server that cannot answer never causes a wipe', () {
      for (final status in const <int>[429, 500, 502, 503]) {
        expect(
          decode(request(), status).outcome,
          RemoteWipeOutcome.transientError,
          reason: '$status',
        );
      }
    });

    test('an unexpected status is a protocol failure, not a guess', () {
      expect(
        () => decode(request(), 418),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('a body that is not JSON is refused rather than read as no wipe', () {
      expect(
        () => decode(request(), 200, 'not json'),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });

  group('success response', () {
    test('a 200 acknowledges the report', () {
      expect(
        decode(
          request(step: RemoteWipeStep.success),
          200,
          '{"wipe":true}',
        ).outcome,
        RemoteWipeOutcome.acknowledged,
      );
    });

    test('a 404 report is not an error worth acting on', () {
      expect(
        decode(request(step: RemoteWipeStep.success), 404).outcome,
        RemoteWipeOutcome.notRequested,
      );
    });
  });
}
