import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  BotAdminListRequest request({CapabilitySnapshot? capabilities}) =>
      BotAdminListRequest(
        accountId: AccountId.parse('account-1'),
        server: ServerBase.parse('https://cloud.example.com'),
        capabilities: capabilities ?? _capabilities(),
      );

  group('BotAdminListRequest', () {
    test('reads the server-wide bot list', () {
      expect(request().httpMethod, 'GET');
      expect(request().uri.path, endsWith('/api/v1/bot/admin'));
      expect(request().headers['OCS-APIRequest'], 'true');
    });

    test('a server without bots-v1 is never asked', () {
      expect(
        () => request(
          capabilities: _capabilities(features: const <String>{'chat-v2'}),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => request(
          capabilities: _capabilities(context: CapabilityContext.anonymous),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });

  group('decodeBotAdminListResponse', () {
    BotAdminListResponse decode(int statusCode, String body) =>
        decodeBotAdminListResponse(
          statusCode: statusCode,
          body: Uint8List.fromList(utf8.encode(body)),
        );

    test('reads the shape the server really answers with', () {
      final response = decode(200, _twoBots);

      expect(response.outcome, BotAdminOutcome.listed);
      expect(response.bots.map((bot) => bot.name), <String>[
        'Echo bot',
        'Broken bot',
      ]);
      expect(response.bots.first.state, BotState.enabled);
      expect(response.bots.last.state, BotState.disabled);
      expect(response.truncated, isFalse);
    });

    test('the webhook address never leaves the decoder, only its host', () {
      // The address is operator infrastructure and can carry a token in its
      // path or query; the screen it feeds is meant to be read out loud.
      final response = decode(200, _twoBots);

      expect(response.bots.first.urlHost, 'bots.example.invalid');
      expect(response.toString(), isNot(contains('secret-path')));
      expect(
        response.bots.first.toString(),
        isNot(contains('bots.example.invalid')),
      );
    });

    test('a failing bot carries its count, moment and bounded reason', () {
      final response = decode(200, _failingBot);
      final bot = response.bots.single;

      expect(bot.isFailing, isTrue);
      expect(bot.errorCount, 7);
      expect(bot.lastErrorAt, DateTime.utc(2026, 9, 9, 16));
      expect(bot.lastErrorMessage, startsWith('Could not reach'));
      expect(
        bot.lastErrorMessage!.length,
        lessThanOrEqualTo(maximumBotErrorCharacters + 1),
      );
    });

    test('a bot that has never failed says so instead of guessing', () {
      final bot = decode(200, _twoBots).bots.first;

      expect(bot.isFailing, isFalse);
      expect(bot.lastErrorAt, isNull);
      expect(bot.lastErrorMessage, isNull);
    });

    test('a longer list than a screen answers is cut and says so', () {
      final many = List<String>.generate(
        maximumAdminBots + 5,
        (index) => jsonEncode(<String, Object?>{
          'id': index + 1,
          'name': 'Bot $index',
          'url': 'https://bots.example.invalid/$index',
          'description': '',
          'error_count': 0,
          'last_error_date': 0,
          'last_error_message': null,
          'state': 1,
          'features': 3,
        }),
      ).join(',');
      final response = decode(200, _envelope('[$many]'));

      expect(response.bots, hasLength(maximumAdminBots));
      expect(response.truncated, isTrue);
    });

    test('an ordinary account is told it is not an administrator', () {
      // Measured: 403 with "Logged in account must be an admin".
      expect(decode(403, _envelope('[]')).outcome, BotAdminOutcome.forbidden);
    });

    test('classifies the other answers', () {
      expect(
        decode(401, _envelope('[]')).outcome,
        BotAdminOutcome.reauthenticationRequired,
      );
      expect(decode(404, _envelope('[]')).outcome, BotAdminOutcome.unsupported);
      expect(decode(429, _envelope('[]')).outcome, BotAdminOutcome.rateLimited);
      expect(
        decode(503, _envelope('[]')).outcome,
        BotAdminOutcome.serverFailure,
      );
      expect(
        () => decode(302, _envelope('[]')),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => decode(200, 'not json'),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('a bot whose app is gone decodes instead of killing the list', () {
      // Measured on Talk 22.0.17: for a bot behind an app that is not enabled
      // the endpoint substitutes state 3, an error count of one, the current
      // time and "App disabled". A decoder that stops at state 2 rejects the
      // whole answer as soon as one such bot exists, which is how an
      // administrator would lose the list of the bots that do work.
      final response = decode(200, _appBot);
      final bot = response.bots.single;

      expect(response.outcome, BotAdminOutcome.listed);
      expect(bot.state, BotState.unavailable);
      expect(bot.errorCount, 1);
      expect(bot.lastErrorMessage, 'App disabled');
      expect(bot.lastErrorAt, DateTime.utc(2026, 9, 9, 14, 49, 49));
      // All three of those are ASSIGNED by `adminListBots` over whatever was
      // stored: the count is invented, the moment is the moment of the request,
      // and the bot's real count is hidden. So this is not a failing bot.
      expect(bot.isFailing, isFalse);
      // A bot provided by an app has no webhook address, only its app id.
      expect(bot.urlHost, 'no-such-app');
    });

    test('an unknown state is refused rather than shown as something', () {
      expect(
        () => decode(
          200,
          _envelope(
            '[{"id":1,"name":"X","url":"https://h/","description":"",'
            '"error_count":0,"last_error_date":0,"last_error_message":null,'
            '"state":9,"features":3}]',
          ),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });
}

String _envelope(String data) =>
    '{"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},'
    '"data":$data}}';

/// The exact shape a Talk 22 server answered with on 9 September 2026.
final String _twoBots = _envelope(
  '['
  '{"id":1,"name":"Echo bot",'
  '"url":"https://bots.example.invalid/secret-path",'
  '"url_hash":"949e5cc22b97d3e5a8f228330773abfc40819002",'
  '"description":"Repeats what it hears","error_count":0,'
  '"last_error_date":0,"last_error_message":null,"state":1,"features":3},'
  '{"id":2,"name":"Broken bot",'
  '"url":"https://bots.example.invalid/broken",'
  '"url_hash":"6dc861c4d7d2cd1df8057183e672d1d0aae2b17b",'
  '"description":"A bot whose endpoint is gone","error_count":0,'
  '"last_error_date":0,"last_error_message":null,"state":0,"features":3}'
  ']',
);

final String _failingBot = _envelope(
  '[{"id":3,"name":"Failing bot","url":"https://bots.example.invalid/gone",'
  '"description":"","error_count":7,"last_error_date":1788969600,'
  '"last_error_message":"Could not reach the bot ${'x' * 400}",'
  '"state":1,"features":3}]',
);

/// A bot provided by an app that is not enabled, copied from the live answer.
final String _appBot = _envelope(
  '[{"id":3,"name":"App bot","url":"nextcloudapp://no-such-app/bot",'
  '"url_hash":"f389b0ebf7f44b07ae2e97eb5bca54176f4fa9ae",'
  '"description":"A bot backed by an app that is not enabled",'
  '"error_count":1,"last_error_date":1788965389,'
  '"last_error_message":"App disabled","state":3,"features":4}]',
);

CapabilitySnapshot _capabilities({
  Set<String> features = const <String>{'bots-v1'},
  CapabilityContext context = CapabilityContext.authenticated,
}) => CapabilitySnapshot.fromJson(<String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': <String, Object?>{
      'version': <String, Object?>{
        'major': 32,
        'minor': 0,
        'micro': 14,
        'string': '32.0.14',
        'edition': '',
        'extendedSupport': false,
      },
      'capabilities': <String, Object?>{
        'spreed': <String, Object?>{'features': features.toList()},
      },
    },
  },
}, context: context);
