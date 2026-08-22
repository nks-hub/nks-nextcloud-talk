import 'dart:convert';
import 'dart:io';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  final manifest = _readJsonObject(
    'contracts/client-bootstrap/fixtures/manifest.json',
  );
  final fixtures = (manifest['fixtures']! as List<Object?>)
      .cast<Map<String, Object?>>();

  group('client bootstrap fixtures', () {
    for (final fixture in fixtures) {
      final id = fixture['id']! as String;
      test(id, () => _validateFixture(fixture));
    }
  });

  group('redaction and validation', () {
    test('credential object does not stringify its secret or login name', () {
      final fixture = fixtures.singleWhere(
        (item) => item['id'] == 'login-poll-success',
      );
      final json = _readFixture(fixture);
      final result =
          parseLoginPollResponse(
                statusCode: 200,
                json: json,
                verifiedServer: ServerBase.parse(
                  fixture['credentialBaseUrl']! as String,
                ),
              )
              as LoginPollSucceeded;

      expect(result.credentials.toString(), isNot(contains('fixture-')));
      expect(result.credentials.toString(), isNot(contains('login')));
    });

    test('capability parser rejects duplicate features', () {
      final fixture = fixtures.singleWhere(
        (item) => item['id'] == 'capabilities-anonymous',
      );
      final json = _readFixture(fixture);
      final root = json as Map<String, Object?>;
      final ocs = root['ocs']! as Map<String, Object?>;
      final data = ocs['data']! as Map<String, Object?>;
      final capabilities = data['capabilities']! as Map<String, Object?>;
      final spreed = capabilities['spreed']! as Map<String, Object?>;
      spreed['features'] = ['threads', 'threads'];

      expect(
        () => CapabilitySnapshot.fromJson(
          root,
          context: CapabilityContext.anonymous,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('valid capability response can report Talk as unavailable', () {
      final fixture = fixtures.singleWhere(
        (item) => item['id'] == 'capabilities-anonymous',
      );
      final json = _readFixture(fixture);
      final root = json as Map<String, Object?>;
      final ocs = root['ocs']! as Map<String, Object?>;
      final data = ocs['data']! as Map<String, Object?>;
      final capabilities = data['capabilities']! as Map<String, Object?>;
      capabilities.remove('spreed');

      final snapshot = CapabilitySnapshot.fromJson(
        root,
        context: CapabilityContext.anonymous,
      );

      expect(snapshot.hasTalk, isFalse);
      expect(snapshot.talkFeatures, isEmpty);
    });

    test('capability parser rejects an excessively deep namespace', () {
      final fixture = fixtures.singleWhere(
        (item) => item['id'] == 'capabilities-anonymous',
      );
      final json = _readFixture(fixture);
      final root = json as Map<String, Object?>;
      final ocs = root['ocs']! as Map<String, Object?>;
      final data = ocs['data']! as Map<String, Object?>;
      final capabilities = data['capabilities']! as Map<String, Object?>;
      Object? nested = 'leaf';
      for (var depth = 0; depth < 70; depth++) {
        nested = <Object?>[nested];
      }
      capabilities['fixture-deep'] = nested;

      expect(
        () => CapabilitySnapshot.fromJson(
          root,
          context: CapabilityContext.anonymous,
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidCapabilities,
          ),
        ),
      );
    });

    test('capability parser enforces one shared node budget', () {
      final fixture = fixtures.singleWhere(
        (item) => item['id'] == 'capabilities-anonymous',
      );
      final json = _readFixture(fixture);
      final root = json as Map<String, Object?>;
      final ocs = root['ocs']! as Map<String, Object?>;
      final data = ocs['data']! as Map<String, Object?>;
      final capabilities = data['capabilities']! as Map<String, Object?>;
      capabilities['fixture-wide'] = List<Object?>.filled(10001, null);

      expect(
        () => CapabilitySnapshot.fromJson(
          root,
          context: CapabilityContext.anonymous,
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidCapabilities,
          ),
        ),
      );
    });

    test('unsupported Login Flow poll status is not guessed', () {
      expect(
        () => parseLoginPollResponse(
          statusCode: 410,
          json: const <String, Object?>{},
          verifiedServer: ServerBase.parse('https://example.invalid'),
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.unsupportedHttpStatus,
          ),
        ),
      );
    });
  });
}

