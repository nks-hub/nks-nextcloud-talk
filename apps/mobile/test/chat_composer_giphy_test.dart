import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/composer/giphy.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  final server = ServerBase.parse('https://cloud.example.invalid/nextcloud');
  const authorization = GiphyAuthorization(
    loginName: 'fixture-user',
    appPassword: 'fixture-password',
  );

  group('GiphyAvailability', () {
    test('distinguishes available, unavailable and unknown states', () {
      expect(
        GiphyAvailability.fromCapabilities(
          _capabilities(<String, Object?>{'enabled': true, 'configured': true}),
        ).state,
        GiphyAvailabilityState.available,
      );

      for (final unavailable in <Object?>[
        <String, Object?>{'enabled': true},
        <String, Object?>{'enabled': true, 'configured': false},
        <String, Object?>{'enabled': false, 'configured': true},
        <String, Object?>{'enabled': 1, 'configured': true},
        'enabled',
      ]) {
        expect(
          GiphyAvailability.fromCapabilities(_capabilities(unavailable)).state,
          GiphyAvailabilityState.unavailable,
        );
      }

      expect(
        GiphyAvailability.fromCapabilities(
          _capabilities(null, includeIntegration: false),
        ).state,
        GiphyAvailabilityState.unknown,
      );
    });
  });

  group('giphyRepositoryProvider', () {
    test(
      'probes a missing capability and reuses the valid first page once',
      () async {
        var endpointRequests = 0;
        final harness = await _GiphyProviderHarness.create(
          integration: null,
          includeIntegration: false,
          giphyClient: MockClient((_) async {
            endpointRequests++;
            return http.Response(_validResponse(), 200);
          }),
        );
        addTearDown(harness.close);

        final repository = await harness.readRepository();

        expect(repository, isNotNull);
        expect(endpointRequests, 1);
        final page = await repository!.trending(cursor: 0, limit: 20);
        expect(page.entries, hasLength(1));
        expect(endpointRequests, 1);
        await repository.trending(cursor: 0, limit: 20);
        expect(endpointRequests, 2);
      },
    );

    test('does not probe an explicitly unavailable integration', () async {
      var endpointRequests = 0;
      final harness = await _GiphyProviderHarness.create(
        integration: <String, Object?>{'enabled': true, 'configured': false},
        giphyClient: MockClient((_) async {
          endpointRequests++;
          return http.Response(_validResponse(), 200);
        }),
      );
      addTearDown(harness.close);

      expect(await harness.readRepository(), isNull);
      expect(endpointRequests, 0);
    });

    test('does not probe a present malformed capability', () async {
      var endpointRequests = 0;
      final harness = await _GiphyProviderHarness.create(
        integration: <String, Object?>{'enabled': 'yes', 'configured': true},
        giphyClient: MockClient((_) async {
          endpointRequests++;
          return http.Response(_validResponse(), 200);
        }),
      );
      addTearDown(harness.close);

      expect(await harness.readRepository(), isNull);
      expect(endpointRequests, 0);
    });

    for (final statusCode in <int>[401, 404]) {
      test(
        'maps an unknown integration HTTP $statusCode to unavailable',
        () async {
          final harness = await _GiphyProviderHarness.create(
            integration: null,
            includeIntegration: false,
            giphyClient: MockClient(
              (_) async => http.Response('unavailable', statusCode),
            ),
          );
          addTearDown(harness.close);

          expect(await harness.readRepository(), isNull);
        },
      );
    }

    test('keeps an unknown integration rate limit retryable', () async {
      final harness = await _GiphyProviderHarness.create(
        integration: null,
        includeIntegration: false,
        giphyClient: MockClient((_) async => http.Response('limited', 429)),
      );
      addTearDown(harness.close);

      await expectLater(
        harness.readRepository(),
        throwsA(_giphyError(GiphyError.rateLimited)),
      );
    });

    test('keeps an unknown integration network failure retryable', () async {
      final harness = await _GiphyProviderHarness.create(
        integration: null,
        includeIntegration: false,
        giphyClient: MockClient((request) async {
          throw http.ClientException('fixture network failure', request.url);
        }),
      );
      addTearDown(harness.close);

      await expectLater(
        harness.readRepository(),
        throwsA(_giphyError(GiphyError.network)),
      );
    });

    test('keeps an unknown integration timeout retryable', () async {
      final harness = await _GiphyProviderHarness.create(
        integration: null,
        includeIntegration: false,
        giphyClient: MockClient((_) async {
          await Completer<void>().future;
          return http.Response('', 200);
        }),
        requestTimeout: const Duration(milliseconds: 10),
      );
      addTearDown(harness.close);

      await expectLater(
        harness.readRepository(),
        throwsA(_giphyError(GiphyError.timeout)),
      );
    });

    test('requires a valid OCS envelope for a successful probe', () async {
      final harness = await _GiphyProviderHarness.create(
        integration: null,
        includeIntegration: false,
        giphyClient: MockClient(
          (_) async => http.Response('{"entries":[]}', 200),
        ),
      );
      addTearDown(harness.close);

      await expectLater(
        harness.readRepository(),
        throwsA(_giphyError(GiphyError.invalidResponse)),
      );
    });

    test(
      'does not create a repository after disposal during capabilities',
      () async {
        final requestStarted = Completer<void>();
        final capabilitiesResponse = Completer<http.Response>();
        final harness = await _GiphyProviderHarness.create(
          integration: null,
          includeIntegration: false,
          capabilitiesClient: MockClient((_) {
            requestStarted.complete();
            return capabilitiesResponse.future;
          }),
          giphyClient: MockClient((_) async {
            return http.Response(_validResponse(), 200);
          }),
        );
        addTearDown(harness.close);

        final pending = harness.readRepository();
        await requestStarted.future;
        harness.disposeProviders();
        capabilitiesResponse.complete(
          http.Response(
            jsonEncode(_capabilitiesPayload(null, includeIntegration: false)),
            200,
          ),
        );

        await expectLater(pending, throwsA(_giphyError(GiphyError.cancelled)));
        expect(harness.factoryInvocations, 0);
      },
    );
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

    test(
      'loads attribution from the exact authenticated server path',
      () async {
        late http.Request observed;
        final repository = HttpGiphyRepository(
          server: server,
          authorization: authorization,
          client: MockClient((request) async {
            observed = request;
            return http.Response.bytes(
              _validGif,
              200,
              headers: const <String, String>{'content-type': 'image/gif'},
            );
          }),
        );
        addTearDown(repository.close);

        final asset = await repository.loadAttributionAsset();

        expect(asset.body, _validGif);
        expect(asset.contentType, 'image/gif');
        expect(observed.method, 'GET');
        expect(
          observed.url,
          Uri.parse(
            'https://cloud.example.invalid/nextcloud/apps/'
            'integration_giphy/img/powered-by-giphy.gif',
          ),
        );
        expect(observed.headers['Authorization'], startsWith('Basic '));
        expect(observed.headers['Accept'], 'image/gif');
        expect(observed.followRedirects, isFalse);
        expect(observed.maxRedirects, 0);
      },
    );

    test('rejects attribution redirects and non-success statuses', () async {
      for (final expectation in <int, GiphyError>{
        302: GiphyError.unexpectedStatus,
        404: GiphyError.integrationUnavailable,
        503: GiphyError.unexpectedStatus,
      }.entries) {
        final repository = HttpGiphyRepository(
          server: server,
          authorization: authorization,
          client: MockClient((_) async => http.Response('', expectation.key)),
        );

        await expectLater(
          repository.loadAttributionAsset(),
          throwsA(_giphyError(expectation.value)),
        );
        repository.close();
      }
    });

    test('rejects oversized attribution and cancels its body', () async {
      final client = _AbortAwareBodyClient(
        statusCode: 200,
        contentLength: 65,
        headers: const <String, String>{'content-type': 'image/gif'},
      );
      final repository = HttpGiphyRepository(
        server: server,
        authorization: authorization,
        client: client,
        maximumAttributionBytes: 64,
      );
      addTearDown(repository.close);

      await expectLater(
        repository.loadAttributionAsset(),
        throwsA(_giphyError(GiphyError.responseTooLarge)),
      );
      expect(client.requestAborted, isFalse);
      expect(client.subscriptionCancelled, isTrue);
    });

    test('requires a GIF content type and signature for attribution', () async {
      for (final response in <http.Response>[
        http.Response.bytes(
          _validGif,
          200,
          headers: const <String, String>{'content-type': 'image/png'},
        ),
        http.Response.bytes(
          utf8.encode('not-a-gif'),
          200,
          headers: const <String, String>{'content-type': 'image/gif'},
        ),
      ]) {
        final repository = HttpGiphyRepository(
          server: server,
          authorization: authorization,
          client: MockClient((_) async => response),
        );

        await expectLater(
          repository.loadAttributionAsset(),
          throwsA(_giphyError(GiphyError.invalidResponse)),
        );
        repository.close();
      }
    });

    test(
      'attribution deadline physically aborts a stalled send',
      () async {
        final client = _DeadlineSendClient();
        final repository = HttpGiphyRepository(
          server: server,
          authorization: authorization,
          client: client,
          requestTimeout: const Duration(milliseconds: 10),
        );
        addTearDown(repository.close);

        await expectLater(
          repository.loadAttributionAsset(),
          throwsA(_giphyError(GiphyError.timeout)),
        );
        expect(client.wasAborted, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 1)),
    );

    test('maps an explicit attribution abort to cancellation', () async {
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

      final pending = repository.loadAttributionAsset(
        abortTrigger: abort.future,
      );
      abort.complete();

      await expectLater(pending, throwsA(_giphyError(GiphyError.cancelled)));
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

    test(
      'deadline physically aborts a stalled send',
      () async {
        final client = _DeadlineSendClient();
        final repository = HttpGiphyRepository(
          server: server,
          authorization: authorization,
          client: client,
          requestTimeout: const Duration(milliseconds: 10),
        );
        addTearDown(repository.close);

        await expectLater(
          repository.trending(cursor: 0, limit: 10),
          throwsA(_giphyError(GiphyError.timeout)),
        );
        expect(client.wasAborted, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 1)),
    );

    test(
      'deadline aborts and cancels a stalled success body',
      () async {
        final client = _AbortAwareBodyClient(statusCode: 200);
        final repository = HttpGiphyRepository(
          server: server,
          authorization: authorization,
          client: client,
          requestTimeout: const Duration(milliseconds: 10),
        );
        addTearDown(repository.close);

        await expectLater(
          repository.trending(cursor: 0, limit: 10),
          throwsA(_giphyError(GiphyError.timeout)),
        );
        expect(client.requestAborted, isTrue);
        expect(client.subscriptionCancelled, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 1)),
    );

    test(
      'bounds cancellation of a stalled error response body',
      () async {
        final client = _StalledBodyClient(
          statusCode: 503,
          stallCancellation: true,
        );
        final repository = HttpGiphyRepository(
          server: server,
          authorization: authorization,
          client: client,
          requestTimeout: const Duration(milliseconds: 10),
        );
        addTearDown(repository.close);

        await expectLater(
          repository.trending(cursor: 0, limit: 10),
          throwsA(_giphyError(GiphyError.timeout)),
        );
        expect(client.wasCancelled, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 1)),
    );

    test(
      'deadline aborts and cancels a stalled thumbnail error body',
      () async {
        final client = _AbortAwareBodyClient(statusCode: 503);
        final repository = HttpGiphyRepository(
          server: server,
          authorization: authorization,
          client: client,
          requestTimeout: const Duration(milliseconds: 10),
        );
        addTearDown(repository.close);

        await expectLater(
          repository.loadThumbnail(_giphyEntry('stalled-thumbnail')),
          throwsA(_giphyError(GiphyError.timeout)),
        );
        expect(client.requestAborted, isTrue);
        expect(client.subscriptionCancelled, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 1)),
    );

    test('cancels an oversized thumbnail response subscription', () async {
      final client = _AbortAwareBodyClient(
        statusCode: 200,
        contentLength: 65,
        headers: const <String, String>{'content-type': 'image/gif'},
      );
      final repository = HttpGiphyRepository(
        server: server,
        authorization: authorization,
        client: client,
        maximumThumbnailBytes: 64,
      );
      addTearDown(repository.close);

      await expectLater(
        repository.loadThumbnail(_giphyEntry('oversized-thumbnail')),
        throwsA(_giphyError(GiphyError.responseTooLarge)),
      );
      expect(client.requestAborted, isFalse);
      expect(client.subscriptionCancelled, isTrue);
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

  group('GiphyPicker attribution', () {
    testWidgets('shows the server mark and opens Giphy', (tester) async {
      final repository = _PickerRepository(
        attributionLoader: () => Future<GiphyAttributionAsset>.value(
          GiphyAttributionAsset(body: _validGif, contentType: 'image/gif'),
        ),
      );
      final controller = GiphyController(repository: repository);
      addTearDown(controller.dispose);
      Uri? opened;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 600,
              child: GiphyPicker(
                controller: controller,
                labels: _pickerLabels,
                thumbnailBuilder: (_, _) => const SizedBox.shrink(),
                onSelected: (_) {},
                onAttributionPressed: (uri) async => opened = uri,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('giphy-attribution-image')), findsOneWidget);

      await tester.tap(find.byKey(const Key('giphy-attribution-link')));
      await tester.pump();
      expect(opened, giphyAttributionUri);
    });

    testWidgets('keeps a visible text link when the server mark fails', (
      tester,
    ) async {
      final repository = _PickerRepository(
        attributionLoader: () => Future<GiphyAttributionAsset>.error(
          const GiphyException(GiphyError.network),
        ),
      );
      final controller = GiphyController(repository: repository);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 600,
              child: GiphyPicker(
                controller: controller,
                labels: _pickerLabels,
                thumbnailBuilder: (_, _) => const SizedBox.shrink(),
                onSelected: (_) {},
                onAttributionPressed: (_) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Powered by GIPHY'), findsOneWidget);
      expect(find.byKey(const Key('giphy-attribution-link')), findsOneWidget);
      expect(find.byKey(const Key('giphy-attribution-image')), findsNothing);
    });
  });
}

const _pickerLabels = GiphyPickerLabels(
  searchHint: 'Search GIFs',
  noResults: 'No GIFs found',
  retry: 'Retry',
  loadMore: 'Load more',
  poweredByGiphy: 'Powered by GIPHY',
);

final _validGif = base64Decode(
  'R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==',
);

CapabilitySnapshot _capabilities(
  Object? integration, {
  bool includeIntegration = true,
}) => CapabilitySnapshot.fromJson(
  _capabilitiesPayload(integration, includeIntegration: includeIntegration),
  context: CapabilityContext.authenticated,
);

Map<String, Object?> _capabilitiesPayload(
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
  return payload;
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

final class _DeadlineSendClient extends http.BaseClient {
  bool wasAborted = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final trigger = (request as http.Abortable).abortTrigger!;
    await trigger;
    wasAborted = true;
    throw http.RequestAbortedException(request.url);
  }
}

final class _AbortAwareBodyClient extends http.BaseClient {
  _AbortAwareBodyClient({
    required this.statusCode,
    this.contentLength,
    this.headers = const <String, String>{},
  });

  final int statusCode;
  final int? contentLength;
  final Map<String, String> headers;
  bool requestAborted = false;
  bool subscriptionCancelled = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final trigger = (request as http.Abortable).abortTrigger!;
    late StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onCancel: () {
        subscriptionCancelled = true;
        if (!controller.isClosed) {
          return controller.close();
        }
      },
    );
    unawaited(
      trigger.then((_) async {
        requestAborted = true;
        if (!controller.isClosed) {
          controller.addError(http.RequestAbortedException(request.url));
          await controller.close();
        }
      }),
    );
    return http.StreamedResponse(
      controller.stream,
      statusCode,
      contentLength: contentLength,
      headers: headers,
    );
  }
}

final class _StalledBodyClient extends http.BaseClient {
  _StalledBodyClient({
    required this.statusCode,
    this.stallCancellation = false,
  });

  final int statusCode;
  final bool stallCancellation;
  bool wasCancelled = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    late StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onCancel: () {
        wasCancelled = true;
        if (stallCancellation) {
          return Completer<void>().future;
        }
        return controller.close();
      },
    );
    return http.StreamedResponse(controller.stream, statusCode);
  }
}

final class _GiphyProviderHarness {
  _GiphyProviderHarness._({
    required this.accountId,
    required this.container,
    required this.api,
    required this.database,
    required this.factoryCounter,
  });

  final String accountId;
  final ProviderContainer container;
  final HttpNextcloudApi api;
  final AppDatabase database;
  final _Counter factoryCounter;
  bool _containerDisposed = false;
  ProviderSubscription<AsyncValue<HttpGiphyRepository?>>? _subscription;

  int get factoryInvocations => factoryCounter.value;

  static Future<_GiphyProviderHarness> create({
    required Object? integration,
    required http.Client giphyClient,
    bool includeIntegration = true,
    Duration requestTimeout = const Duration(seconds: 20),
    http.Client? capabilitiesClient,
  }) async {
    const accountId = 'account-giphy';
    final database = openTestDatabase();
    final accounts = AccountRepository(database);
    await accounts.upsertAccount(
      accountId: accountId,
      serverUrl: 'https://cloud.example.invalid/nextcloud',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 8, 24),
    );
    final vault = MemoryCredentialVault();
    await vault.writeAppPassword(accountId, 'fixture-password');
    final api = HttpNextcloudApi(
      client:
          capabilitiesClient ??
          MockClient((_) async {
            return http.Response(
              jsonEncode(
                _capabilitiesPayload(
                  integration,
                  includeIntegration: includeIntegration,
                ),
              ),
              200,
            );
          }),
    );
    final factoryCounter = _Counter();
    final container = ProviderContainer(
      overrides: <Override>[
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(api),
        giphyRepositoryFactoryProvider.overrideWithValue(({
          required ServerBase server,
          required GiphyAuthorization authorization,
        }) {
          factoryCounter.value++;
          return HttpGiphyRepository(
            server: server,
            authorization: authorization,
            client: giphyClient,
            requestTimeout: requestTimeout,
          );
        }),
      ],
    );
    return _GiphyProviderHarness._(
      accountId: accountId,
      container: container,
      api: api,
      database: database,
      factoryCounter: factoryCounter,
    );
  }

  Future<HttpGiphyRepository?> readRepository() {
    _subscription ??= container.listen<AsyncValue<HttpGiphyRepository?>>(
      giphyRepositoryProvider(accountId),
      (_, _) {},
      fireImmediately: true,
    );
    return container.read(giphyRepositoryProvider(accountId).future);
  }

  void disposeProviders() {
    if (_containerDisposed) {
      return;
    }
    _containerDisposed = true;
    _subscription?.close();
    _subscription = null;
    container.dispose();
  }

  Future<void> close() async {
    disposeProviders();
    api.close();
    await database.close();
  }
}

final class _Counter {
  int value = 0;
}

final class _ControlledRepository implements GiphyRepository {
  final Map<String, Completer<GiphyPage>> _searches = {};

  @override
  Future<GiphyAttributionAsset> loadAttributionAsset({
    Future<void>? abortTrigger,
  }) => Future<GiphyAttributionAsset>.error(
    const GiphyException(GiphyError.network),
  );

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

final class _PickerRepository implements GiphyRepository {
  _PickerRepository({required this.attributionLoader});

  final Future<GiphyAttributionAsset> Function() attributionLoader;

  @override
  Future<GiphyAttributionAsset> loadAttributionAsset({
    Future<void>? abortTrigger,
  }) => attributionLoader();

  @override
  Future<GiphyPage> search({
    required String term,
    required int cursor,
    required int limit,
    Future<void>? abortTrigger,
  }) async => GiphyPage(entries: const <GiphyEntry>[], cursor: 0);

  @override
  Future<GiphyPage> trending({
    required int cursor,
    required int limit,
    Future<void>? abortTrigger,
  }) async => GiphyPage(entries: const <GiphyEntry>[], cursor: 0);
}
