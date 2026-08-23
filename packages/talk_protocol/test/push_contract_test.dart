import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

import 'support/push_test_support.dart';

void main() {
  final manifest = _readJsonObject(
    'contracts/push-client/fixtures/manifest.json',
  );
  final fixtures = (manifest['fixtures']! as List<Object?>)
      .cast<Map<String, Object?>>();

  group('push client fixtures', () {
    for (final fixture in fixtures) {
      test(fixture['id']! as String, () => _validateFixture(fixture));
    }
  });

  group('push crypto material', () {
    test('accepts a strict RSA-2048 SPKI public key', () {
      final key = PushRsaPublicKey.parse(pushPublicKeyA);

      expect(key.pem, pushPublicKeyA);
      expect(key.modulusBits, 2048);
      expect(key.exponent, 65537);
      expect(key.toString(), isNot(contains('MIIB')));
    });

    test('rejects malformed or non-SPKI key material', () {
      expect(
        () => PushRsaPublicKey.parse(
          pushPublicKeyA.replaceFirst('PUBLIC KEY', 'RSA PUBLIC KEY'),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => PushRsaPublicKey.parse(pushPublicKeyA.substring(0, 100)),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('rejects bytes trailing the SPKI and inner RSA sequence', () {
      final der = _decodePem(pushPublicKeyA);
      final outsideRoot = Uint8List.fromList(<int>[...der, 0]);
      expect(
        () => PushRsaPublicKey.parse(_encodePem(outsideRoot)),
        throwsA(isA<TalkProtocolException>()),
      );

      final insideBitString = List<int>.of(der);
      final rootValueOffset = _derValueOffset(insideBitString, 0);
      final algorithmEnd = _derTlvEnd(insideBitString, rootValueOffset);
      expect(insideBitString[algorithmEnd], 0x03);
      _incrementDerLength(insideBitString, 0);
      _incrementDerLength(insideBitString, algorithmEnd);
      insideBitString.add(0);
      expect(
        () => PushRsaPublicKey.parse(
          _encodePem(Uint8List.fromList(insideBitString)),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });

  group('Nextcloud push registration response', () {
    test('parses a bounded OCS 201 response', () {
      final effect = pushNextcloudRegistrationEffect(
        authority: pushAuthority(pushAccountA),
        providerToken: pushProviderToken(),
        key: pushDeviceKey(pushAccountA),
        effectId: pushEffectId(1),
      );
      final response = decodePushNextcloudRegistrationResponse(
        effect: effect,
        statusCode: 201,
        body: jsonEncode(<String, Object?>{
          'ocs': <String, Object?>{
            'meta': <String, Object?>{
              'status': 'ok',
              'statuscode': 200,
              'message': 'OK',
            },
            'data': <String, Object?>{
              'publicKey': pushPublicKeyA,
              'deviceIdentifier': pushDeviceIdentifier,
              'signature': pushDeviceSignature,
            },
          },
        }),
      );

      expect(response.classification, PushCompletionClass.success);
      expect(response.registration!.deviceIdentifier.decodedLength, 64);
    });

    test('rejects duplicate JSON members and oversized bodies', () {
      final effect = pushNextcloudRegistrationEffect(
        authority: pushAuthority(pushAccountA),
        providerToken: pushProviderToken(),
        key: pushDeviceKey(pushAccountA),
        effectId: pushEffectId(2),
      );
      expect(
        () => decodePushNextcloudRegistrationResponse(
          effect: effect,
          statusCode: 201,
          body:
              '{"ocs":{"meta":{"status":"ok","statuscode":200},'
              '"data":{"publicKey":"x","publicKey":"y",'
              '"deviceIdentifier":"x","signature":"x"}}}',
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => decodePushNextcloudRegistrationResponse(
          effect: effect,
          statusCode: 201,
          body: 'x' * (PushWireLimits.maximumOcsBodyBytes + 1),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('classifies an HTTP request timeout as retryable', () {
      final effect = pushNextcloudRegistrationEffect(
        authority: pushAuthority(pushAccountA),
        providerToken: pushProviderToken(),
        key: pushDeviceKey(pushAccountA),
        effectId: pushEffectId(3),
      );

      final response = decodePushNextcloudRegistrationResponse(
        effect: effect,
        statusCode: 408,
        body: '',
      );

      expect(response.classification, PushCompletionClass.transientFailure);
    });
  });

  group('mobile push envelope and plaintext', () {
    test('requires canonical RSA-2048 ciphertext and signature', () {
      final encoded = base64Encode(List<int>.filled(256, 7));
      final envelope = PushEnvelope.parse(
        envelopeId: PushEnvelopeId.parse('envelope-a'),
        subjectBase64: encoded,
        signatureBase64: encoded,
      );

      expect(envelope.ciphertext, hasLength(256));
      expect(envelope.signature, hasLength(256));
      expect(envelope.toString(), isNot(contains(encoded.substring(0, 16))));
      expect(
        () => PushEnvelope.parse(
          envelopeId: PushEnvelopeId.parse('envelope-b'),
          subjectBase64: '$encoded\n',
          signatureBase64: encoded,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('parses normal and all silent-delete payload variants', () {
      final normal = decodePushWakeUpPayload(
        '{"app":"spreed","subject":"Synthetic",'
        '"type":"chat","id":"rooma123","nid":1337}',
      );
      final one = decodePushWakeUpPayload('{"delete":true,"nid":1337}');
      final multiple = decodePushWakeUpPayload(
        '{"delete-multiple":true,"nids":[1337,1338]}',
      );
      final all = decodePushWakeUpPayload('{"delete-all":true}');

      expect(normal.action, PushWakeUpAction.catchUp);
      expect(one.action, PushWakeUpAction.deleteOne);
      expect(multiple.action, PushWakeUpAction.deleteMultiple);
      expect(all.action, PushWakeUpAction.deleteAll);
      expect(normal.toString(), isNot(contains('Synthetic')));
    });

    test('rejects ambiguous delete flags and duplicate members', () {
      expect(
        () => decodePushWakeUpPayload(
          '{"delete":true,"delete-all":true,"nid":1}',
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => decodePushWakeUpPayload('{"nid":1,"nid":2}'),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('matches the fail-closed OpenAPI action schemas exactly', () {
      for (final source in <String>[
        '{"delete-all":true,"nid":1}',
        '{"delete":true,"nid":1,"app":"spreed"}',
        '{"delete":false,"nid":1}',
        '{"app":""}',
        '{"app":null,"nid":1}',
        '{"app":"spreed","unknown":true}',
      ]) {
        expect(
          () => decodePushWakeUpPayload(source),
          throwsA(isA<TalkProtocolException>()),
          reason: source,
        );
      }
    });
  });

  group('push response budgets', () {
    test('rejects oversized success and error bodies for every response', () {
      final authority = pushAuthority(pushAccountA);
      final providerToken = pushProviderToken();
      final key = pushDeviceKey(pushAccountA);
      final registration = pushServerRegistration();
      final context = PushEffectContext.forAuthority(
        effectId: pushEffectId(89),
        authority: authority,
        providerTokenGeneration: providerToken.generation,
        keyGeneration: key.generation,
        registrationRevision: 1,
      );
      final nextcloudRegistration = RegisterPushWithNextcloudEffect(
        context: context,
        providerToken: providerToken,
        key: key,
      );
      final gatewayRegistration = RegisterPushWithGatewayEffect(
        context: context,
        providerToken: providerToken,
        registration: registration,
        cloudId: null,
      );
      final nextcloudUnregistration = UnregisterPushFromNextcloudEffect(
        context: context,
      );
      final gatewayUnregistration = UnregisterPushFromGatewayEffect(
        context: context,
        registration: registration,
      );
      final oversized = 'x' * (PushWireLimits.maximumOcsBodyBytes + 1);
      final decoders = <String, void Function(int statusCode, String body)>{
        'Nextcloud registration': (statusCode, body) {
          decodePushNextcloudRegistrationResponse(
            effect: nextcloudRegistration,
            statusCode: statusCode,
            body: body,
          );
        },
        'gateway registration': (statusCode, body) {
          decodePushGatewayRegistrationResponse(
            effect: gatewayRegistration,
            statusCode: statusCode,
            body: body,
          );
        },
        'Nextcloud unregistration': (statusCode, body) {
          decodePushNextcloudUnregistrationResponse(
            effect: nextcloudUnregistration,
            statusCode: statusCode,
            body: body,
          );
        },
        'gateway unregistration': (statusCode, body) {
          decodePushGatewayUnregistrationResponse(
            effect: gatewayUnregistration,
            statusCode: statusCode,
            body: body,
          );
        },
      };

      for (final decoder in decoders.entries) {
        for (final statusCode in <int>[200, 401, 403, 409, 429, 500]) {
          expect(
            () => decoder.value(statusCode, oversized),
            throwsA(isA<TalkProtocolException>()),
            reason: '${decoder.key} HTTP $statusCode',
          );
        }
      }
    });
  });

  group('push unregistration responses', () {
    test('uses the upstream DELETE endpoints and strict success statuses', () {
      final authority = pushAuthority(pushAccountA);
      var snapshot = addPushAccountAndToken(
        PushRuntimeSnapshot.empty(),
        authority,
      );
      snapshot = completePushAccountRegistration(
        snapshot,
        authority,
        key: pushDeviceKey(pushAccountA),
      );
      snapshot = commitPushRuntime(
        snapshot,
        requestPushAccountRemoval(snapshot, authority),
      );
      var planned = planNextPushEffect(snapshot, effectId: pushEffectId(90));
      final nextcloud = planned.effect! as UnregisterPushFromNextcloudEffect;
      expect(nextcloud.uri.path, '/ocs/v2.php/apps/notifications/api/v2/push');
      expect(nextcloud.uri.queryParameters['format'], 'json');
      snapshot = commitPushRuntime(snapshot, planned);
      snapshot = commitPushRuntime(
        snapshot,
        completePushEffect(
          snapshot,
          decodePushNextcloudUnregistrationResponse(
            effect: nextcloud,
            statusCode: 202,
            body: '',
          ),
        ),
      );

      planned = planNextPushEffect(snapshot, effectId: pushEffectId(91));
      final gateway = planned.effect! as UnregisterPushFromGatewayEffect;
      expect(gateway.uri.path, '/devices');
      expect(
        gateway.uri.queryParameters.keys,
        containsAll(<String>[
          'deviceIdentifier',
          'deviceIdentifierSignature',
          'userPublicKey',
        ]),
      );
      expect(
        decodePushGatewayUnregistrationResponse(
          effect: gateway,
          statusCode: 200,
          body: '',
        ).classification,
        PushCompletionClass.success,
      );
      expect(
        decodePushGatewayUnregistrationResponse(
          effect: gateway,
          statusCode: 403,
          body: '',
        ).classification,
        PushCompletionClass.rejected,
      );
    });
  });
}

void _validateFixture(Map<String, Object?> fixture) {
  final id = fixture['id']! as String;
  final schema = fixture['schema']! as String;
  final source = _readFixtureSource(fixture);

  switch (schema) {
    case 'PushRegistrationRequest':
      final expected = (jsonDecode(source)! as Map<Object?, Object?>)
          .cast<String, String>();
      final effect = pushNextcloudRegistrationEffect(
        authority: pushAuthority(pushAccountA),
        providerToken: pushProviderToken(),
        key: pushDeviceKey(pushAccountA),
        effectId: pushEffectId(700),
      );
      expect(effect.formFields, expected);
      return;
    case 'OcsPushRegistrationEnvelope':
      final effect = pushNextcloudRegistrationEffect(
        authority: pushAuthority(pushAccountA),
        providerToken: pushProviderToken(),
        key: pushDeviceKey(pushAccountA),
        effectId: pushEffectId(701),
      );
      final response = decodePushNextcloudRegistrationResponse(
        effect: effect,
        statusCode: 201,
        body: source,
      );
      expect(response.classification, PushCompletionClass.success);
      expect(response.registration!.userPublicKey.pem, pushPublicKeyA);
      expect(
        response.registration!.deviceIdentifier.value,
        pushDeviceIdentifier,
      );
      expect(
        response.registration!.deviceIdentifierSignature.value,
        pushDeviceSignature,
      );
      return;
    case 'MobilePushEnvelope':
      final json = (jsonDecode(source)! as Map<Object?, Object?>)
          .cast<String, Object?>();
      final envelope = PushEnvelope.parse(
        envelopeId: PushEnvelopeId.parse(id),
        subjectBase64: json['subject']! as String,
        signatureBase64: json['signature']! as String,
      );
      expect(envelope.ciphertext, hasLength(256));
      expect(envelope.signature, hasLength(256));
      return;
    case 'WakeUpPayload':
      PushWakeUpPayload decode() => decodePushWakeUpPayload(source);
      if (fixture['valid'] == false) {
        expect(decode, throwsA(isA<TalkProtocolException>()));
        return;
      }
      final payload = decode();
      final expectedAction = switch (id) {
        'wake-up-normal' => PushWakeUpAction.catchUp,
        'wake-up-delete-one' => PushWakeUpAction.deleteOne,
        'wake-up-delete-multiple' => PushWakeUpAction.deleteMultiple,
        'wake-up-delete-all' => PushWakeUpAction.deleteAll,
        _ => throw StateError('Unknown wake-up fixture $id'),
      };
      expect(payload.action, expectedAction);
      return;
    default:
      throw StateError('Unknown push fixture schema $schema');
  }
}

String _readFixtureSource(Map<String, Object?> fixture) {
  final relative = 'contracts/push-client/fixtures/${fixture['file']}';
  return File('${_repoRoot().path}/$relative').readAsStringSync();
}

Map<String, Object?> _readJsonObject(String relativePath) {
  final source = File('${_repoRoot().path}/$relativePath').readAsStringSync();
  return (jsonDecode(source)! as Map<Object?, Object?>).cast<String, Object?>();
}

Directory _repoRoot() {
  var directory = Directory.current.absolute;
  while (directory.parent.path != directory.path) {
    if (File(
      '${directory.path}/contracts/push-client/openapi.json',
    ).existsSync()) {
      return directory;
    }
    directory = directory.parent;
  }
  throw StateError('Repository root not found');
}

Uint8List _decodePem(String pem) {
  final body = pem
      .split('\n')
      .where((line) => line.isNotEmpty && !line.startsWith('-----'))
      .join();
  return base64Decode(body);
}

String _encodePem(Uint8List der) {
  final body = base64Encode(der);
  final lines = <String>[];
  for (var offset = 0; offset < body.length; offset += 64) {
    final end = offset + 64 < body.length ? offset + 64 : body.length;
    lines.add(body.substring(offset, end));
  }
  return '-----BEGIN PUBLIC KEY-----\n${lines.join('\n')}\n'
      '-----END PUBLIC KEY-----\n';
}

int _derValueOffset(List<int> bytes, int tagOffset) {
  final first = bytes[tagOffset + 1];
  return (first & 0x80) == 0 ? tagOffset + 2 : tagOffset + 2 + (first & 0x7f);
}

int _derLength(List<int> bytes, int tagOffset) {
  final first = bytes[tagOffset + 1];
  if ((first & 0x80) == 0) {
    return first;
  }
  final count = first & 0x7f;
  var value = 0;
  for (var index = 0; index < count; index++) {
    value = (value << 8) | bytes[tagOffset + 2 + index];
  }
  return value;
}

int _derTlvEnd(List<int> bytes, int tagOffset) =>
    _derValueOffset(bytes, tagOffset) + _derLength(bytes, tagOffset);

void _incrementDerLength(List<int> bytes, int tagOffset) {
  final lengthOffset = tagOffset + 1;
  final first = bytes[lengthOffset];
  if ((first & 0x80) == 0) {
    bytes[lengthOffset] = first + 1;
    return;
  }
  final count = first & 0x7f;
  var value = _derLength(bytes, tagOffset) + 1;
  for (var index = count - 1; index >= 0; index--) {
    bytes[lengthOffset + 1 + index] = value & 0xff;
    value >>= 8;
  }
  expect(value, 0);
}
