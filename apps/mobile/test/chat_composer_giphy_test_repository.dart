part of 'chat_composer_giphy_test.dart';

void _registerGiphyRepositoryTests(
  ServerBase server,
  GiphyAuthorization authorization,
) {
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

    test('keeps the first trending page warm for picker reopen', () async {
      var requests = 0;
      final repository = HttpGiphyRepository(
        server: server,
        authorization: authorization,
        client: MockClient((request) async {
          requests++;
          return http.Response(_validResponse(), 200);
        }),
      );
      addTearDown(repository.close);

      final first = await repository.trending(cursor: 0, limit: 20);
      final reopened = await repository.trending(cursor: 0, limit: 20);

      expect(first.entries, isNotEmpty);
      expect(
        reopened.entries.single.resourceUrl,
        first.entries.single.resourceUrl,
      );
      expect(requests, 1);
    });

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
      'resolves a Giphy reference and loads its same-origin proxy',
      () async {
        final observed = <http.Request>[];
        final resourceUrl = Uri.parse(
          'https://giphy.com/gifs/waving-cat-fixture123',
        );
        final repository = HttpGiphyRepository(
          server: server,
          authorization: authorization,
          client: MockClient((request) async {
            observed.add(request);
            if (request.url.path.endsWith('/ocs/v2.php/references/resolve')) {
              return http.Response(
                _validReferenceResponse(resourceUrl),
                200,
                headers: const <String, String>{
                  'content-type': 'application/json; charset=utf-8',
                },
              );
            }
            if (request.url.path.endsWith(
              '/apps/integration_giphy/gif/proxy',
            )) {
              return http.Response.bytes(
                _validGif,
                200,
                headers: const <String, String>{'content-type': 'image/gif'},
              );
            }
            return http.Response('', 404);
          }),
        );
        addTearDown(repository.close);

        final media = await repository.loadReference(resourceUrl);

        expect(media.resourceUrl, resourceUrl);
        expect(media.body, _validGif);
        expect(media.contentType, 'image/gif');
        expect(media.aspectRatio, 1);
        expect(observed, hasLength(2));
        expect(
          observed.first.url.path,
          '/nextcloud/ocs/v2.php/references/resolve',
        );
        expect(observed.first.url.queryParameters, <String, String>{
          'reference': resourceUrl.toString(),
          'format': 'json',
        });
        expect(observed.first.headers['Authorization'], startsWith('Basic '));
        expect(observed.first.followRedirects, isFalse);
        expect(
          observed.last.url,
          Uri.parse(
            'https://cloud.example.invalid/nextcloud/index.php/apps/'
            'integration_giphy/gif/proxy',
          ),
        );
        expect(observed.last.headers['Authorization'], startsWith('Basic '));
        expect(observed.last.followRedirects, isFalse);
      },
    );

    test('rejects a foreign Giphy reference proxy before loading it', () async {
      var requests = 0;
      final resourceUrl = Uri.parse(
        'https://giphy.com/gifs/waving-cat-fixture123',
      );
      final repository = HttpGiphyRepository(
        server: server,
        authorization: authorization,
        client: MockClient((request) async {
          requests++;
          return http.Response(
            _validReferenceResponse(
              resourceUrl,
              proxiedUrl: 'https://media.giphy.com/media/fixture/giphy.gif',
            ),
            200,
          );
        }),
      );
      addTearDown(repository.close);

      await expectLater(
        repository.loadReference(resourceUrl),
        throwsA(_giphyError(GiphyError.invalidResponse)),
      );
      expect(requests, 1);
    });

    test('rejects a same-origin URL outside the Giphy app route', () async {
      var requests = 0;
      final resourceUrl = Uri.parse(
        'https://giphy.com/gifs/waving-cat-fixture123',
      );
      final repository = HttpGiphyRepository(
        server: server,
        authorization: authorization,
        client: MockClient((request) async {
          requests++;
          return http.Response(
            _validReferenceResponse(
              resourceUrl,
              proxiedUrl:
                  'https://cloud.example.invalid/nextcloud/ocs/v2.php/'
                  'apps/integration_giphy/gif/proxy',
            ),
            200,
          );
        }),
      );
      addTearDown(repository.close);

      await expectLater(
        repository.loadReference(resourceUrl),
        throwsA(_giphyError(GiphyError.invalidResponse)),
      );
      expect(requests, 1);
    });

    test('rejects a static image for a Giphy reference', () async {
      var requests = 0;
      final resourceUrl = Uri.parse(
        'https://giphy.com/gifs/waving-cat-fixture123',
      );
      final repository = HttpGiphyRepository(
        server: server,
        authorization: authorization,
        client: MockClient((request) async {
          requests++;
          if (requests == 1) {
            return http.Response(_validReferenceResponse(resourceUrl), 200);
          }
          return http.Response.bytes(
            _validPng,
            200,
            headers: const <String, String>{'content-type': 'image/png'},
          );
        }),
      );
      addTearDown(repository.close);

      await expectLater(
        repository.loadReference(resourceUrl),
        throwsA(_giphyError(GiphyError.invalidResponse)),
      );
      expect(requests, 2);
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

    test('rejects GIFs with an oversized logical screen', () async {
      final oversizedCanvas = Uint8List.fromList(_validGif)
        ..[6] = 0xff
        ..[7] = 0xff
        ..[8] = 0xff
        ..[9] = 0xff;

      for (final loadAttribution in <bool>[true, false]) {
        final repository = HttpGiphyRepository(
          server: server,
          authorization: authorization,
          client: MockClient(
            (_) async => http.Response.bytes(
              oversizedCanvas,
              200,
              headers: const <String, String>{'content-type': 'image/gif'},
            ),
          ),
        );
        addTearDown(repository.close);

        final operation = loadAttribution
            ? repository.loadAttributionAsset()
            : repository.loadThumbnail(_giphyEntry('oversized-canvas'));
        await expectLater(
          operation,
          throwsA(_giphyError(GiphyError.invalidResponse)),
        );
      }
    });

    test('reuses a thumbnail without another authenticated request', () async {
      var requests = 0;
      final repository = HttpGiphyRepository(
        server: server,
        authorization: authorization,
        client: MockClient((_) async {
          requests++;
          return http.Response.bytes(
            _validGif,
            200,
            headers: const <String, String>{'content-type': 'image/gif'},
          );
        }),
      );
      addTearDown(repository.close);
      final entry = _giphyEntry('cached-thumbnail');

      final first = await repository.loadThumbnail(entry);
      final second = await repository.loadThumbnail(entry);

      expect(first.body, _validGif);
      expect(second.body, _validGif);
      expect(requests, 1);
    });

    test('coalesces concurrent loads of the same thumbnail', () async {
      var requests = 0;
      final release = Completer<void>();
      final repository = HttpGiphyRepository(
        server: server,
        authorization: authorization,
        client: MockClient((_) async {
          requests++;
          await release.future;
          return http.Response.bytes(
            _validGif,
            200,
            headers: const <String, String>{'content-type': 'image/gif'},
          );
        }),
      );
      addTearDown(repository.close);
      final entry = _giphyEntry('shared-thumbnail');

      final first = repository.loadThumbnail(entry);
      final second = repository.loadThumbnail(entry);
      await Future<void>.delayed(Duration.zero);
      release.complete();
      final thumbnails = await Future.wait([first, second]);

      expect(thumbnails, hasLength(2));
      expect(requests, 1);
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

    test(
      'covariant IO client future maps to a bounded timeout',
      () async {
        final client = _CovariantDeadlineSendClient();
        final repository = HttpGiphyRepository(
          server: ServerBase.parse('https://cloud.example.invalid'),
          authorization: authorization,
          client: client,
          requestTimeout: const Duration(milliseconds: 10),
        );
        addTearDown(repository.close);

        await expectLater(
          repository.trending(cursor: 0, limit: 20),
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
}
