import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

/// The wire shapes here are the ones measured against a live Nextcloud Talk
/// server on 9 September 2026; see
/// `docs/private/research/live-csv-invitations-20260909.md`.
void main() {
  group('ImportEmailInvitationsRequest', () {
    test('encodes the v4 multipart POST with the file and testRun parts', () {
      final request = _importRequest(testRun: true);

      expect(request.httpMethod, 'POST');
      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/room/'
        'rooma123/import-emails?format=json',
      );
      expect(request.formBody, isNull);
      expect(request.headers['OCS-APIRequest'], 'true');
      expect(
        request.headers['Content-Type'],
        startsWith('multipart/form-data; boundary='),
      );

      final body = utf8.decode(request.multipartBody);
      expect(
        body,
        contains(
          'Content-Disposition: form-data; name="file"; '
          'filename="invitations.csv"',
        ),
      );
      expect(body, contains('Content-Type: text/csv'));
      expect(body, contains(_csvText));
      expect(
        body,
        contains('Content-Disposition: form-data; name="testRun"\r\n\r\n1'),
      );
      expect(body, endsWith('--\r\n'));
    });

    test('a real send differs from a preview only in the testRun field', () {
      expect(
        utf8.decode(_importRequest(testRun: false).multipartBody),
        contains('name="testRun"\r\n\r\n0'),
      );
    });

    test('requires an authenticated email-csv-import capability', () {
      for (final capabilities in <CapabilitySnapshot>[
        _capabilities(features: const <Object?>[]),
        _capabilities(features: const <Object?>['clear-history']),
        _capabilities(context: CapabilityContext.anonymous),
      ]) {
        expect(
          () => _importRequest(testRun: true, capabilities: capabilities),
          _throwsRequestFailure,
        );
      }
    });

    test('bounds the upload and refuses an empty file', () {
      expect(
        () => _importRequest(testRun: true, csvBytes: const <int>[]),
        _throwsRequestFailure,
      );
      expect(
        () => _importRequest(
          testRun: true,
          csvBytes: List<int>.filled(emailInvitationCsvMaximumBytes + 1, 0x61),
        ),
        _throwsRequestFailure,
      );
      // One byte under the bound is still accepted, so the limit is the only
      // thing being tested here and not an off-by-one refusal.
      expect(
        _importRequest(
          testRun: true,
          csvBytes: List<int>.filled(emailInvitationCsvMaximumBytes, 0x61),
        ).csvBytes,
        hasLength(emailInvitationCsvMaximumBytes),
      );
    });

    test('refuses a file name that could break out of the part header', () {
      for (final name in <String>[
        '',
        'a/b.csv',
        r'a\b.csv',
        'a".csv',
        'a\nb.csv',
      ]) {
        expect(
          () => _importRequest(testRun: true, fileName: name),
          _throwsRequestFailure,
        );
      }
    });

    test('renders neither the addresses nor the file name', () {
      final rendered = _importRequest(testRun: true).toString();
      expect(rendered, isNot(contains('example.org')));
      expect(rendered, isNot(contains('invitations.csv')));
    });
  });

  group('decodeImportEmailInvitationsResponse', () {
    test('reads a preview as counts with nothing sent', () {
      final response = decodeImportEmailInvitationsResponse(
        request: _importRequest(testRun: true),
        statusCode: 200,
        body: _ocsBody(
          statusCode: 200,
          data: const {'invites': 2, 'duplicates': 0},
        ),
      );

      expect(response, isA<ImportEmailInvitationsSuccess>());
      final success = response as ImportEmailInvitationsSuccess;
      expect(success.invites, 2);
      expect(success.duplicates, 0);
      expect(success.invitationsSent, isFalse);
      expect(success.roomType, isNull);
    });

    test('reads a real import as sent, carrying the room type', () {
      final response =
          decodeImportEmailInvitationsResponse(
                request: _importRequest(testRun: false),
                statusCode: 200,
                body: _ocsBody(
                  statusCode: 200,
                  data: const {'invites': 2, 'duplicates': 0, 'type': 3},
                ),
              )
              as ImportEmailInvitationsSuccess;

      expect(response.invitationsSent, isTrue);
      expect(response.roomType, 3);
      expect(response.invites, 2);
    });

    test('a preview that reports a room type is refused', () {
      // The server signals a real send by echoing `type`. If it ever did that
      // for a preview it would mean invitations went out, and reporting
      // "nothing was sent" would be a lie.
      expect(
        () => decodeImportEmailInvitationsResponse(
          request: _importRequest(testRun: true),
          statusCode: 200,
          body: _ocsBody(
            statusCode: 200,
            data: const {'invites': 1, 'duplicates': 0, 'type': 3},
          ),
        ),
        _throwsResponseFailure,
      );
    });

    test('a real import that reports no room type is refused', () {
      expect(
        () => decodeImportEmailInvitationsResponse(
          request: _importRequest(testRun: false),
          statusCode: 200,
          body: _ocsBody(
            statusCode: 200,
            data: const {'invites': 1, 'duplicates': 0},
          ),
        ),
        _throwsResponseFailure,
      );
    });

    test('classifies invalid rows with their 1-based line numbers', () {
      final response =
          decodeImportEmailInvitationsResponse(
                request: _importRequest(testRun: true),
                statusCode: 400,
                body: _ocsBody(
                  status: 'failure',
                  statusCode: 400,
                  data: const {
                    'error': 'Following lines are invalid: 2, 5',
                    'message': 'Following lines are invalid: 2, 5',
                    'invites': 2,
                    'duplicates': 1,
                    'invalid': 2,
                    'invalidLines': [2, 5],
                  },
                ),
              )
              as ImportEmailInvitationsInvalidRows;

      expect(response.invalid, 2);
      expect(response.invalidLines, <int>[2, 5]);
      expect(response.invites, 2);
      expect(response.duplicates, 1);
    });

    test('caps a pathological list of invalid lines', () {
      final response =
          decodeImportEmailInvitationsResponse(
                request: _importRequest(testRun: true),
                statusCode: 400,
                body: _ocsBody(
                  status: 'failure',
                  statusCode: 400,
                  data: {
                    'invalid': 5000,
                    'invalidLines': List<int>.generate(
                      5000,
                      (index) => index + 2,
                    ),
                  },
                ),
              )
              as ImportEmailInvitationsInvalidRows;

      expect(response.invalidLines, hasLength(emailInvitationInvalidLineLimit));
      expect(response.invalidLines.first, 2);
    });

    test('classifies a refused file and keeps the server explanation', () {
      final response =
          decodeImportEmailInvitationsResponse(
                request: _importRequest(testRun: true),
                statusCode: 400,
                body: _ocsBody(
                  status: 'failure',
                  statusCode: 400,
                  data: const {
                    'error': 'Missing "email" field in header line',
                    'message': 'Missing "email" field in header line',
                  },
                ),
              )
              as ImportEmailInvitationsRejected;

      expect(response.message, 'Missing "email" field in header line');
    });

    test('classifies auth, role, missing room and transient failures', () {
      final request = _importRequest(testRun: true);
      final envelopes = <int, Matcher>{
        401: isA<ImportEmailInvitationsReauthenticationRequired>(),
        403: isA<ImportEmailInvitationsForbidden>(),
        404: isA<ImportEmailInvitationsRoomMissing>(),
      };
      for (final entry in envelopes.entries) {
        expect(
          decodeImportEmailInvitationsResponse(
            request: request,
            statusCode: entry.key,
            body: _ocsBody(
              status: 'failure',
              statusCode: entry.key,
              data: const <Object?>[],
            ),
          ),
          entry.value,
        );
      }
      for (final statusCode in <int>[429, 503]) {
        final response = decodeImportEmailInvitationsResponse(
          request: request,
          statusCode: statusCode,
          body: Uint8List(0),
        );
        expect(response, isA<ImportEmailInvitationsHttpFailure>());
        expect(response.statusCode, statusCode);
      }
    });
  });

  group('ResendEmailInvitationsRequest', () {
    test('encodes the all-attendees POST without a body', () {
      final request = _resendRequest();

      expect(request.httpMethod, 'POST');
      expect(request.isAllAttendees, isTrue);
      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/room/'
        'rooma123/participants/resend-invitations?format=json',
      );
      expect(request.formBody, isNull);
    });

    test('encodes one attendee in the form body', () {
      final request = _resendRequest(attendeeId: 196);

      expect(request.isAllAttendees, isFalse);
      expect(request.formBody, {'attendeeId': '196'});
    });

    test('refuses an attendee id the server could never have', () {
      for (final attendeeId in <int>[0, -1]) {
        expect(
          () => _resendRequest(attendeeId: attendeeId),
          _throwsRequestFailure,
        );
      }
    });
  });

  group('decodeResendEmailInvitationsResponse', () {
    test('accepts the 200 with a null payload', () {
      expect(
        decodeResendEmailInvitationsResponse(
          request: _resendRequest(),
          statusCode: 200,
          body: _ocsBody(statusCode: 200, data: null),
        ),
        isA<ResendEmailInvitationsSuccess>(),
      );
    });

    test('classifies auth, role, missing target and transient failures', () {
      final request = _resendRequest(attendeeId: 196);
      final envelopes = <int, Matcher>{
        401: isA<ResendEmailInvitationsReauthenticationRequired>(),
        403: isA<ResendEmailInvitationsForbidden>(),
        404: isA<ResendEmailInvitationsTargetMissing>(),
      };
      for (final entry in envelopes.entries) {
        expect(
          decodeResendEmailInvitationsResponse(
            request: request,
            statusCode: entry.key,
            body: _ocsBody(
              status: 'failure',
              statusCode: entry.key,
              data: null,
            ),
          ),
          entry.value,
        );
      }
      for (final statusCode in <int>[429, 503]) {
        final response = decodeResendEmailInvitationsResponse(
          request: request,
          statusCode: statusCode,
          body: Uint8List(0),
        );
        expect(response, isA<ResendEmailInvitationsHttpFailure>());
        expect(response.statusCode, statusCode);
      }
    });

    test('refuses an undocumented status', () {
      expect(
        () => decodeResendEmailInvitationsResponse(
          request: _resendRequest(),
          statusCode: 418,
          body: Uint8List(0),
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

const String _csvText =
    'email,name\n'
    'up08.alpha@example.org,Alpha Tester\n'
    'up08.beta@example.org,Beta Tester\n';

final Matcher _throwsRequestFailure = throwsA(
  isA<TalkProtocolException>().having(
    (error) => error.code,
    'code',
    TalkProtocolErrorCode.invalidRoomSettingsRequest,
  ),
);

final Matcher _throwsResponseFailure = throwsA(
  isA<TalkProtocolException>().having(
    (error) => error.code,
    'code',
    TalkProtocolErrorCode.invalidRoomSettingsResponse,
  ),
);

ImportEmailInvitationsRequest _importRequest({
  required bool testRun,
  CapabilitySnapshot? capabilities,
  List<int>? csvBytes,
  String fileName = 'invitations.csv',
}) {
  return ImportEmailInvitationsRequest(
    accountId: AccountId.parse('account-a'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    csvBytes: csvBytes ?? utf8.encode(_csvText),
    fileName: fileName,
    testRun: testRun,
    capabilities: capabilities ?? _capabilities(),
  );
}

ResendEmailInvitationsRequest _resendRequest({int? attendeeId}) {
  return ResendEmailInvitationsRequest(
    accountId: AccountId.parse('account-a'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    attendeeId: attendeeId,
  );
}

CapabilitySnapshot _capabilities({
  CapabilityContext context = CapabilityContext.authenticated,
  Object? features = const <Object?>['email-csv-import'],
}) {
  return CapabilitySnapshot.fromJson({
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
          'spreed': {'features': features},
        },
      },
    },
  }, context: context);
}

Uint8List _ocsBody({
  String status = 'ok',
  required int statusCode,
  required Object? data,
}) {
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'ocs': {
          'meta': {
            'status': status,
            'statuscode': statusCode,
            'message': status,
          },
          'data': data,
        },
      }),
    ),
  );
}
