part of 'chat_composer_giphy_test.dart';

void _registerGiphyCapabilityTests() {
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
}
