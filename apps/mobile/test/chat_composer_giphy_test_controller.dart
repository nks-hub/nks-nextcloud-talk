part of 'chat_composer_giphy_test.dart';

void _registerGiphyControllerTests() {
  group('GiphyController', () {
    testWidgets('retries the first transient trending failure once', (
      tester,
    ) async {
      final repository = _ColdTrendingRepository();
      final controller = GiphyController(repository: repository);
      addTearDown(controller.dispose);

      final loaded = controller.loadTrending();
      await tester.pump();

      expect(repository.trendingCalls, 1);
      expect(controller.phase, GiphyLoadPhase.loading);

      await tester.pump(const Duration(seconds: 1));
      expect(await loaded, isTrue);
      expect(repository.trendingCalls, 2);
      expect(controller.phase, GiphyLoadPhase.ready);
      expect(controller.entries.single.title, 'cold-retry');
    });

    testWidgets('stops after one automatic cold trending retry', (
      tester,
    ) async {
      final repository = _ColdTrendingRepository(alwaysFail: true);
      final controller = GiphyController(repository: repository);
      addTearDown(controller.dispose);

      final loaded = controller.loadTrending();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(await loaded, isFalse);
      expect(repository.trendingCalls, 2);
      expect(controller.phase, GiphyLoadPhase.error);
      expect(controller.error, GiphyError.network);

      await tester.pump(const Duration(seconds: 10));
      expect(repository.trendingCalls, 2);
    });

    testWidgets('retries only transient cold trending failures', (
      tester,
    ) async {
      for (final error in <GiphyError>[
        GiphyError.timeout,
        GiphyError.unexpectedStatus,
      ]) {
        final repository = _ColdTrendingRepository(
          alwaysFail: true,
          failure: error,
        );
        final controller = GiphyController(repository: repository);

        final loaded = controller.loadTrending();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        expect(await loaded, isFalse, reason: error.name);
        expect(repository.trendingCalls, 2, reason: error.name);
        controller.dispose();
      }

      for (final error in <GiphyError>[
        GiphyError.integrationUnavailable,
        GiphyError.cancelled,
        GiphyError.responseTooLarge,
        GiphyError.invalidResponse,
        GiphyError.rateLimited,
      ]) {
        final repository = _ColdTrendingRepository(
          alwaysFail: true,
          failure: error,
        );
        final controller = GiphyController(repository: repository);

        expect(await controller.loadTrending(), isFalse, reason: error.name);
        await tester.pump(const Duration(seconds: 1));

        expect(repository.trendingCalls, 1, reason: error.name);
        controller.dispose();
      }
    });

    testWidgets('a newer search cancels the pending cold retry', (
      tester,
    ) async {
      final repository = _ColdTrendingRepository();
      final controller = GiphyController(repository: repository);
      addTearDown(controller.dispose);

      final coldLoad = controller.loadTrending();
      await tester.pump();

      expect(await controller.search('new'), isTrue);
      await tester.pump(const Duration(seconds: 1));

      expect(await coldLoad, isFalse);
      expect(repository.trendingCalls, 1);
      expect(controller.entries.single.title, 'search-new');
    });

    testWidgets('dispose cancels the pending cold retry', (tester) async {
      final repository = _ColdTrendingRepository();
      final controller = GiphyController(repository: repository);

      final coldLoad = controller.loadTrending();
      await tester.pump();
      controller.dispose();
      await tester.pump(const Duration(seconds: 1));

      expect(await coldLoad, isFalse);
      expect(repository.trendingCalls, 1);
    });

    test('suppresses stale search results', () async {
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
    });
  });

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

final class _ColdTrendingRepository implements GiphyRepository {
  _ColdTrendingRepository({
    this.alwaysFail = false,
    this.failure = GiphyError.network,
  });

  final bool alwaysFail;
  final GiphyError failure;
  int trendingCalls = 0;

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
  }) async =>
      GiphyPage(entries: <GiphyEntry>[_giphyEntry('search-$term')], cursor: 1);

  @override
  Future<GiphyPage> trending({
    required int cursor,
    required int limit,
    Future<void>? abortTrigger,
  }) async {
    trendingCalls++;
    if (alwaysFail || trendingCalls == 1) {
      throw GiphyException(failure);
    }
    return GiphyPage(
      entries: <GiphyEntry>[_giphyEntry('cold-retry')],
      cursor: 1,
    );
  }
}
