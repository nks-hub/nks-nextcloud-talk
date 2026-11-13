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
    expect(tester.takeException(), isNull);
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
