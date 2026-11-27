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
      await _pumpUntil(tester, () => _giphyButtonEnabled(tester));

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

  testWidgets('reopened Giphy picker is warm and keeps attachment access', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    _addHarnessTearDown(tester, harness);
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
    expect(find.byKey(const Key('voice-record')), findsNothing);
    expect(
      find.byKey(const Key('send-message-gesture')).hitTestable(),
      findsOneWidget,
    );
    await _tapGiphy(tester);
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

    await _tapGiphy(tester);
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
    await _unmountComposer(tester);
  });
}

bool _giphyButtonEnabled(WidgetTester tester) {
  final button = find.byType(ComposerActionMenuButton);
  return button.evaluate().isNotEmpty &&
      tester
          .widget<ComposerActionMenuButton>(button)
          .actions
          .value
          .any(
            (action) =>
                action.key == const Key('open-giphy-picker') &&
                action.onSelected != null,
          );
}

Future<void> _openComposerMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('pick-image-attachment')));
  await _pumpTransition(tester);
}

Future<void> _tapGiphy(WidgetTester tester) async {
  await _openComposerMenu(tester);
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
