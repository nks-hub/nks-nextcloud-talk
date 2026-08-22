import 'dart:convert';
import 'dart:io';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('ServerBase', () {
    final cases =
        _readJsonObject(
              'contracts/client-bootstrap/fixtures/origin-normalization.cases.json',
            )['cases']!
            as List<Object?>;

    for (final rawCase in cases) {
      final testCase = rawCase! as Map<String, Object?>;
      final id = testCase['id']! as String;
      test(id, () {
        final policy = testCase['allowDebugHttp'] == true
            ? ServerOriginPolicy.debug
            : ServerOriginPolicy.production;
        if (testCase['expectedError'] == true) {
          expect(
            () =>
                ServerBase.parse(testCase['input']! as String, policy: policy),
            throwsA(isA<TalkProtocolException>()),
          );
          return;
        }
        final server = ServerBase.parse(
          testCase['input']! as String,
          policy: policy,
        );
        expect(server.value, testCase['expected']);
      });
    }

    test('normalizes an internationalized domain name', () {
      final server = ServerBase.parse('https://BÜCHER.example/nextcloud');

      expect(server.value, 'https://xn--bcher-kva.example/nextcloud');
    });

    test('builds subpath-aware bootstrap endpoints', () {
      final server = ServerBase.parse(
        'https://cloud.example.invalid/nextcloud',
      );

      expect(
        server.statusUri.toString(),
        'https://cloud.example.invalid/nextcloud/status.php',
      );
      expect(
        server.loginFlowV2Uri.toString(),
        'https://cloud.example.invalid/nextcloud/index.php/login/v2',
      );
      expect(
        server.capabilitiesUri.toString(),
        'https://cloud.example.invalid/nextcloud/ocs/v2.php/cloud/'
        'capabilities?format=json',
      );
    });

    test('redacts invalid authority values from errors', () {
      const secret = 'fixture-password-never-log';

      Object? error;
      try {
        ServerBase.parse('https://fixture-user:$secret@example.invalid');
      } on Object catch (caught) {
        error = caught;
      }

      expect(error, isA<TalkProtocolException>());
      expect(error.toString(), isNot(contains(secret)));
      expect(error.toString(), isNot(contains('fixture-user')));
    });

    test('rejects an overlong server address', () {
      final address = 'https://${''.padRight(4090, 'a')}.invalid';

      expect(
        () => ServerBase.parse(address),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidServerAddress,
          ),
        ),
      );
    });
  });
}

Map<String, Object?> _readJsonObject(String relativePath) {
  final file = File('${_repoRoot().path}/$relativePath');
  return (jsonDecode(file.readAsStringSync())! as Map<Object?, Object?>).cast();
}

Directory _repoRoot() {
  var directory = Directory.current.absolute;
  while (directory.parent.path != directory.path) {
    if (File(
      '${directory.path}/contracts/client-bootstrap/openapi.json',
    ).existsSync()) {
      return directory;
    }
    directory = directory.parent;
  }
  throw StateError('Repository root not found');
}
