part of 'chat_composer_integration_test.dart';

void _registerGiphyReopenTests() {
  testWidgets('reopened Giphy picker is warm and keeps attachment access', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    addTearDown(harness.close);
    var trendingRequests = 0;
    final repository = HttpGiphyRepository(
      server: ServerBase.parse('https://cloud.example.invalid'),
      authorization: const GiphyAuthorization(
        loginName: 'fixture-user',
        appPassword: 'fixture-app-password',
      ),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/gifs/trending')) {
          trendingRequests++;
          return http.Response(_giphyResponse(), 200);
        }
        return http.Response.bytes(
          _animatedGif,
          200,
          headers: const <String, String>{'content-type': 'image/gif'},
        );
      }),
    );
    addTearDown(repository.close);
    await tester.pumpWidget(
      harness.app(
        overrides: <Override>[
          giphyRepositoryProvider.overrideWith(
            (ref, accountId) async => repository,
          ),
        ],
      ),
    );
    await _pumpUntil(tester, () => _giphyButtonEnabled(tester));

    expect(find.byKey(const Key('pick-image-attachment')), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-giphy-picker')));
    await _pumpUntil(tester, () {
      final picker = find.byType(GiphyPicker);
      return picker.evaluate().isNotEmpty &&
          tester.widget<GiphyPicker>(picker).controller.phase ==
              GiphyLoadPhase.ready;
    });
    expect(trendingRequests, 1);
    Navigator.of(tester.element(find.byType(GiphyPicker))).pop();
    await _pumpTransition(tester);
    expect(find.byKey(const Key('pick-image-attachment')), findsOneWidget);

    await tester.tap(find.byKey(const Key('open-giphy-picker')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final picker = find.byType(GiphyPicker);
    expect(picker, findsOneWidget);
    expect(
      tester.widget<GiphyPicker>(picker).controller.phase,
      GiphyLoadPhase.ready,
    );
    expect(
      find.descendant(
        of: picker,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
    expect(trendingRequests, 1);

    Navigator.of(tester.element(find.byType(GiphyPicker))).pop();
    await _pumpTransition(tester);
    expect(find.byKey(const Key('pick-image-attachment')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
