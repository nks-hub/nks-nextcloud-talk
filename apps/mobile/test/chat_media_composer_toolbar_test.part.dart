part of 'chat_media_composer_test.dart';

void _registerChatMediaComposerToolbarTests(
  DurableAttachmentSourceStore Function() sourceStore,
) {
  testWidgets('narrow idle toolbar keeps all five actions on one baseline', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore(),
        bridge: bridge.bridge,
        threadId: null,
        voiceBackends: voiceBackends,
        idleActions: <Widget>[
          IconButton(
            key: const Key('open-emoji-picker'),
            onPressed: () {},
            icon: const Icon(Icons.emoji_emotions_outlined),
          ),
          IconButton(
            key: const Key('open-giphy-picker'),
            onPressed: () {},
            icon: const Icon(Icons.gif_box_outlined),
          ),
          IconButton.filled(
            key: const Key('send-message'),
            onPressed: () {},
            icon: const Icon(Icons.send_rounded),
          ),
        ],
      ),
    );

    const actionKeys = <String>[
      'pick-image-attachment',
      'voice-record',
      'open-emoji-picker',
      'open-giphy-picker',
      'send-message',
    ];
    final centerYs = actionKeys
        .map((key) => tester.getCenter(find.byKey(Key(key))).dy)
        .toSet();
    expect(centerYs, hasLength(1));
    for (final key in actionKeys) {
      final size = tester.getSize(find.byKey(Key(key)));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('recording error fits beside a full narrow toolbar', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(259, 956);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory(failStart: true);
    addTearDown(voiceBackends.close);

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore(),
        bridge: bridge.bridge,
        threadId: null,
        voiceBackends: voiceBackends,
        locale: const Locale('cs'),
        idleActions: List<Widget>.generate(
          5,
          (index) => IconButton(
            key: Key('idle-action-$index'),
            onPressed: () {},
            icon: const Icon(Icons.circle_outlined),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('voice-record')));
    await _pumpUntil(
      tester,
      () => find
          .text('Hlasovou zprávu se nepodařilo nahrát.')
          .evaluate()
          .isNotEmpty,
    );

    expect(find.text('Hlasovou zprávu se nepodařilo nahrát.'), findsOneWidget);
    for (var index = 0; index < 5; index++) {
      final action = find.byKey(Key('idle-action-$index'));
      expect(action, findsOneWidget);
      final size = tester.getSize(action);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    expect(
      tester.getSize(find.byKey(const Key('voice-record'))).width,
      greaterThanOrEqualTo(48),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported voice capability leaves a disabled microphone', (
    tester,
  ) async {
    final bridge = _RecordingBridge(profile: _profile(voice: false));
    addTearDown(bridge.close);

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore(),
        bridge: bridge.bridge,
        threadId: null,
        profile: _profile(voice: false),
      ),
    );

    final button = tester.widget<IconButton>(
      find.byKey(const Key('voice-record-unavailable')),
    );
    expect(button.onPressed, isNull);
    expect(find.byKey(const Key('voice-record')), findsNothing);
  });

  testWidgets('denied microphone offers app settings recovery', (tester) async {
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory(permissionGranted: false);
    addTearDown(voiceBackends.close);
    var settingsOpenCalls = 0;

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore(),
        bridge: bridge.bridge,
        threadId: null,
        voiceBackends: voiceBackends,
        openAppSettings: () async {
          settingsOpenCalls++;
          return false;
        },
      ),
    );
    await tester.tap(find.byKey(const Key('voice-record')));
    await tester.pump();

    expect(find.text('Microphone access was denied.'), findsOneWidget);
    final settings = find.byKey(const Key('voice-open-app-settings'));
    expect(settings, findsOneWidget);
    expect(tester.getSize(settings), const Size(48, 48));
    await tester.tap(settings);
    await tester.pump();
    expect(settingsOpenCalls, 1);
    expect(
      find.text('The system settings could not be opened.'),
      findsOneWidget,
    );
  });

  testWidgets('loading toolbar wraps at compact detail pane width', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(259, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      localizedTestApp(
        home: Scaffold(
          body: ChatMediaComposerStatus.loading(
            idleActions: _aggregatedIdleActions(),
            trailingActions: _aggregatedTrailingActions(),
          ),
        ),
      ),
    );

    const actionKeys = <String>[
      'pick-image-attachment',
      'open-giphy-picker',
      'open-emoji-picker',
      'voice-record-unavailable',
      'send-message',
    ];
    final centerYs = actionKeys
        .map((key) => tester.getCenter(find.byKey(Key(key))).dy)
        .toSet();
    expect(centerYs, hasLength(1));
    for (final key in actionKeys) {
      final size = tester.getSize(find.byKey(Key(key)));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('aggregated toolbar orders actions without duplicate gallery', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(259, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore(),
        bridge: bridge.bridge,
        threadId: null,
        voiceBackends: voiceBackends,
        showAttachmentButton: false,
        idleActions: _aggregatedIdleActions(),
        trailingActions: _aggregatedTrailingActions(),
      ),
    );

    const actionKeys = <String>[
      'pick-image-attachment',
      'open-giphy-picker',
      'open-emoji-picker',
      'voice-record',
      'send-message',
    ];
    final centerYs = actionKeys
        .map((key) => tester.getCenter(find.byKey(Key(key))).dy)
        .toSet();
    expect(centerYs, hasLength(1));
    for (final key in actionKeys) {
      final size = tester.getSize(find.byKey(Key(key)));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    expect(find.byKey(const Key('pick-image-from-gallery')), findsNothing);
    expect(find.byKey(const Key('pick-image-attachment')), findsOneWidget);
    expect(find.byKey(const Key('open-giphy-picker')), findsOneWidget);
    final centers = actionKeys
        .map((key) => tester.getCenter(find.byKey(Key(key))).dx)
        .toList(growable: false);
    expect(centers, orderedEquals(centers.toList()..sort()));
    expect(tester.takeException(), isNull);

    final invalidBridge = _RecordingBridge();
    addTearDown(invalidBridge.close);
    await tester.pumpWidget(
      _composerApp(
        composerKey: const Key('invalid-media-composer'),
        sourceStore: sourceStore(),
        bridge: invalidBridge.bridge,
        threadId: null,
        voiceBackends: voiceBackends,
        showAttachmentButton: false,
        silent: true,
      ),
    );

    expect(find.byKey(const Key('pick-image-from-gallery')), findsNothing);
  });

  testWidgets('iOS-style inactive picker result waits for resumed admission', (
    tester,
  ) async {
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);
    final controller = ChatMediaComposerController();
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore(),
        bridge: bridge.bridge,
        threadId: null,
        voiceBackends: voiceBackends,
        controller: controller,
        showAttachmentButton: false,
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    late Future<bool> started;
    await tester.runAsync(() async {
      started = controller.pickAttachment(AttachmentPickerSource.gallery);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('image-attachment-upload-panel'))
          .evaluate()
          .isNotEmpty,
    );
    expect(bridge.sessions, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(await tester.runAsync(() => started), isTrue);
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);
    expect(bridge.sources, hasLength(1));
  });
}

List<Widget> _aggregatedIdleActions() => <Widget>[
  IconButton(
    key: const Key('pick-image-attachment'),
    onPressed: () {},
    icon: const Icon(Icons.attach_file_rounded),
  ),
  IconButton(
    key: const Key('open-giphy-picker'),
    onPressed: null,
    icon: const SizedBox.square(
      dimension: 20,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  ),
  IconButton(
    key: const Key('open-emoji-picker'),
    onPressed: () {},
    icon: const Icon(Icons.emoji_emotions_outlined),
  ),
];

List<Widget> _aggregatedTrailingActions() => <Widget>[
  IconButton.filled(
    key: const Key('send-message'),
    onPressed: () {},
    icon: const Icon(Icons.send_rounded),
  ),
];
