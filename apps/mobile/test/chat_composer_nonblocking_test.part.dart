part of 'chat_composer_integration_test.dart';

void _registerNonBlockingComposerTests() {
  testWidgets(
    'the composer is free again while the first line is still on the wire',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      final hold = Completer<void>();
      harness.chatSendHold.add(hold);
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });

      await tester.pumpWidget(harness.app());
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
      );

      await tester.enterText(
        find.byKey(const Key('chat-composer')),
        'first line',
      );
      await _pumpUntil(tester, () => _sendButtonEnabled(tester));
      await tester.tap(find.byKey(const Key('send-message-gesture')));

      // The request is open and unanswered, and the composer is already usable
      // again: the send is durable in the outbox, which is what the field was
      // waiting for. Before that it stayed disabled for the whole round trip.
      await _pumpUntil(
        tester,
        () =>
            harness.chatSendStarted.length == 1 &&
            _composer(tester).text.isEmpty &&
            _sendButtonEnabled(tester),
      );

      await tester.enterText(
        find.byKey(const Key('chat-composer')),
        'second line',
      );
      await _pumpUntil(tester, () => _sendButtonEnabled(tester));
      await tester.tap(find.byKey(const Key('send-message-gesture')));

      // Admission is a database write, so the second row is what says the tap
      // was taken; the field itself empties before that.
      var queued = const <StoredTextSendOperation>[];
      for (var attempt = 0; attempt < 600 && queued.length < 2; attempt++) {
        await tester.pump(const Duration(milliseconds: 10));
        queued = (await tester.runAsync(
          () =>
              (harness.database.select(harness.database.textSendOperations)
                    ..orderBy([(row) => OrderingTerm.asc(row.enqueueSequence)]))
                  .get(),
        ))!;
      }
      expect(queued.map((row) => row.message), ['first line', 'second line']);
      // The second line is queued, not racing: it waits for the unresolved
      // first one instead of overtaking it.
      expect(harness.chatSendStarted, ['first line']);

      hold.complete();
      await _pumpUntil(tester, () => harness.sentMessages.length == 2);

      expect(harness.chatSendStarted, ['first line', 'second line']);
      expect(harness.sentMessages, ['first line', 'second line']);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'text sent during an upload is not held by it',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      final upload = Completer<void>();
      harness.attachmentUploadHold.add(upload);
      addTearDown(() {
        if (!upload.isCompleted) upload.complete();
      });

      await tester.pumpWidget(harness.app());
      await _pumpUntil(
        tester,
        () =>
            find.byType(ChatMediaComposer).evaluate().isNotEmpty &&
            find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
      );
      final controller = tester
          .widget<ChatMediaComposer>(find.byType(ChatMediaComposer))
          .controller!;
      expect(
        await tester.runAsync(
          () => controller.attachImageBytes(
            _animatedGif,
            mimeType: 'image/gif',
            displayName: 'held-upload.gif',
          ),
        ),
        isTrue,
      );
      await _pumpUntil(tester, () => controller.hasPreparedAttachment);
      await _pumpUntil(tester, () => _sendButtonEnabled(tester));
      await tester.tap(find.byKey(const Key('send-message-gesture')));
      await _pumpUntil(tester, () => harness.attachmentUploadStarted.isNotEmpty);

      // The upload is on the wire and unfinished. Text typed now goes out on
      // its own queue rather than waiting for the file, and it keeps its place
      // among the text sends.
      await _pumpUntil(tester, () => _sendButtonEnabled(tester));
      await tester.enterText(
        find.byKey(const Key('chat-composer')),
        'a line during the upload',
      );
      await _pumpUntil(tester, () => _sendButtonEnabled(tester));
      await tester.tap(find.byKey(const Key('send-message-gesture')));
      await _pumpUntil(tester, () => harness.sentMessages.isNotEmpty);

      expect(harness.sentMessages, ['a line during the upload']);
      expect(harness.uploadedAttachments, isEmpty);
      expect(harness.finalizedFileNames, isEmpty);

      upload.complete();
      await _pumpUntil(tester, () => harness.finalizedFileNames.isNotEmpty);

      expect(harness.finalizedFileNames.single, 'held-upload.gif');
      expect(harness.sentMessages, ['a line during the upload']);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