void _validateFixture(Map<String, Object?> fixture) {
  final operation = fixture['operationId'];
  final direction = fixture['direction'];
  final statusCode = int.tryParse(fixture['status']?.toString() ?? '');
  final json = _readFixture(fixture);

  if (operation == 'getServerStatus') {
    final status = ServerStatus.fromJson(json);
    final actual = status.blockers.map((item) => item.wireName).toList()
      ..sort();
    final expected =
        ((fixture['expectedStatusBlockers']! as List<Object?>).cast<String>())
            .toList()
          ..sort();
    expect(actual, expected);
    return;
  }

  if (operation == 'initializeLoginFlowV2' && direction == 'request') {
    expect(json, isA<Map<Object?, Object?>>());
    expect((json as Map<Object?, Object?>), isEmpty);
    expect(loginFlowInitializationFormFields, isEmpty);
    return;
  }

  if (operation == 'initializeLoginFlowV2') {
    final policy = fixture['allowDebugHttp'] == true
        ? ServerOriginPolicy.debug
        : ServerOriginPolicy.production;
    LoginFlowInitialization action() => LoginFlowInitialization.fromJson(
      json,
      verifiedServer: ServerBase.parse(
        fixture['loginBaseUrl']! as String,
        policy: policy,
      ),
      policy: policy,
    );
    if (fixture['expectedTrusted'] == true) {
      final result = action();
      expect(result.loginUri, isNotNull);
      expect(result.pollFormBody, startsWith('token='));
      expect(result.toString(), isNot(contains(result.pollToken.value)));
    } else {
      expect(action, throwsA(isA<TalkProtocolException>()));
    }
    return;
  }

  if (operation == 'pollLoginFlowV2' && direction == 'request') {
    final request = json! as Map<String, Object?>;
    final token = OpaqueLoginToken.parse(request['token']);
    expect(
      Uri(queryParameters: {'token': token.value}).query,
      'token=${Uri.encodeQueryComponent(token.value)}',
    );
    return;
  }

  if (operation == 'pollLoginFlowV2') {
    if (statusCode == 404) {
      final result = parseLoginPollResponse(
        statusCode: statusCode!,
        json: json,
        verifiedServer: ServerBase.parse('https://example.invalid'),
      );
      expect(result, isA<LoginPollPending>());
      return;
    }
    if (fixture['valid'] == false) {
      expect(
        () => parseLoginPollResponse(
          statusCode: statusCode!,
          json: json,
          verifiedServer: ServerBase.parse('https://example.invalid'),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      return;
    }
    final policy = fixture['allowDebugHttp'] == true
        ? ServerOriginPolicy.debug
        : ServerOriginPolicy.production;
    LoginPollResult action() => parseLoginPollResponse(
      statusCode: statusCode!,
      json: json,
      verifiedServer: ServerBase.parse(
        fixture['credentialBaseUrl']! as String,
        policy: policy,
      ),
      policy: policy,
    );
    if (fixture['expectedTrustedCredentials'] == true) {
      final result = action();
      expect(result, isA<LoginPollSucceeded>());
      final succeeded = result as LoginPollSucceeded;
      expect(
        succeeded.credentials.appPassword,
        startsWith(fixture['syntheticSecretPrefix']! as String),
      );
    } else {
      expect(action, throwsA(isA<TalkProtocolException>()));
    }
    return;
  }

  if (operation == 'getCapabilities') {
    final context = switch (fixture['capabilityContext']) {
      'anonymous' => CapabilityContext.anonymous,
      'authenticated' => CapabilityContext.authenticated,
      _ => throw StateError('Unknown fixture capability context'),
    };
    final snapshot = CapabilitySnapshot.fromJson(json, context: context);
    expect(snapshot.context, context);
    for (final namespace
        in (fixture['requiredNamespaces']! as List<Object?>).cast<String>()) {
      expect(snapshot.namespaces, contains(namespace));
    }
    for (final namespace
        in ((fixture['forbiddenNamespaces'] as List<Object?>?) ?? const [])
            .cast<String>()) {
      expect(snapshot.namespaces, isNot(contains(namespace)));
    }
    for (final feature
        in (fixture['requiredTalkFeatures']! as List<Object?>).cast<String>()) {
      expect(snapshot.supportsTalk(feature), isTrue);
    }
    for (final feature
        in ((fixture['requiredNotificationPush'] as List<Object?>?) ?? const [])
            .cast<String>()) {
      expect(snapshot.supportsNotificationPush(feature), isTrue);
    }
    return;
  }

  fail('Fixture ${fixture['id']} was not dispatched');
}

Object? _readFixture(Map<String, Object?> fixture) {
  final relative = 'contracts/client-bootstrap/fixtures/${fixture['file']}';
  final file = File('${_repoRoot().path}/$relative');
  return jsonDecode(file.readAsStringSync());
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
