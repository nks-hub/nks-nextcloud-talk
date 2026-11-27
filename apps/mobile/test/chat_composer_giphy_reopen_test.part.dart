part of 'chat_composer_integration_test.dart';

void _registerGiphyReopenTests() {
  testWidgets('compact composer keeps one row and opens formatting from plus', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.reset);
    _installVoiceChannels();
    final harness = (await tester.runAsync(
      () => _ComposerHarness.create(voice: true),
    ))!;
    _addHarnessTearDown(tester, harness);
    try {
      await tester.pumpWidget(harness.app());
      await _pumpUntil(tester, () => _galleryEnabled(tester));

      final field = find.byKey(const Key('chat-composer'));
      final plus = find.byKey(const Key('pick-image-attachment'));
      final emoji = find.byKey(const Key('open-emoji-picker'));
      final send = find.byKey(const Key('send-message-gesture'));
      final voice = find.byKey(const Key('voice-record'));
      expect(voice.hitTestable(), findsOneWidget);
      expect(send, findsNothing);
      await tester.enterText(field, 'hello');
      final controller = _composer(tester);
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 5,
      );
      await tester.pump();
      expect(voice, findsNothing);
      for (final control in [plus, emoji, send]) {
        expect(control.hitTestable(), findsOneWidget);
        expect(
          tester.getCenter(control).dy,
          closeTo(tester.getCenter(field).dy, 1),
        );
      }
      expect(find.byKey(const Key('open-format-menu')), findsNothing);
      expect(find.byKey(const Key('open-giphy-picker')), findsNothing);
      await _openComposerMenu(tester);
      expect(find.byKey(const Key('open-giphy-picker')), findsNothing);
      expect(
        find.byKey(const Key('record-voice-message')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('open-format-menu')));
      await _pumpTransition(tester);
      await tester.tap(find.byKey(const Key('format-bold')));
      await _pumpTransition(tester);
      expect(controller.text, '**hello**');
      await _openComposerMenu(tester);
      await tester.tap(find.byKey(const Key('record-voice-message')));
      await _pumpTransition(tester);
      await _pumpUntil(
        tester,
        () => find.text('Microphone access was denied.').evaluate().isNotEmpty,
      );
      expect(
        find.byKey(const Key('voice-open-app-settings')).hitTestable(),
        findsOneWidget,
      );
      expect(controller.text, '**hello**');
      await tester.enterText(field, '');
      await tester.pump();
      expect(send, findsNothing);
      expect(voice.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmountComposer(tester);
    }
  });

  testWidgets('Giphy selection sends a reference and keeps the composer', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    _addHarnessTearDown(tester, harness);
    final giphy = _giphyRepository();
    addTearDown(giphy.close);
    final usage = FileEmojiUsageStore(directory: harness.attachmentRoot);

    await tester.pumpWidget(
      harness.app(
        overrides: <Override>[
          emojiUsageStoreProvider.overrideWithValue(usage),
          giphyRepositoryProvider.overrideWith((ref, accountId) async {
            expect(accountId, harness.account.id);
            return giphy;
          }),
        ],
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
    );

    await tester.enterText(find.byKey(const Key('chat-composer')), 'Hi  there');
    _composer(tester).selection = const TextSelection.collapsed(offset: 3);
    await _openEmojiPanel(tester);
    expect(find.byKey(const Key('inline-emoji-panel')), findsOneWidget);
    expect(find.byKey(const Key('chat-composer')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('inline-emoji-panel'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('chat-composer'))).dy),
    );
    await tester.enterText(
      find.byKey(const Key('emoji-search')),
      'waving hand',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('emoji-choice-waving-hand')));
    await _pumpTransition(tester);
    expect(_composer(tester).text, 'Hi 👋 there');
    expect(find.byKey(const Key('emoji-close')), findsOneWidget);
    await _pumpUntil(tester, () => _sendButtonEnabled(tester));
    await tester.tap(find.byKey(const Key('send-message-gesture')));
    await _pumpUntil(
      tester,
      () => harness.sentMessages.length == 1 && _composer(tester).text.isEmpty,
    );
    await _pumpTransition(tester);
    expect(harness.sentMessages, <String>['Hi 👋 there']);
    expect(find.byKey(const Key('inline-emoji-panel')), findsNothing);
    await _openEmojiPanel(tester);
    final recent = find.byKey(const Key('emoji-recent-choice-waving-hand'));
    final catalog = find.byKey(const Key('emoji-choice-grinning-face'));
    await _pumpUntil(tester, () => recent.hitTestable().evaluate().isNotEmpty);
    expect(catalog.hitTestable(), findsOneWidget);
    expect(
      tester.getRect(recent).bottom,
      lessThanOrEqualTo(tester.getRect(catalog).top),
    );
    await tester.tap(recent);
    await _pumpTransition(tester);
    await tester.tap(find.byKey(const Key('emoji-close')));
    await _pumpTransition(tester);
    expect(find.byKey(const Key('inline-emoji-panel')), findsNothing);

    await _tapGiphy(tester);
    final gif = find.byKey(
      const ValueKey<String>('giphy-thumbnail-https://giphy.com/gifs/wave'),
    );
    await _pumpUntil(tester, () => gif.evaluate().isNotEmpty);
    await _pumpTransition(tester);
    final thumbnailImage = tester.widget<Image>(
      find.descendant(of: gif, matching: find.byType(Image)),
    );
    final resizedThumbnail = thumbnailImage.image as ResizeImage;
    expect(resizedThumbnail.width, 480);
    expect(resizedThumbnail.height, 480);
    final picker = find.descendant(
      of: find.byKey(const Key('inline-emoji-panel')),
      matching: find.byType(GiphyPicker),
    );
    expect(
      tester.getBottomLeft(picker).dy,
      lessThanOrEqualTo(
        tester.getTopLeft(find.byKey(const Key('chat-composer'))).dy,
      ),
    );
    await tester.ensureVisible(gif);
    await tester.pump();
    await tester.tap(gif);
    await _pumpTransition(tester);
    await _pumpUntil(tester, () => harness.sentMessages.length == 2);

    // The GIF travels as a reference the bubble renders, so nothing is
    // uploaded into the user's own storage.
    expect(harness.sentMessages.last, 'https://giphy.com/gifs/wave');
    expect(harness.uploadedAttachments, isEmpty);
    expect(harness.finalizedFileNames, isEmpty);
    // Text already typed must survive sending a GIF.
    expect(_composer(tester).text, '👋');

    await _pumpUntil(tester, () => _sendButtonEnabled(tester));
    await tester.tap(find.byKey(const Key('send-message-gesture')));
    await _pumpUntil(
      tester,
      () => harness.sentMessages.length == 3 && _composer(tester).text.isEmpty,
    );

    expect(harness.sentMessages.last, '👋');
    expect(_composer(tester).text, isEmpty);
    expect(tester.takeException(), isNull);
    await _unmountComposer(tester);
  });

  testWidgets('reopened Giphy picker is warm and keeps attachment access', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    _addHarnessTearDown(tester, harness);
    final requests = <Uri>[];
    int requestsFor(String path) =>
        requests.where((uri) => uri.path.endsWith(path)).length;
    final repository = _giphyRepository(onRequest: requests.add);
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
    await _pumpUntil(tester, () => _galleryEnabled(tester));

    expect(find.byKey(const Key('pick-image-attachment')), findsOneWidget);
    expect(find.byKey(const Key('voice-record')), findsNothing);
    expect(
      find.byKey(const Key('send-message-gesture')).hitTestable(),
      findsOneWidget,
    );
    await _tapGiphy(tester);
    final wave = find.byKey(
      const ValueKey<String>('giphy-thumbnail-https://giphy.com/gifs/wave'),
    );
    final image = find.descendant(of: wave, matching: find.byType(Image));
    await _pumpUntil(tester, () => image.evaluate().isNotEmpty);
    expect(requestsFor('/gifs/trending'), 1);
    expect(requestsFor('/gif/wave'), 1);
    await tester.tap(find.byKey(const Key('emoji-close')));
    await _pumpTransition(tester);
    expect(find.byKey(const Key('inline-emoji-panel')), findsNothing);
    expect(
      find.byKey(const Key('pick-image-attachment')).hitTestable(),
      findsOneWidget,
    );

    await _tapGiphy(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final picker = find.byType(GiphyPicker);
    expect(picker, findsOneWidget);
    expect(
      tester.widget<GiphyPicker>(picker).controller.phase,
      GiphyLoadPhase.ready,
    );
    expect(wave, findsOneWidget);
    await _pumpUntil(tester, () => image.evaluate().isNotEmpty);
    expect(requestsFor('/gifs/trending'), 1);
    expect(requestsFor('/gif/wave'), 1);

    await tester.tap(find.byKey(const Key('composer-emoji-tab')));
    await _pumpTransition(tester);
    expect(find.byKey(const Key('emoji-search')).hitTestable(), findsOneWidget);
    expect(picker, findsNothing);
    await tester.tap(find.byKey(const Key('open-emoji-picker')));
    await _pumpTransition(tester);
    expect(find.byKey(const Key('inline-emoji-panel')), findsNothing);
    expect(
      find.byKey(const Key('pick-image-attachment')).hitTestable(),
      findsOneWidget,
    );
    await _unmountComposer(tester);
  });

  testWidgets(
    'search and select a GIF on an 800 by 360 landscape phone',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 360);
      addTearDown(tester.view.reset);
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      final repository = _giphyRepository();
      addTearDown(repository.close);
      await tester.pumpWidget(
        harness.app(
          overrides: [
            giphyRepositoryProvider.overrideWith(
              (ref, accountId) async => repository,
            ),
          ],
        ),
      );
      await _pumpUntil(tester, () => _galleryEnabled(tester));
      await _tapGiphy(tester);
      final search = find.byKey(const Key('giphy-search'));
      await _pumpUntil(
        tester,
        () => search.hitTestable().evaluate().isNotEmpty,
      );
      await tester.enterText(search, 'otter');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      final result = find.byKey(
        const ValueKey<String>('giphy-thumbnail-https://giphy.com/gifs/otter'),
      );
      await _pumpUntil(tester, () => result.evaluate().isNotEmpty);
      final attribution = find.byKey(const Key('giphy-attribution-link'));
      await tester.ensureVisible(attribution);
      await tester.pump();
      expect(attribution.hitTestable(), findsOneWidget);
      await tester.ensureVisible(result);
      await tester.pump();
      expect(result.hitTestable(), findsOneWidget);
      await tester.tap(result);
      await _pumpUntil(tester, () => harness.sentMessages.isNotEmpty);
      expect(harness.sentMessages, ['https://giphy.com/gifs/otter']);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final closePanel in [true, false]) {
    testWidgets(
      closePanel
          ? 'closing the panel during a GIF probe keeps it closed and preserves the draft'
          : 'returning to emoji during a GIF probe keeps emoji selected and preserves the draft',
      (tester) async {
        final harness = (await tester.runAsync(_ComposerHarness.create))!;
        _addHarnessTearDown(tester, harness);
        final repository = _giphyRepository();
        addTearDown(repository.close);
        final probe = Completer<HttpGiphyRepository?>();
        var requested = false;
        await tester.pumpWidget(
          harness.app(
            overrides: [
              giphyRepositoryProvider.overrideWith((ref, accountId) {
                requested = true;
                return probe.future;
              }),
            ],
          ),
        );
        await _pumpUntil(tester, () => _galleryEnabled(tester));
        await tester.enterText(find.byKey(const Key('chat-composer')), 'Draft');
        await _openEmojiPanel(tester);
        expect(requested, isFalse);
        final search = find.byKey(const Key('emoji-search'));
        if (!closePanel) {
          await tester.enterText(search, 'waving hand');
          await tester.pump();
        }
        await tester.tap(find.byKey(const Key('open-giphy-picker')));
        await _pumpUntil(tester, () => requested);
        await tester.tap(
          find.byKey(
            Key(closePanel ? 'open-emoji-picker' : 'composer-emoji-tab'),
          ),
        );
        await tester.pump();
        probe.complete(repository);
        await _pumpTransition(tester);

        expect(find.byType(GiphyPicker), findsNothing);
        expect(
          find.byKey(const Key('inline-emoji-panel')),
          closePanel ? findsNothing : findsOneWidget,
        );
        if (!closePanel) {
          expect(search.hitTestable(), findsOneWidget);
          expect(
            tester.widget<TextField>(search).controller!.text,
            'waving hand',
          );
          expect(
            find.byKey(const Key('emoji-choice-waving-hand')).hitTestable(),
            findsOneWidget,
          );
        }
        expect(_composer(tester).text, 'Draft');
        expect(harness.sentMessages, isEmpty);
        expect(tester.takeException(), isNull);
        await _unmountComposer(tester);
      },
    );
  }
}

