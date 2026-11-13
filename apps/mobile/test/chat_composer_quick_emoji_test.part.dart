part of 'chat_composer_integration_test.dart';

void _registerQuickEmojiComposerTests() {
  testWidgets('tapping the quick emoji sends it as an ordinary message', (
    tester,
  ) async {
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
  Future<_ComposerHarness> openQuickEmojiComposer(WidgetTester tester) async {
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
