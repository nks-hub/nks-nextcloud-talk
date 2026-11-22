part of 'chat_composer_integration_test.dart';

const _ShortComposerGeometry _s21LandscapeComposerGeometry = (
  name: 'Galaxy S21 landscape',
  physicalSize: Size(2400, 1080),
  pixelRatio: 3,
  topPadding: 72,
  keyboard: 594,
  visibleHeight: 486,
  attachment: false,
);

void _registerCompactReplyComposerTest() {
  testWidgets(
    'Galaxy S21 landscape can send and cancel a reply above the keyboard',
    (tester) async {
      const geometry = _s21LandscapeComposerGeometry;
      tester.view.devicePixelRatio = geometry.pixelRatio;
      tester.view.physicalSize = geometry.physicalSize;
      tester.view.padding = FakeViewPadding(top: geometry.topPadding);
      tester.view.viewPadding = FakeViewPadding(top: geometry.topPadding);
      tester.view.viewInsets = FakeViewPadding.zero;
      addTearDown(tester.view.reset);

      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      await tester.runAsync(harness.seedReplyMessage);
      await tester.pumpWidget(harness.app(inRoomScreen: true));

      final banner = find.byKey(const Key('chat-reply-banner'));
      final cancel = find.byKey(const Key('chat-cancel-reply'));
      final composer = find.byKey(const Key('chat-composer'));
      final editable = find.descendant(
        of: composer,
        matching: find.byType(EditableText),
      );
      final media = find.byType(ChatMediaComposer);
      final replyText = find.descendant(
        of: banner,
        matching: find.byType(Text),
      );
      final send = find.byKey(const Key('send-message-gesture'));

      try {
        await _pumpUntil(
          tester,
          () => composer.evaluate().isNotEmpty && media.evaluate().isNotEmpty,
        );
        await _selectCompactTestReply(tester);
        expect(banner, findsOneWidget);
        final expandedText = tester
            .widgetList<Text>(replyText)
            .map((text) => text.data!)
            .toList();
        expect(expandedText, hasLength(2));

        const draft = 'A reply\nstill goes out';
        await tester.enterText(composer, draft);
        await tester.pump();
        final editableElement = tester.element(editable);
        final mediaElement = tester.element(media);

        Future<void> resize(double bottomInset) async {
          tester.view.viewInsets = FakeViewPadding(bottom: bottomInset);
          await _pumpTransition(tester);
          expect(tester.element(editable), same(editableElement));
          expect(tester.element(media), same(mediaElement));
        }

        final visibleBottom = geometry.visibleHeight / geometry.pixelRatio;
        await resize(geometry.keyboard);
        expect(tester.takeException(), isNull);
        expect(tester.getRect(banner).bottom, lessThanOrEqualTo(visibleBottom));
        final compactText = tester.widget<Text>(replyText);
        expect(compactText.maxLines, 1);
        for (final line in expandedText) {
          expect(compactText.data, contains(line));
        }
        for (final action in [send, cancel]) {
          expect(action.hitTestable(), findsOneWidget);
          final bounds = tester.getRect(action);
          expect(bounds.width, greaterThanOrEqualTo(48));
          expect(bounds.height, greaterThanOrEqualTo(48));
          expect(bounds.bottom, lessThanOrEqualTo(visibleBottom));
        }

        await resize(0);
        expect(
          tester.widgetList<Text>(replyText).map((text) => text.data),
          orderedEquals(expandedText),
        );
        expect(_composer(tester).text, draft);

        await resize(geometry.keyboard);
        await tester.tap(cancel);
        await tester.pump();
        expect(banner, findsNothing);
        expect(_composer(tester).text, draft);
        expect(harness.sentMessages, isEmpty);

        await resize(0);
        await _selectCompactTestReply(tester);
        await resize(geometry.keyboard);
        expect(send.hitTestable(), findsOneWidget);
        await tester.tap(send);
        await _pumpUntil(
          tester,
          () => harness.sentMessages.isNotEmpty && banner.evaluate().isEmpty,
        );
        expect(harness.sentMessages, [draft]);
        expect(harness.chatSendFields.single['replyTo'], '109');
        await resize(0);
        expect(_composer(tester).text, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        tester.view.viewInsets = FakeViewPadding.zero;
        await _unmountComposer(tester);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

Future<void> _selectCompactTestReply(WidgetTester tester) async {
  final message = find.byKey(const Key('chat-message-target-109'));
  await _pumpUntil(tester, () => message.hitTestable().evaluate().isNotEmpty);
  await tester.longPress(message);
  await _pumpTransition(tester);
  await tester.tap(find.byKey(const Key('message-action-reply')));
  await _pumpTransition(tester);
}
