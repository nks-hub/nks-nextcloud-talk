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
}
