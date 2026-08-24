import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/features/chat/composer/giphy.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  final server = ServerBase.parse('https://cloud.example.invalid/nextcloud');
  const authorization = GiphyAuthorization(
    loginName: 'fixture-user',
    appPassword: 'fixture-password',
  );

  group('GiphyAvailability', () {
    test('requires enabled and configured booleans', () {
      expect(
        GiphyAvailability.fromCapabilities(
          _capabilities(<String, Object?>{'enabled': true, 'configured': true}),
        ).isAvailable,
        isTrue,
      );

      for (final malformed in <Object?>[
        null,
        <String, Object?>{'enabled': true},
        <String, Object?>{'enabled': true, 'configured': false},
        <String, Object?>{'enabled': 1, 'configured': true},
        'enabled',
      ]) {
        expect(
          GiphyAvailability.fromCapabilities(
            _capabilities(malformed, includeIntegration: malformed != null),
          ).isAvailable,
          isFalse,
        );
      }
    });
  });

  group('HttpGiphyRepository', () {
    test(
      'uses the exact authenticated same-origin trending endpoint',
      () async {
        late http.Request observed;
        final repository = HttpGiphyRepository(
          server: server,
          authorization: authorization,
          client: MockClient((request) async {
            observed = request;
            return http.Response(_validResponse(), 200);
          }),
        );
        addTearDown(repository.close);

        final page = await repository.trending(cursor: 4, limit: 12);

        expect(page.entries, hasLength(1));
        expect(page.cursor, 5);
        expect(observed.method, 'GET');
        expect(
          observed.url.path,
          '/nextcloud/ocs/v2.php/apps/integration_giphy/api/v1/gifs/trending',
        );
        expect(observed.url.queryParameters, <String, String>{
          'cursor': '4',
          'limit': '12',
          'format': 'json',
        });
        expect(observed.headers['OCS-APIRequest'], 'true');
        expect(observed.headers['Authorization'], startsWith('Basic '));
        expect(observed.followRedirects, isFalse);
        expect(observed.maxRedirects, 0);
      },
    );

    test('sends search term only to the server integration', () async {
      late http.Request observed;
      final repository = HttpGiphyRepository(
        server: server,
        authorization: authorization,
        client: MockClient((request) async {
          observed = request;
          return http.Response(_validResponse(), 200);
        }),
      );
      addTearDown(repository.close);

      await repository.search(term: 'waving cat', cursor: 0, limit: 10);

      expect(
        observed.url.path,
        '/nextcloud/ocs/v2.php/apps/integration_giphy/api/v1/gifs/search',
      );
      expect(observed.url.queryParameters['term'], 'waving cat');
      expect(observed.url.host, server.uri.host);
    });

    test('rejects foreign thumbnails and unsafe resource links', () async {
      for (final entry in <Map<String, Object?>>[
        _entry(thumbnailUrl: 'https://images.example.invalid/a.gif'),
        _entry(resourceUrl: 'http://giphy.com/gifs/wave-123'),
        _entry(resourceUrl: 'https://giphy.example.invalid/gifs/wave-123'),
      ]) {
        final repository = HttpGiphyRepository(
          server: server,
          authorization: authorization,
          client: MockClient(
            (_) async => http.Response(_responseWithEntry(entry), 200),
          ),
        );

        await expectLater(
          repository.trending(cursor: 0, limit: 10),
          throwsA(_giphyError(GiphyError.invalidResponse)),
        );
        repository.close();
      }
    });

    test(
      'classifies integration 401 without treating it as account auth',
      () async {
        final repository = HttpGiphyRepository(
          server: server,
          authorization: authorization,
          client: MockClient((_) async => http.Response('', 401)),
        );
        addTearDown(repository.close);

        await expectLater(
          repository.trending(cursor: 0, limit: 10),
          throwsA(_giphyError(GiphyError.integrationUnavailable)),
        );
      },
    );

    test(
      'classifies rate limits, server failures, malformed and oversized bodies',
      () async {
        final cases = <(http.Client, GiphyError)>[
          (
            MockClient((_) async => http.Response('', 429)),
            GiphyError.rateLimited,
          ),
          (
            MockClient((_) async => http.Response('', 503)),
            GiphyError.unexpectedStatus,
          ),
          (
            MockClient((_) async => http.Response('not-json', 200)),
            GiphyError.invalidResponse,
          ),
          (_OversizedClient(), GiphyError.responseTooLarge),
        ];

        for (final testCase in cases) {
          final repository = HttpGiphyRepository(
            server: server,
            authorization: authorization,
            client: testCase.$1,
            maximumResponseBytes: 64,
          );
          await expectLater(
            repository.trending(cursor: 0, limit: 10),
            throwsA(_giphyError(testCase.$2)),
          );
          repository.close();
        }
      },
    );

    test('times out a stalled server request', () async {
      final repository = HttpGiphyRepository(
        server: server,
        authorization: authorization,
        client: MockClient((_) async {
          await Completer<void>().future;
          return http.Response('', 200);
        }),
        requestTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(repository.close);

      await expectLater(
        repository.trending(cursor: 0, limit: 10),
        throwsA(_giphyError(GiphyError.timeout)),
      );
    });

    test('maps an explicit abort trigger to cancellation', () async {
      final abort = Completer<void>();
      final repository = HttpGiphyRepository(
        server: server,
        authorization: authorization,
        client: MockClient.streaming((request, _) async {
          final abortable = request as http.AbortableRequest;
          await abortable.abortTrigger;
          throw http.RequestAbortedException(request.url);
        }),
      );
      addTearDown(repository.close);

      final pending = repository.trending(
        cursor: 0,
        limit: 10,
        abortTrigger: abort.future,
      );
      abort.complete();

      await expectLater(pending, throwsA(_giphyError(GiphyError.cancelled)));
    });

    test('rejects an OCS failure envelope', () async {
      final payload = jsonDecode(_validResponse()) as Map<String, Object?>;
      final ocs = payload['ocs']! as Map<String, Object?>;
      final meta = ocs['meta']! as Map<String, Object?>;
      meta['status'] = 'failure';
      meta['statuscode'] = 997;
      final repository = HttpGiphyRepository(
        server: server,
        authorization: authorization,
        client: MockClient(
          (_) async => http.Response(jsonEncode(payload), 200),
        ),
      );
      addTearDown(repository.close);

      await expectLater(
        repository.trending(cursor: 0, limit: 10),
        throwsA(_giphyError(GiphyError.invalidResponse)),
      );
    });
  });

  test('authorization never exposes credentials through toString', () {
    final rendered = authorization.toString();
    expect(rendered, isNot(contains('fixture-user')));
    expect(rendered, isNot(contains('fixture-password')));
  });

  test(
    'controller suppresses stale search results and inserts selected URL',
    () async {
      final repository = _ControlledRepository();
      final controller = GiphyController(repository: repository);
      addTearDown(controller.dispose);

      final first = controller.search('old');
      final second = controller.search('new');
      repository.complete(
        'new',
        GiphyPage(entries: <GiphyEntry>[_giphyEntry('new')], cursor: 1),
      );
      await second;
      repository.complete(
        'old',
        GiphyPage(entries: <GiphyEntry>[_giphyEntry('old')], cursor: 1),
      );
      await first;

      expect(controller.entries.single.title, 'new');
      final draft = TextEditingController(text: 'hello');
      addTearDown(draft.dispose);
      expect(
        controller.insertSelection(draft, controller.entries.single),
        isTrue,
      );
      expect(draft.text, 'hello https://giphy.com/gifs/new ');
    },
  );
}