bool _galleryEnabled(WidgetTester tester) {
  final button = find.byType(ComposerActionMenuButton);
  return button.evaluate().isNotEmpty &&
      tester
          .widget<ComposerActionMenuButton>(button)
          .actions
          .value
          .any(
            (action) =>
                action.key == const Key('attach-source-gallery') &&
                action.onSelected != null,
          );
}

Future<void> _openComposerMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('pick-image-attachment')));
  await _pumpTransition(tester);
}

Future<void> _openEmojiPanel(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('open-emoji-picker')));
  await _pumpTransition(tester);
}

Future<void> _tapGiphy(WidgetTester tester) async {
  await _openEmojiPanel(tester);
  await tester.tap(find.byKey(const Key('open-giphy-picker')));
}

void _installVoiceChannels() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channels = <MethodChannel>[];
  void register(String name, Future<dynamic> Function(MethodCall) handler) {
    final channel = MethodChannel(name);
    channels.add(channel);
    messenger.setMockMethodCallHandler(channel, handler);
  }

  addTearDown(() {
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
  for (final name in [
    'xyz.luan/audioplayers.global',
    'xyz.luan/audioplayers.global/events',
    'com.nkshub.nextcloudtalk/call_audio_focus',
  ]) {
    register(name, (_) async => null);
  }
  register(
    'com.llfbandit.record/messages',
    (call) async => call.method == 'hasPermission' ? false : null,
  );
  register('xyz.luan/audioplayers', (call) async {
    if (call.method == 'create') {
      final id = (call.arguments as Map)['playerId'];
      register('xyz.luan/audioplayers/events/$id', (_) async => null);
    }
    return null;
  });
}
