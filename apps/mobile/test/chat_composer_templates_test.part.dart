part of 'chat_composer_integration_test.dart';

void _registerComposerFeatureTests() {
  _registerLocationComposerTests();
  _registerGiphyReopenTests();
  _registerNonBlockingComposerTests();
  _registerQuickEmojiComposerTests();
  _registerClipboardOfferComposerTests();
  _registerCompactReplyComposerTest();

  testWidgets(
    'the plus menu inserts a template at the cursor without sending',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      final store = ReplyTemplateStore(directory: harness.attachmentRoot);
      await tester.runAsync(
        () => store.save(
          AccountId.parse(harness.account.id),
          name: 'Lunch',
          text: 'soon',
        ),
      );
      await tester.pumpWidget(
        harness.app(
          overrides: [replyTemplateStoreProvider.overrideWithValue(store)],
        ),
      );
      final field = find.byKey(const Key('chat-composer'));
      await _pumpUntil(tester, () => field.evaluate().isNotEmpty);
      await tester.enterText(field, 'See you !');
      _composer(tester).selection = const TextSelection.collapsed(offset: 8);
      await _openComposerMenu(tester);
      await tester.tap(find.byKey(const Key('open-reply-templates')));
      await _pumpTransition(tester);
      final template = find.text('Lunch');
      await _pumpUntil(
        tester,
        () => template.hitTestable().evaluate().isNotEmpty,
      );
      await tester.tap(template);
      await _pumpTransition(tester);
      expect(_composer(tester).text, 'See you soon!');
      expect(_composer(tester).selection.baseOffset, 12);
      expect(harness.chatSendStarted, isEmpty);
      await _unmountComposer(tester);
    },
  );
}
