part of 'chat_composer_integration_test.dart';

const _galleryCount = 36;
const _expressionPanel = Key('inline-emoji-panel');
const _gifSearch = Key('giphy-search');
const _gifGrid = PageStorageKey<String>('giphy-grid');

void _registerGiphyGalleryTests() {
  testWidgets(
    'portrait GIF gallery keeps six complete previews with the IME',
    (tester) async {
      _galleryWindow(tester, const Size(390, 844));
      final fixture = await _openGallery(tester);
      await _galleryPage(tester, 20);
      final panel = find.byKey(_expressionPanel);
      expect(tester.getSize(panel), const Size(390, 320));
      final noIme = await _visibleGifs(tester, fixture);
      expect(noIme.full, 6);
      expect(noIme.partial, 3);
      expect(noIme.viewport.size, const Size(390, 211));
      expect(noIme.tile.width, closeTo(119.33, .01));
      expect(noIme.tile.height, 90);

      await tester.tap(find.byKey(_gifSearch));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.enterText(find.byKey(_gifSearch), 'fixture');
      await tester.pump(const Duration(milliseconds: 400));
      await _pumpUntil(
        tester,
        () => _galleryController(tester).term == 'fixture',
      );
      await _galleryPage(tester, 20);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.getSize(panel), const Size(390, 320));
      final withIme = await _visibleGifs(tester, fixture);
      expect(withIme.full, 6);
      expect(withIme.partial, 3);
      expect(withIme.viewport.size, noIme.viewport.size);
      expect(withIme.viewport.top, noIme.viewport.top - 300);
      expect(find.byKey(const Key('giphy-attribution-image')), findsOneWidget);
      await _unmountComposer(tester);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets('desktop GIF gallery follows the smiley and keeps eight previews '
      'at both supported heights', (tester) async {
    _galleryWindow(tester, const Size(1280, 800));
    final fixture = await _openGallery(tester, width: 900);
    await _galleryPage(tester, 20);
    final panel = find.byKey(_expressionPanel);
    final anchor = find.byKey(const Key('open-emoji-picker'));
    final pane = tester.getRect(find.byKey(const Key('chat-room-pane')));
    final first = tester.getRect(panel);
    final button = tester.getRect(anchor);
    expect(first.size, const Size(420, 360));
    expect(first.bottom, closeTo(button.top - 8, .1));
    expect(first.right, closeTo(button.right, .1));
    expect(first.left, greaterThanOrEqualTo(pane.left));
    expect(first.right, lessThanOrEqualTo(pane.right));
    final tall = await _visibleGifs(tester, fixture);
    expect(tall.full, 8);
    expect(tall.partial, 4);
    expect(tall.viewport.size, const Size(420, 251));
    expect(tall.tile, const Size(95, 103));

    final shortWindow = 800 - (button.top - pane.top - 8) + 320;
    tester.view.physicalSize = Size(1280, shortWindow);
    await _pumpTransition(tester);
    expect(tester.getSize(panel).width, 420);
    expect(tester.getSize(panel).height, closeTo(320, .1));
    final short = await _visibleGifs(tester, fixture);
    expect(short.full, 8);
    expect(short.partial, 0);
    expect(short.viewport.size, const Size(420, 211));
    expect(short.tile, const Size(95, 99.5));
    await tester.tap(find.byKey(_gifSearch));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _pumpTransition(tester);
    expect(panel, findsNothing);
    await _unmountComposer(tester);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets(
    'both expression tabs preserve the search and scroll position',
    (tester) async {
      _galleryWindow(tester, const Size(1280, 800));
      await _openGallery(tester);
      await tester.enterText(find.byKey(_gifSearch), 'fixture');
      await tester.pump(const Duration(milliseconds: 400));
      final controller = _galleryController(tester);
      await _pumpUntil(tester, () => controller.term == 'fixture');
      await _galleryPage(tester, 20);
      final grid = find.byKey(_gifGrid);
      final scroller = find.descendant(
        of: grid,
        matching: find.byType(Scrollable),
      );
      await tester.drag(grid, const Offset(0, -260));
      await _pumpTransition(tester);
      final offset = tester.state<ScrollableState>(scroller).position.pixels;
      expect(offset, greaterThan(100));

      await tester.tap(find.byKey(const Key('composer-emoji-tab')));
      await _pumpTransition(tester);
      expect(find.byKey(_gifSearch), findsNothing);
      await tester.enterText(find.byKey(const Key('emoji-search')), 'face');
      await _pumpTransition(tester);
      final emojiGrid = find.byKey(const Key('composer-emoji-scroll'));
      final emojiScroller = find.descendant(
        of: emojiGrid,
        matching: find.byType(Scrollable),
      );
      await tester.drag(emojiGrid, const Offset(0, -260));
      await _pumpTransition(tester);
      final emojiOffset = tester
          .state<ScrollableState>(emojiScroller)
          .position
          .pixels;
      expect(emojiOffset, greaterThan(100));

      final gifTab = find.byKey(const Key('open-giphy-picker'));
      Focus.of(tester.element(gifTab)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _pumpTransition(tester);
      expect(find.byKey(_gifSearch), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(_gifSearch)).controller!.text,
        'fixture',
      );
      expect(_galleryController(tester), same(controller));
      expect(
        tester.state<ScrollableState>(scroller).position.pixels,
        closeTo(offset, .1),
      );

      await tester.tap(find.byKey(const Key('composer-emoji-tab')));
      await _pumpTransition(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('emoji-search')))
            .controller!
            .text,
        'face',
      );
      expect(
        tester.state<ScrollableState>(emojiScroller).position.pixels,
        closeTo(emojiOffset, .1),
      );
      await _unmountComposer(tester);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'saving a GIF keeps the draft and selecting it from My GIFs sends',
    (tester) async {
      _galleryWindow(tester, const Size(390, 844));
      final fixture = await _openGallery(tester, draft: 'I was writing');
      await _galleryPage(tester, 20);
      final resource = 'https://giphy.com/gifs/layout-0';
      final star = find.byKey(ValueKey('gif-favorite-$resource'));
      await _pumpUntil(tester, () {
        final buttons = star.evaluate();
        return buttons.isNotEmpty &&
            tester.widget<IconButton>(star).onPressed != null;
      });
      await tester.tap(star);
      await _pumpUntil(
        tester,
        () => tester.widget<IconButton>(star).isSelected == true,
      );
      expect(fixture.chatSendStarted, isEmpty);
      expect(_composer(tester).text, 'I was writing');
      await tester.tap(find.byKey(const Key('giphy-my-gifs')));
      await _pumpTransition(tester);
      expect(find.byKey(_gifGrid), findsNothing);
      final saved = find.byKey(ValueKey('giphy-thumbnail-$resource'));
      expect(saved.hitTestable(), findsOneWidget);
      await tester.tap(saved, warnIfMissed: false);
      await _pumpUntil(tester, () => fixture.sentMessages.length == 1);
      expect(fixture.sentMessages.single, resource);
      expect(_composer(tester).text, 'I was writing');
      await _unmountComposer(tester);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  for (final gifKeyboard in [false, true]) {
    testWidgets('Android Back closes the expression picker before the room '
        '(GIF search keyboard: $gifKeyboard)', (tester) async {
      _galleryWindow(tester, const Size(390, 844));
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      final repository = _layoutGiphyRepository();
      addTearDown(repository.close);
      final providerScope =
          harness.app(overrides: _galleryProviders(harness, repository))
              as ProviderScope;
      var selected = true;
      var closeRoom = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: providerScope.overrides,
          child: localizedTestApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, update) => ConversationWorkspace(
                  account: harness.account,
                  accounts: [harness.account],
                  conversations: [harness.conversation],
                  selectedConversationToken: selected
                      ? harness.conversation.token
                      : null,
                  loading: false,
                  syncing: false,
                  onRefresh: () async {},
                  onSelectAccount: (_) {},
                  onAddAccount: () {},
                  onOpenConversation: (_) {},
                  onSelectConversation: (_) {},
                  onCloseConversation: () => update(() {
                    closeRoom++;
                    selected = false;
                  }),
                ),
              ),
            ),
          ),
        ),
      );
      await _pumpUntil(tester, () => _galleryEnabled(tester));
      await tester.enterText(find.byKey(const Key('chat-composer')), 'A draft');
      await _tapGiphy(tester);
      await _pumpUntil(
        tester,
        () => find.byKey(_gifSearch).evaluate().isNotEmpty,
      );
      if (gifKeyboard) {
        await tester.tap(find.byKey(_gifSearch));
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pump();
      }
      expect(tester.testTextInput.isVisible, gifKeyboard);
      await tester.binding.handlePopRoute();
      await _pumpTransition(tester);
      expect(find.byKey(_expressionPanel), findsNothing);
      expect(closeRoom, 0);
      expect(_composer(tester).text, 'A draft');
      tester.view.resetViewInsets();
      await tester.binding.handlePopRoute();
      await _pumpTransition(tester);
      expect(closeRoom, 1);
      expect(find.byKey(const Key('chat-room-pane')), findsNothing);
      await _unmountComposer(tester);
    }, variant: const TargetPlatformVariant({TargetPlatform.android}));
  }
}

