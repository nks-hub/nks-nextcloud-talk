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

  testWidgets('wide idle toolbar separates attachment from right actions', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
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
        leadingAction: _aggregatedLeadingAction(),
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
    final toolbarRect = tester.getRect(
      find.byKey(const Key('chat-media-composer-actions')),
    );
    final actionRects = actionKeys
        .map((key) => tester.getRect(find.byKey(Key(key))))
        .toList(growable: false);

    expect(actionRects.first.left, toolbarRect.left);
    expect(actionRects.last.right, toolbarRect.right);
    expect(actionRects[1].left, greaterThan(actionRects.first.right));
    for (var index = 2; index < actionRects.length; index++) {
      expect(actionRects[index].left, actionRects[index - 1].right);
      expect(actionRects[index].top, actionRects.first.top);
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

  testWidgets('wide recording error separates attachment from right actions', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 956);
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
        showAttachmentButton: false,
        leadingAction: _aggregatedLeadingAction(),
        idleActions: _aggregatedIdleActions(),
        trailingActions: _aggregatedTrailingActions(),
      ),
    );
    await tester.tap(find.byKey(const Key('voice-record')));
    final errorMessage = find.text('The voice message could not be recorded.');
    await _pumpUntil(tester, () => errorMessage.evaluate().isNotEmpty);

    final actionsRect = tester.getRect(
      find.byKey(const Key('chat-media-composer-actions')),
    );
    final firstActionRect = tester.getRect(
      find.byKey(const Key('pick-image-attachment')),
    );
    final sendActionRect = tester.getRect(
      find.byKey(const Key('send-message')),
    );
    final emojiActionRect = tester.getRect(
      find.byKey(const Key('open-emoji-picker')),
    );
    final voiceAction = find.byKey(const Key('voice-record'));
    final voiceActionRect = tester.getRect(voiceAction);
    expect(firstActionRect.left, actionsRect.left);
    expect(sendActionRect.right, actionsRect.right);
    expect(
      find.descendant(
        of: find.byKey(const Key('chat-media-composer-actions')),
        matching: voiceAction,
      ),
      findsOneWidget,
    );
    expect(voiceActionRect.left, emojiActionRect.right);
    expect(sendActionRect.left, voiceActionRect.right);
    expect(tester.getCenter(errorMessage).dx, actionsRect.center.dx);
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
    tester.view.physicalSize = const Size(220, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      localizedTestApp(
        home: Scaffold(
          body: ChatMediaComposerStatus.loading(
            leadingAction: _aggregatedLeadingAction(),
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
    expect(centerYs, hasLength(2));
    expect(
      tester.getCenter(find.byKey(const Key('send-message'))).dy,
      greaterThan(
        tester.getCenter(find.byKey(const Key('pick-image-attachment'))).dy,
      ),
    );
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
        leadingAction: _aggregatedLeadingAction(),
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

  testWidgets(
    'a desktop window that is not key still admits the file',
    (tester) async {
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
      // No resume ever comes: the window stays behind Finder.
      expect(await tester.runAsync(() => started), isTrue);
      await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);
      expect(bridge.sources, hasLength(1));
    },
    variant: TargetPlatformVariant.desktop(),
  );
}

Widget _aggregatedLeadingAction() => IconButton(
  key: const Key('pick-image-attachment'),
  onPressed: () {},
  icon: const Icon(Icons.attach_file_rounded),
);

List<Widget> _aggregatedIdleActions() => <Widget>[
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
