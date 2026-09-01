import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  final accountId = AccountId.parse('account-a');
  final server = ServerBase.parse('https://cloud.example.invalid/base');
  final roomToken = ConversationToken.parse('room1234', path: r'$.roomToken');

  Uint8List ocs(Object? data, {String status = 'ok', int code = 200}) {
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'ocs': {
            'meta': {'status': status, 'statuscode': code, 'message': 'OK'},
            'data': data,
          },
        }),
      ),
    );
  }

  group('bot requests', () {
    test('bind list and mutation to account origin room and bot', () {
      final list = ListBotsRequest(
        accountId: accountId,
        server: server,
        roomToken: roomToken,
      );
      final enable = ChangeBotStateRequest(
        accountId: accountId,
        server: server,
        roomToken: roomToken,
        botId: 17,
        enable: true,
      );
      final disable = ChangeBotStateRequest(
        accountId: accountId,
        server: server,
        roomToken: roomToken,
        botId: 17,
        enable: false,
      );

      expect(
        list.uri.toString(),
        'https://cloud.example.invalid/base/ocs/v2.php/apps/spreed/api/v1/'
        'bot/room1234?format=json',
      );
      expect(enable.uri.path, endsWith('/bot/room1234/17'));
      expect(enable.httpMethod, 'POST');
      expect(disable.httpMethod, 'DELETE');
      expect(enable.accountId, accountId);
      expect(enable.server, server);
      expect(enable.roomToken, roomToken);
      expect(enable.headers['OCS-APIRequest'], 'true');
      expect(enable.toString(), isNot(contains('room1234')));
    });

    test('rejects a negative bot identifier', () {
      expect(
        () => ChangeBotStateRequest(
          accountId: accountId,
          server: server,
          roomToken: roomToken,
          botId: -1,
          enable: true,
        ),
        throwsA(
          isA<TalkProtocolException>()
              .having(
                (error) => error.code,
                'code',
                TalkProtocolErrorCode.invalidBotsRequest,
              )
              .having((error) => error.path, 'path', r'$.path.botId'),
        ),
      );
    });
  });

  group('bot responses', () {
    ListBotsRequest listRequest() => ListBotsRequest(
      accountId: accountId,
      server: server,
      roomToken: roomToken,
    );

    ChangeBotStateRequest changeRequest({bool enable = true}) =>
        ChangeBotStateRequest(
          accountId: accountId,
          server: server,
          roomToken: roomToken,
          botId: 17,
          enable: enable,
        );

    test('decodes all three upstream bot states and nullable description', () {
      final request = listRequest();
      final response = decodeListBotsResponse(
        request: request,
        statusCode: 200,
        body: ocs([
          {'id': 17, 'name': 'Assistant', 'description': 'Answers', 'state': 0},
          {'id': 18, 'name': 'Recorder', 'description': null, 'state': 1},
          {'id': 19, 'name': 'Bridge', 'description': '', 'state': 2},
        ]),
      );

      expect(response, isA<BotListSuccess>());
      final success = response as BotListSuccess;
      expect(success.request, same(request));
      expect(success.bots.map((bot) => bot.state), [
        BotState.disabled,
        BotState.enabled,
        BotState.noSetup,
      ]);
      expect(success.bots[1].description, isNull);
      expect(success.bots[0].toString(), 'TalkBot(id: 17, state: disabled)');
    });

    test('treats an omitted upstream description as null', () {
      final response =
          decodeListBotsResponse(
                request: listRequest(),
                statusCode: 200,
                body: ocs([
                  {'id': 17, 'name': 'Assistant', 'state': 0},
                ]),
              )
              as BotListSuccess;

      expect(response.bots.single.description, isNull);
    });

    test('decodes enable 201 and disable 200 as authoritative bot state', () {
      final enabled = decodeChangeBotStateResponse(
        request: changeRequest(),
        statusCode: 201,
        body: ocs({
          'id': 17,
          'name': 'Assistant',
          'description': 'Answers',
          'state': 1,
        }),
      );
      final disabled = decodeChangeBotStateResponse(
        request: changeRequest(enable: false),
        statusCode: 200,
        body: ocs({
          'id': 17,
          'name': 'Assistant',
          'description': 'Answers',
          'state': 0,
        }),
      );

      expect((enabled as BotChangeSuccess).bot.state, BotState.enabled);
      expect((disabled as BotChangeSuccess).bot.state, BotState.disabled);
    });

    test('classifies mutation refusal and shared HTTP failures', () {
      final rejected = decodeChangeBotStateResponse(
        request: changeRequest(),
        statusCode: 400,
        body: ocs({'error': 'classified'}, status: 'failure', code: 400),
      );
      expect(rejected, isA<BotChangeRejected>());
      expect((rejected as BotChangeRejected).reason, 'classified');

      final expected = <int, Matcher>{
        401: isA<BotReauthenticationRequired>(),
        403: isA<BotForbidden>(),
        404: isA<BotRoomMissing>(),
        429: isA<BotHttpFailure>(),
        503: isA<BotHttpFailure>(),
      };
      for (final entry in expected.entries) {
        final response = decodeListBotsResponse(
          request: listRequest(),
          statusCode: entry.key,
          body: entry.key == 429 || entry.key == 503
              ? Uint8List(0)
              : ocs(null, status: 'failure', code: entry.key),
        );
        expect(response, entry.value, reason: 'HTTP ${entry.key}');
      }
    });

    test('rejects malformed state duplicate ids and oversized payloads', () {
      for (final data in <Object?>[
        [
          {'id': 17, 'name': 'Assistant', 'description': null, 'state': 9},
        ],
        [
          {'id': 17, 'name': 'A', 'description': null, 'state': 0},
          {'id': 17, 'name': 'B', 'description': null, 'state': 1},
        ],
      ]) {
        expect(
          () => decodeListBotsResponse(
            request: listRequest(),
            statusCode: 200,
            body: ocs(data),
          ),
          throwsA(
            isA<TalkProtocolException>().having(
              (error) => error.code,
              'code',
              TalkProtocolErrorCode.invalidBotsResponse,
            ),
          ),
        );
      }

      expect(
        () => decodeListBotsResponse(
          request: listRequest(),
          statusCode: 200,
          body: Uint8List(botsMaximumWireBytes + 1),
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidBotsResponse,
          ),
        ),
      );
    });

    test('rejects HTTP and OCS meta contradictions', () {
      final contradictions = <void Function()>[
        () => decodeListBotsResponse(
          request: listRequest(),
          statusCode: 200,
          body: ocs(const <Object?>[], status: 'failure'),
        ),
        () => decodeListBotsResponse(
          request: listRequest(),
          statusCode: 200,
          body: ocs(const <Object?>[], code: 201),
        ),
        () => decodeChangeBotStateResponse(
          request: changeRequest(),
          statusCode: 201,
          body: ocs({
            'id': 17,
            'name': 'Assistant',
            'description': null,
            'state': 1,
          }, code: 201),
        ),
        () => decodeChangeBotStateResponse(
          request: changeRequest(),
          statusCode: 400,
          body: ocs({'error': 'bot'}),
        ),
        () => decodeListBotsResponse(
          request: listRequest(),
          statusCode: 401,
          body: ocs(null, status: 'failure', code: 403),
        ),
      ];

      for (final contradiction in contradictions) {
        expect(
          contradiction,
          throwsA(
            isA<TalkProtocolException>().having(
              (error) => error.code,
              'code',
              TalkProtocolErrorCode.invalidBotsResponse,
            ),
          ),
        );
      }
    });
  });
}
