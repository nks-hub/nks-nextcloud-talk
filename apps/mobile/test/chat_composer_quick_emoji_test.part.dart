part of 'chat_composer_integration_test.dart';

void _registerQuickEmojiComposerTests() {
  testWidgets('tapping the quick emoji sends it as an ordinary message', (
    tester,
  ) async {
    _installVoiceChannels();
    final server = FakeOwnTalkServer()
      ..setExternally({'composer.quickEmoji': '\u{1F44D}'});
    final harness = (await tester.runAsync(
      () => _ComposerHarness.create(ownTalk: server, voice: true),
    ))!;
    _addHarnessTearDown(tester, harness);
    await tester.pumpWidget(
      harness.app(
        overrides: [
          ownTalkSettingsStoreProvider.overrideWith(
            (ref) => Future<OwnTalkSettingsStore>.error(StateError('no store')),
          ),
          appLifecycleResumeEventsProvider.overrideWithValue(
            const Stream<void>.empty(),
          ),
        ],
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('send-quick-emoji')).evaluate().isNotEmpty,
    );

    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('voice-record'))
          .hitTestable()
          .evaluate()
          .isNotEmpty,
    );
    expect(find.byKey(const Key('send-message')), findsNothing);
    await tester.tap(find.byKey(const Key('send-quick-emoji')));
    await _pumpUntil(tester, () => harness.sentMessages.isNotEmpty);

    expect(harness.sentMessages, ['\u{1F44D}']);
    expect(
      ChatEmojiSizeReference.tryParse(
        harness.chatSendFields.single['referenceId']!,
      ),
      isNull,
    );
    expect(tester.takeException(), isNull);
    await _unmountComposer(tester);
  });

  /// Pumps the composer with the thumbs-up quick emoji showing.
  Future<_ComposerHarness> openQuickEmojiComposer(
    WidgetTester tester, {
    bool voice = false,
  }) async {
    final server = FakeOwnTalkServer()
      ..setExternally({'composer.quickEmoji': '\u{1F44D}'});
    final harness = (await tester.runAsync(
      () => _ComposerHarness.create(ownTalk: server, voice: voice),
    ))!;
    _addHarnessTearDown(tester, harness);
    await tester.pumpWidget(
      harness.app(
        overrides: [
          ownTalkSettingsStoreProvider.overrideWith(
            (ref) => Future<OwnTalkSettingsStore>.error(StateError('no store')),
          ),
          appLifecycleResumeEventsProvider.overrideWithValue(
            const Stream<void>.empty(),
          ),
        ],
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('send-quick-emoji')).evaluate().isNotEmpty,
    );
    return harness;
  }

  testWidgets(
    'desktop composer aligns actions when the draft grows',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(850, 650);
      addTearDown(tester.view.reset);
      _installVoiceChannels();
      final harness = await openQuickEmojiComposer(tester, voice: true);
      try {
        final plus = find.byKey(const Key('pick-image-attachment'));
        final field = find.byKey(const Key('chat-composer'));
        final emoji = find.byKey(const Key('open-emoji-picker'));
        final voice = find.byKey(const Key('voice-record'));
        final quick = find.byKey(const Key('send-quick-emoji'));
        final send = find.byKey(const Key('send-message-gesture'));
        await _pumpUntil(
          tester,
          () => voice.hitTestable().evaluate().isNotEmpty,
        );

        final baseline = tester.getCenter(plus).dy;
        void expectAligned(Finder control) {
          expect(control.hitTestable(), findsOneWidget);
          expect(tester.getSize(control), const Size.square(48));
          expect(tester.getCenter(control).dy, closeTo(baseline, 0.5));
        }

        for (final control in [plus, emoji, voice, quick]) {
          expectAligned(control);
        }
        final primary = tester.getRect(quick);
        expect(primary.right, 850 - 16);
        expect(tester.getRect(plus).left, 16);
        expect(tester.getRect(field).left - tester.getRect(plus).right, 12);
        expect(tester.getRect(emoji).right, tester.getRect(voice).left);
        expect(tester.getRect(voice).right, primary.left);
        expect(tester.getCenter(field).dy, closeTo(baseline, 0.5));
        final singleLine = tester.getSize(field).height;

        const draft = 'First line\nSecond line\nThird line';
        await tester.enterText(field, draft);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.getSize(field).height, greaterThan(singleLine + 20));
        for (final control in [plus, emoji, send]) {
          expectAligned(control);
        }
        expect(tester.getRect(send), primary);
        expect(tester.getRect(emoji).right, primary.left);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _pumpUntil(tester, () => harness.sentMessages.isNotEmpty);
        expect(harness.sentMessages.single, draft);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmountComposer(tester);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('send and quick emoji share one slot of the same size', (
    tester,
  ) async {
    await openQuickEmojiComposer(tester);
    final slot = find.byKey(const Key('send-slot-transition'));
    final emojiRect = tester.getRect(slot);

    await tester.enterText(find.byKey(const Key('chat-composer')), 'Hello');
    await tester.pump();
    // Mid-transition the slot already holds the send button, at full size.
    expect(find.byKey(const Key('send-quick-emoji')), findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(slot), emojiRect);

    await tester.enterText(find.byKey(const Key('chat-composer')), '');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('send-quick-emoji')), findsOneWidget);
    expect(tester.getRect(slot), emojiRect);
    expect(tester.takeException(), isNull);
    await _unmountComposer(tester);
  });

  testWidgets('holding the quick emoji sends it at the step it grew to', (
    tester,
  ) async {
    final harness = await openQuickEmojiComposer(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('send-quick-emoji'))),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    final preview = find.byKey(const Key('quick-emoji-hold-preview'));
    expect(preview, findsOneWidget);
    final early = tester.widget<Text>(preview).style!.fontSize!;
    await tester.pump(QuickEmojiHoldButton.growDuration);
    expect(tester.widget<Text>(preview).style!.fontSize!, greaterThan(early));
    await gesture.up();
    await _pumpUntil(tester, () => harness.sentMessages.isNotEmpty);

    expect(harness.sentMessages, ['\u{1F44D}']);
    final reference = ChatEmojiSizeReference.tryParse(
      harness.chatSendFields.single['referenceId']!,
    );
    expect(reference?.step, ChatEmojiSizeReference.maxStep);
    expect(preview, findsNothing);
    await _unmountComposer(tester);
  });

  testWidgets('a shorter hold sends a smaller step', (tester) async {
    final harness = await openQuickEmojiComposer(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('send-quick-emoji'))),
    );
    await tester.pump(kLongPressTimeout);
    await tester.pump(QuickEmojiHoldButton.growDuration * 0.5);
    await gesture.up();
    await _pumpUntil(tester, () => harness.sentMessages.isNotEmpty);

    expect(
      ChatEmojiSizeReference.tryParse(
        harness.chatSendFields.single['referenceId']!,
      )?.step,
      2,
    );
    await _unmountComposer(tester);
  });

  testWidgets('the hold preview shows the size that release would send', (
    tester,
  ) async {
    final harness = await openQuickEmojiComposer(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('send-quick-emoji'))),
    );
    await tester.pump(kLongPressTimeout);
    await tester.pump(QuickEmojiHoldButton.growDuration * 0.4);
    // Let the preview finish moving to the step it has reached.
    await tester.pump(const Duration(milliseconds: 200));
    final preview = find.byKey(const Key('quick-emoji-hold-preview'));
    expect(
      tester.widget<Text>(preview).style!.fontSize,
      enlargedEmojiFontSizeForStep(2),
    );
    await gesture.up();
    await _pumpUntil(tester, () => harness.sentMessages.isNotEmpty);

    expect(
      ChatEmojiSizeReference.tryParse(
        harness.chatSendFields.single['referenceId']!,
      )?.step,
      2,
    );
    await _unmountComposer(tester);
  });

  testWidgets('the stand-in bubble of a held emoji is drawn at the held '
      'size from the first frame', (tester) async {
    final harness = await openQuickEmojiComposer(tester);
    final hold = Completer<void>();
    harness.admissionHold.add(hold);
    addTearDown(() {
      if (!hold.isCompleted) hold.complete();
    });

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('send-quick-emoji'))),
    );
    await tester.pump(kLongPressTimeout);
    await tester.pump(QuickEmojiHoldButton.growDuration);
    await gesture.up();
    // Admission waits on the held capabilities request, so only the stand-in
    // is on screen.
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('chat-pending-provisional-1'))
          .evaluate()
          .isNotEmpty,
    );

    final text = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('chat-pending-provisional-1')),
        matching: find.text('\u{1F44D}'),
      ),
    );
    expect(
      text.style!.fontSize,
      enlargedEmojiFontSizeForStep(ChatEmojiSizeReference.maxStep),
    );
    expect(harness.chatSendStarted, isEmpty);
    hold.complete();
    await _unmountComposer(tester);
  });

  testWidgets('dragging away while holding cancels the send', (tester) async {
    final harness = await openQuickEmojiComposer(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('send-quick-emoji'))),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    expect(find.byKey(const Key('quick-emoji-hold-preview')), findsOneWidget);
    await gesture.moveBy(
      const Offset(-(QuickEmojiHoldButton.cancelDistance + 20), 0),
    );
    await tester.pump();
    expect(find.byKey(const Key('quick-emoji-hold-preview')), findsNothing);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );

    expect(harness.chatSendFields, isEmpty);
    expect(find.byKey(const Key('send-quick-emoji')), findsOneWidget);
    await _unmountComposer(tester);
  });

  testWidgets(
    'a prepared file turns the quick emoji back into the send button while '
    'the text field stays empty',
    (tester) async {
      final server = FakeOwnTalkServer()
        ..setExternally({'composer.quickEmoji': '\u{1F44D}'});
      final harness = (await tester.runAsync(
        () => _ComposerHarness.create(ownTalk: server),
      ))!;
      _addHarnessTearDown(tester, harness);
      await tester.pumpWidget(
        harness.app(
          overrides: [
            ownTalkSettingsStoreProvider.overrideWith(
              (ref) =>
                  Future<OwnTalkSettingsStore>.error(StateError('no store')),
            ),
            appLifecycleResumeEventsProvider.overrideWithValue(
              const Stream<void>.empty(),
            ),
          ],
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('send-quick-emoji')).evaluate().isNotEmpty,
      );
      final controller = tester
          .widget<ChatMediaComposer>(find.byType(ChatMediaComposer))
          .controller!;
      expect(
        await tester.runAsync(
          () => controller.attachImageBytes(
            _animatedGif,
            mimeType: 'image/gif',
            displayName: 'prepared.gif',
          ),
        ),
        isTrue,
      );
      await _pumpUntil(tester, () => controller.hasPreparedAttachment);
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('send-quick-emoji')).evaluate().isEmpty,
      );
      expect(find.byKey(const Key('send-message')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