void _galleryWindow(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

List<Override> _galleryProviders(
  _ComposerHarness harness,
  HttpGiphyRepository repo,
) => [
  emojiUsageStoreProvider.overrideWithValue(
    FileEmojiUsageStore(directory: harness.attachmentRoot),
  ),
  gifFavoritesStoreProvider.overrideWithValue(
    GifFavoritesStore(directory: harness.attachmentRoot),
  ),
  giphyRepositoryProvider.overrideWith((_, accountId) async {
    expect(accountId, harness.account.id);
    return repo;
  }),
];

Future<_ComposerHarness> _openGallery(
  WidgetTester tester, {
  double? width,
  String? draft,
}) async {
  final harness = (await tester.runAsync(_ComposerHarness.create))!;
  _addHarnessTearDown(tester, harness);
  final repository = _layoutGiphyRepository();
  addTearDown(repository.close);
  final app = harness.app(
    wrapInScaffold: true,
    overrides: _galleryProviders(harness, repository),
  );
  await tester.pumpWidget(
    width == null
        ? app
        : Align(
            alignment: Alignment.centerRight,
            child: SizedBox(width: width, child: app),
          ),
  );
  await _pumpUntil(tester, () => _galleryEnabled(tester));
  if (draft != null) {
    await tester.enterText(find.byKey(const Key('chat-composer')), draft);
  }
  await _tapGiphy(tester);
  await _pumpUntil(
    tester,
    () => find.byType(GiphyPicker).evaluate().isNotEmpty,
  );
  return harness;
}

GiphyController _galleryController(WidgetTester tester) =>
    tester.widget<GiphyPicker>(find.byType(GiphyPicker)).controller;

Future<void> _galleryPage(WidgetTester tester, int initialCount) async {
  final controller = _galleryController(tester);
  await _pumpUntil(
    tester,
    () =>
        controller.entries.length == initialCount &&
        controller.phase == GiphyLoadPhase.ready,
  );
  expect(await tester.runAsync(controller.loadMore), isTrue);
  await _pumpUntil(tester, () => controller.entries.length == _galleryCount);
  expect(
    controller.entries.map((entry) => entry.resourceUrl).toSet(),
    hasLength(_galleryCount),
  );
}

Future<({int full, int partial, Rect viewport, Size tile})> _visibleGifs(
  WidgetTester tester,
  _ComposerHarness harness,
) async {
  final grid = find.byKey(_gifGrid);
  final viewport = tester.getRect(grid);
  final scroll = find.descendant(of: grid, matching: find.byType(Scrollable));
  expect(tester.state<ScrollableState>(scroll).position.pixels, 0);
  final visible = <(Finder, Rect, Rect)>[];
  for (final entry in _galleryController(tester).entries) {
    final tile = find.byKey(ValueKey('giphy-thumbnail-${entry.resourceUrl}'));
    if (tile.evaluate().isEmpty) continue;
    final rect = tester.getRect(tile);
    final intersection = viewport.intersect(rect);
    if (intersection.width > 0 && intersection.height > .1) {
      visible.add((tile, rect, intersection));
    }
  }
  await _pumpUntil(
    tester,
    () => visible.every((target) {
      final image = find.descendant(
        of: target.$1,
        matching: find.byType(RawImage),
      );
      return image.evaluate().length == 1 &&
          tester.widget<RawImage>(image).image != null;
    }),
  );
  var full = 0;
  for (final (tile, rect, intersection) in visible) {
    final sendPoint = Offset(
      intersection.left + intersection.width / 4,
      intersection.center.dy,
    );
    final offset = sendPoint - rect.center;
    expect(
      tile.hitTestable(
        at: Alignment(offset.dx * 2 / rect.width, offset.dy * 2 / rect.height),
      ),
      findsOneWidget,
    );
    if ((rect.height - intersection.height).abs() < .1) full++;
  }
  expect(harness.sentMessages, isEmpty);
  return (
    full: full,
    partial: visible.length - full,
    viewport: viewport,
    tile: visible.first.$2.size,
  );
}

HttpGiphyRepository _layoutGiphyRepository() => HttpGiphyRepository(
  server: ServerBase.parse('https://cloud.example.invalid'),
  authorization: const GiphyAuthorization(
    loginName: 'fixture-user',
    appPassword: 'fixture-app-password',
  ),
  client: MockClient((request) async {
    final uri = request.url;
    if (uri.path.endsWith('/gifs/trending') ||
        uri.path.endsWith('/gifs/search')) {
      final cursor = int.parse(uri.queryParameters['cursor']!);
      final limit = int.parse(uri.queryParameters['limit']!);
      final end = (cursor + limit).clamp(0, _galleryCount);
      return http.Response(
        jsonEncode({
          'ocs': {
            'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
            'data': {
              'entries': [
                for (var i = cursor; i < end; i++)
                  {
                    'thumbnailUrl':
                        'https://cloud.example.invalid/apps/integration_giphy/gif/layout-$i',
                    'resourceUrl': 'https://giphy.com/gifs/layout-$i',
                    'title': 'Fixture $i',
                    'subline': 'Fixture author',
                  },
              ],
              'cursor': end,
            },
          },
        }),
        200,
      );
    }
    if (uri.path.contains('/gif/') ||
        uri.path.endsWith('powered-by-giphy.gif')) {
      final index = int.tryParse(uri.pathSegments.last.split('-').last) ?? 0;
      final gif = [..._animatedGif];
      gif[13] = (index * 43 + 34) % 255;
      gif[14] = (index * 37 + 65) % 255;
      gif[15] = (index * 29 + 119) % 255;
      return http.Response.bytes(
        gif,
        200,
        headers: {'content-type': 'image/gif'},
      );
    }
    return http.Response('', 404);
  }),
);