CapabilitySnapshot _capabilities(
  Object? integration, {
  bool includeIntegration = true,
}) {
  final payload = capabilitiesJson();
  final ocs = payload['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  final capabilities = data['capabilities']! as Map<String, Object?>;
  if (includeIntegration) {
    capabilities['integration_giphy'] = integration;
  }
  return CapabilitySnapshot.fromJson(
    payload,
    context: CapabilityContext.authenticated,
  );
}

Map<String, Object?> _entry({
  String thumbnailUrl =
      'https://cloud.example.invalid/nextcloud/apps/integration_giphy/gif/abc',
  String resourceUrl = 'https://giphy.com/gifs/wave-123',
}) => <String, Object?>{
  'thumbnailUrl': thumbnailUrl,
  'title': 'Wave',
  'subline': 'Fixture author',
  'resourceUrl': resourceUrl,
};

String _validResponse() => _responseWithEntry(_entry());

String _responseWithEntry(Map<String, Object?> entry) =>
    jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': 'ok',
          'statuscode': 200,
          'message': 'OK',
        },
        'data': <String, Object?>{
          'entries': <Object?>[entry],
          'cursor': 5,
        },
      },
    });

Matcher _giphyError(GiphyError error) => isA<GiphyException>().having(
  (exception) => exception.error,
  'error',
  error,
);

GiphyEntry _giphyEntry(String title) => GiphyEntry(
  thumbnailUrl: Uri.parse(
    'https://cloud.example.invalid/nextcloud/apps/integration_giphy/gif/$title',
  ),
  title: title,
  subline: '',
  resourceUrl: Uri.parse('https://giphy.com/gifs/$title'),
);

final class _OversizedClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.value(List<int>.filled(65, 0x20)),
      200,
      contentLength: 65,
    );
  }
}

final class _ControlledRepository implements GiphyRepository {
  final Map<String, Completer<GiphyPage>> _searches = {};

  @override
  Future<GiphyPage> search({
    required String term,
    required int cursor,
    required int limit,
    Future<void>? abortTrigger,
  }) {
    return (_searches[term] = Completer<GiphyPage>()).future;
  }

  @override
  Future<GiphyPage> trending({
    required int cursor,
    required int limit,
    Future<void>? abortTrigger,
  }) async => GiphyPage(entries: const <GiphyEntry>[], cursor: 0);

  void complete(String term, GiphyPage page) => _searches[term]!.complete(page);
}
