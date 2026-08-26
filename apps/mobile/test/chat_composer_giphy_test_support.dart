part of 'chat_composer_giphy_test.dart';

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

final _validPng = Uint8List.fromList(const <int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
]);

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

String _validReferenceResponse(
  Uri resourceUrl, {
  String proxiedUrl =
      'https://cloud.example.invalid/nextcloud/index.php/apps/'
      'integration_giphy/gif/proxy',
}) => jsonEncode(<String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': <String, Object?>{
      'references': <String, Object?>{
        resourceUrl.toString(): <String, Object?>{
          'richObjectType': 'integration_giphy_gif',
          'richObject': <String, Object?>{
            'id': 'fixture123',
            'proxied_url': proxiedUrl,
            'images': <String, Object?>{
              'fixed_width': <String, Object?>{'width': '400', 'height': '200'},
            },
          },
        },
      },
    },
  },
});

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

final class _CovariantDeadlineSendClient extends http.BaseClient {
  bool wasAborted = false;

  @override
  Future<IOStreamedResponse> send(http.BaseRequest request) async {
    await (request as http.Abortable).abortTrigger!;
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
