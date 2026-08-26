import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('ClearRoomHistoryRequest', () {
    test('encodes the capability-gated v1 DELETE without a body', () {
      final request = _request();

      expect(request.httpMethod, 'DELETE');
      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v1/chat/'
        'rooma123?format=json',
      );
      expect(request.formBody, isNull);
      expect(request.headers['OCS-APIRequest'], 'true');
      expect(request.toString(), isNot(contains('rooma123')));
    });

    test('requires an authenticated clear-history capability', () {
      for (final capabilities in <CapabilitySnapshot>[
        _capabilities(features: const <Object?>[]),
        _capabilities(context: CapabilityContext.anonymous),
      ]) {
        expect(
          () => _request(capabilities: capabilities),
          throwsA(
            isA<TalkProtocolException>().having(
              (error) => error.code,
              'code',
              TalkProtocolErrorCode.invalidRoomSettingsRequest,
            ),
          ),
        );
      }
    });
  });

  group('decodeClearRoomHistoryResponse', () {
    test('accepts 200 and preserves the authoritative system message', () {
      final response = decodeClearRoomHistoryResponse(
        request: _request(),
        statusCode: 200,
        body: _ocsBody(statusCode: 200, data: _historyClearedMessage()),
        headers: ChatResponseHeaders.fromMap({'X-Chat-Last-Common-Read': '41'}),
      );

      expect(response, isA<ClearRoomHistorySuccess>());
      final success = response as ClearRoomHistorySuccess;
      expect(success.externalCopiesMayRemain, isFalse);
      expect(success.systemMessage.systemMessage, 'history_cleared');
      expect(success.systemMessage.messageId, 42);
      expect(success.lastCommonRead?.value, '41');
    });

    test('treats documented 202 as success with an external-copy warning', () {
      final response = decodeClearRoomHistoryResponse(
        request: _request(),
        statusCode: 202,
        body: _ocsBody(statusCode: 202, data: _historyClearedMessage()),
      );

      expect(response, isA<ClearRoomHistorySuccess>());
      expect(
        (response as ClearRoomHistorySuccess).externalCopiesMayRemain,
        isTrue,
      );
    });

    test('rejects a wrong room, system type or threaded replacement', () {
      for (final replacement in <Map<String, Object?>>[
        _historyClearedMessage()..['token'] = 'other123',
        _historyClearedMessage()..['systemMessage'] = 'room_renamed',
        _historyClearedMessage()..['threadId'] = 42,
      ]) {
        expect(
          () => decodeClearRoomHistoryResponse(
            request: _request(),
            statusCode: 200,
            body: _ocsBody(statusCode: 200, data: replacement),
          ),
          throwsA(isA<TalkProtocolException>()),
        );
      }
    });

    test('rejects malformed common-read headers and mismatched OCS status', () {
      expect(
        () => decodeClearRoomHistoryResponse(
          request: _request(),
          statusCode: 200,
          body: _ocsBody(statusCode: 200, data: _historyClearedMessage()),
          headers: ChatResponseHeaders.fromMap({
            'X-Chat-Last-Common-Read': '-1',
          }),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => decodeClearRoomHistoryResponse(
          request: _request(),
          statusCode: 200,
          body: _ocsBody(statusCode: 202, data: _historyClearedMessage()),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test(
      'classifies auth, permission, missing room and transient failures',
      () {
        final request = _request();
        final envelopes = <int, Matcher>{
          401: isA<ClearRoomHistoryReauthenticationRequired>(),
          403: isA<ClearRoomHistoryForbidden>(),
          404: isA<ClearRoomHistoryRoomMissing>(),
        };
        for (final entry in envelopes.entries) {
          expect(
            decodeClearRoomHistoryResponse(
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
          final response = decodeClearRoomHistoryResponse(
            request: request,
            statusCode: statusCode,
            body: Uint8List(0),
          );
          expect(response, isA<ClearRoomHistoryHttpFailure>());
          expect(response.statusCode, statusCode);
        }
      },
    );
  });
}

ClearRoomHistoryRequest _request({CapabilitySnapshot? capabilities}) {
  return ClearRoomHistoryRequest(
    accountId: AccountId.parse('account-a'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    capabilities: capabilities ?? _capabilities(),
  );
}

CapabilitySnapshot _capabilities({
  CapabilityContext context = CapabilityContext.authenticated,
  Object? features = const <Object?>['clear-history'],
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

Map<String, Object?> _historyClearedMessage() => <String, Object?>{
  'id': 42,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'moderator',
  'actorDisplayName': 'Moderator',
  'timestamp': 1787695200,
  'systemMessage': 'history_cleared',
  'messageType': 'system',
  'isReplyable': false,
  'referenceId': '',
  'message': 'You cleared the history of the conversation',
  'messageParameters': <String, Object?>{},
};
