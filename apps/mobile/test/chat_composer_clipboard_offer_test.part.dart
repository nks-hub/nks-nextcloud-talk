part of 'chat_composer_integration_test.dart';

void _registerClipboardOfferComposerTests() {
  Future<({_ComposerHarness harness, FakeClipboardImageSource clipboard})>
  pumpWithClipboardImage(
    WidgetTester tester, {
    FakeOwnTalkServer? ownTalk,
  }) async {
    ClipboardImageOffer.debugForgetHandledClip();
    final clipboard = FakeClipboardImageSource()
      ..copyImage('clip-1', _animatedGif);
    final harness = (await tester.runAsync(
      () => _ComposerHarness.create(ownTalk: ownTalk),
    ))!;
    _addHarnessTearDown(tester, harness);
    await tester.pumpWidget(
      harness.app(
        overrides: [
          clipboardImageSourceProvider.overrideWithValue(clipboard),
          clipboardOfferMemoryProvider.overrideWithValue(
            ClipboardOfferMemory(directory: harness.attachmentRoot),
          ),
          if (ownTalk != null) ...[
            ownTalkSettingsStoreProvider.overrideWith(
              (ref) =>
                  Future<OwnTalkSettingsStore>.error(StateError('no store')),
            ),
            appLifecycleResumeEventsProvider.overrideWithValue(
              const Stream<void>.empty(),
            ),
          ],
        ],
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byType(ChatMediaComposer).evaluate().isNotEmpty,
    );
    expect(clipboard.peeks, 0, reason: 'an unfocused field asks nothing');
    await tester.tap(find.byKey(const Key('chat-composer')));
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('clipboard-image-offer')).evaluate().isNotEmpty,
    );
    await _pumpTransition(tester);
    return (harness: harness, clipboard: clipboard);
  }

  testWidgets(
    'the clipboard thumbnail puts the image into the composer to wait for '
    'a caption',
    (tester) async {
      final (:harness, :clipboard) = await pumpWithClipboardImage(tester);
      final controller = tester
          .widget<ChatMediaComposer>(find.byType(ChatMediaComposer))
          .controller!;

      await tester.tap(find.byKey(const Key('clipboard-image-offer-attach')));
      await _pumpUntil(tester, () => controller.hasPreparedAttachment);
      await _pumpTransition(tester);
      expect(find.byKey(const Key('clipboard-image-offer')), findsNothing);
      expect(harness.attachmentUploadStarted, isEmpty);

      // A newer clip stays unread while a file already waits here.
      clipboard.copyImage('clip-2', _animatedGif);
      await _pumpTransition(tester);
      expect(find.byKey(const Key('clipboard-image-offer')), findsNothing);
      expect(clipboard.reads, 1);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'the card leaves the quick emoji slot as it is',
    (tester) async {
      await pumpWithClipboardImage(
        tester,
        ownTalk: FakeOwnTalkServer()
          ..setExternally({'composer.quickEmoji': '\u{1F44D}'}),
      );
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('send-quick-emoji')).evaluate().isNotEmpty,
      );
      // The card's send is the only primary action while the field is empty.
      expect(find.byKey(const Key('clipboard-image-offer')), findsOneWidget);
      expect(find.byKey(const Key('send-message')), findsNothing);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'send on the clipboard card uploads the image once',
    (tester) async {
      final (:harness, :clipboard) = await pumpWithClipboardImage(tester);

      await tester.tap(find.byKey(const Key('clipboard-image-offer-send')));
      await _pumpUntil(tester, () => harness.finalizedFileNames.isNotEmpty);
      await _pumpTransition(tester);

      expect(harness.uploadedAttachments.single, _animatedGif);
      expect(harness.finalizedFileNames.single, startsWith('screenshot-'));
      expect(find.byKey(const Key('clipboard-image-offer')), findsNothing);
      expect(clipboard.reads, 1);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
