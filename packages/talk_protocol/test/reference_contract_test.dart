import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('reference capability', () {
    test('requires the authenticated core reference-api flag', () {
      expect(
        ReferenceCapabilityProfile.fromCapabilities(
          _capabilities(referenceApi: true),
        ).enabled,
        isTrue,
      );
      expect(
        ReferenceCapabilityProfile.fromCapabilities(
          _capabilities(referenceApi: false),
        ).enabled,
        isFalse,
      );
      expect(
        ReferenceCapabilityProfile.fromCapabilities(
          _capabilities(referenceApi: true, authenticated: false),
        ).enabled,
        isFalse,
      );
    });
  });

  group('reference request', () {
    test('builds the core resolver request below a server subpath', () {
      final request = ReferenceResolveRequest(
        server: ServerBase.parse('https://cloud.example.invalid/nextcloud'),
        reference: Uri.parse('https://docs.example.invalid/topic?q=one#part'),
      );

      expect(request.uri.path, '/nextcloud/ocs/v2.php/references/resolve');
      expect(request.uri.queryParameters, {
        'reference': 'https://docs.example.invalid/topic?q=one#part',
        'format': 'json',
      });
    });

    test('rejects non-HTTPS and credential-bearing targets', () {
      final server = ServerBase.parse('https://cloud.example.invalid');

      expect(
        () => ReferenceResolveRequest(
          server: server,
          reference: Uri.parse('http://docs.example.invalid/topic'),
        ),
        throwsA(isA<ReferenceProtocolException>()),
      );
      expect(
        () => ReferenceResolveRequest(
          server: server,
          reference: Uri.parse('https://user@docs.example.invalid/topic'),
        ),
        throwsA(isA<ReferenceProtocolException>()),
      );
    });
  });

  group('reference response', () {
    test('binds the exact requested key and ignores provider wire links', () {
      final request = _request();
      final response = ReferenceResolveResponse.parse(
        request: request,
        statusCode: 200,
        json: _response(
          type: 'integration_unknown',
          providerLink: 'https://spoofed.example.invalid/phishing',
        ),
      );

      expect(response.classification, ReferenceClassification.resolved);
      expect(response.reference?.reference, request.reference);
      expect(response.reference?.title, 'Verified title');
      expect(response.reference?.description, 'Verified description');
      expect(response.reference?.richObjectType, 'integration_unknown');
      expect(
        response.reference.toString(),
        isNot(contains('spoofed.example.invalid')),
      );
    });

    test('rejects a response keyed by a different URL', () {
      final request = _request();
      final json = _response();
      final references =
          ((json['ocs']! as Map<String, Object?>)['data']!
                  as Map<String, Object?>)['references']!
              as Map<String, Object?>;
      final value = references.remove(request.reference.toString());
      references['https://spoofed.example.invalid'] = value;

      expect(
        () => ReferenceResolveResponse.parse(
          request: request,
          statusCode: 200,
          json: json,
        ),
        throwsA(isA<ReferenceProtocolException>()),
      );
    });

    test('falls back when the provider returns null or inaccessible data', () {
      final request = _request();
      final missing = _response();
      final missingReferences =
          ((missing['ocs']! as Map<String, Object?>)['data']!
                  as Map<String, Object?>)['references']!
              as Map<String, Object?>;
      missingReferences[request.reference.toString()] = null;

      expect(
        ReferenceResolveResponse.parse(
          request: request,
          statusCode: 200,
          json: missing,
        ).classification,
        ReferenceClassification.unavailable,
      );
      expect(
        ReferenceResolveResponse.parse(
          request: request,
          statusCode: 200,
          json: _response(accessible: false),
        ).classification,
        ReferenceClassification.unavailable,
      );
    });

    test('classifies authentication, unsupported and transient statuses', () {
      final request = _request();

      expect(
        ReferenceResolveResponse.parse(
          request: request,
          statusCode: 401,
          json: const <String, Object?>{},
        ).classification,
        ReferenceClassification.reauthenticationRequired,
      );
      expect(
        ReferenceResolveResponse.parse(
          request: request,
          statusCode: 404,
          json: const <String, Object?>{},
        ).classification,
        ReferenceClassification.unsupported,
      );
      expect(
        ReferenceResolveResponse.parse(
          request: request,
          statusCode: 429,
          json: const <String, Object?>{},
        ).classification,
        ReferenceClassification.rateLimited,
      );
      expect(
        ReferenceResolveResponse.parse(
          request: request,
          statusCode: 503,
          json: const <String, Object?>{},
        ).classification,
        ReferenceClassification.serviceUnavailable,
      );
    });
  });
}

CapabilitySnapshot _capabilities({
  required bool referenceApi,
  bool authenticated = true,
}) => CapabilitySnapshot.fromJson(
  {
    'ocs': {
      'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
      'data': {
        'version': {
          'major': 34,
          'minor': 0,
          'micro': 1,
          'string': '34.0.1',
          'edition': '',
          'extendedSupport': false,
        },
        'capabilities': {
          'core': {'reference-api': referenceApi},
          'spreed': {
            'features': <Object?>['markdown-messages'],
          },
        },
      },
    },
  },
  context: authenticated
      ? CapabilityContext.authenticated
      : CapabilityContext.anonymous,
);

ReferenceResolveRequest _request() => ReferenceResolveRequest(
  server: ServerBase.parse('https://cloud.example.invalid'),
  reference: Uri.parse('https://docs.example.invalid/topic'),
);

Map<String, Object?> _response({
  String type = 'open-graph',
  String providerLink = 'https://docs.example.invalid/topic',
  bool accessible = true,
}) {
  final reference = _request().reference.toString();
  return {
    'ocs': {
      'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
      'data': {
        'references': <String, Object?>{
          reference: {
            'richObjectType': type,
            'richObject': {
              'id': 'provider-object',
              'name': 'Provider object',
              'link': providerLink,
            },
            'openGraphObject': {
              'id': reference,
              'name': 'Verified title',
              'description': 'Verified description',
              'thumb': null,
              'link': providerLink,
            },
            'accessible': accessible,
          },
        },
      },
    },
  };
}
