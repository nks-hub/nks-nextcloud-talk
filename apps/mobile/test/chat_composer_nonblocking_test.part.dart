part of 'chat_composer_integration_test.dart';

void _registerNonBlockingComposerTests() {
  for (final (extension, prefix) in [
    ('md', '# Notes\n\n'),
    ('txt', ''),
    ('dart', "import 'package:flutter/widgets.dart';\n"),
  ]) {
    testWidgets(
      'long pasted $extension waits for send and preserves all bytes',
      (tester) async {
        final harness = (await tester.runAsync(_ComposerHarness.create))!;
        _addHarnessTearDown(tester, harness);
        await tester.pumpWidget(harness.app());
        await _pumpUntil(tester, () {
          final media = find.byType(ChatMediaComposer);
          return media.evaluate().isNotEmpty &&
              tester
                  .widget<ChatMediaComposer>(media)
                  .controller!
                  .canAttachBytes;
        });
        final controller = tester
            .widget<ChatMediaComposer>(find.byType(ChatMediaComposer))
            .controller!;
        final source = '$prefix${'Příloha ' * 700}';
        await tester.enterText(
          find.byKey(const Key('chat-composer')),
          'caption',
        );
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: 'caption$source',
            selection: TextSelection.collapsed(offset: 7 + source.length),
          ),
        );
        await _pumpUntil(tester, () => controller.hasPreparedAttachment);
        expect(_composer(tester).text, 'caption');
        expect(harness.uploadedAttachments, isEmpty);
        await tester.tap(find.byKey(const Key('send-message-gesture')));
        await _pumpUntil(tester, () => harness.finalizedFileNames.isNotEmpty);
        expect(harness.finalizedFileNames.single, endsWith('.$extension'));
        expect(utf8.decode(harness.uploadedAttachments.single), source);
        expect(tester.takeException(), isNull);
        await _unmountComposer(tester);
      },
    );
  }

  testWidgets(
    'a reply hands its stand-in over to its outbox row',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      await tester.runAsync(harness.seedReplyMessage);
      final hold = Completer<void>();
      harness.chatSendHold.add(hold);
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });

      await tester.pumpWidget(harness.app());
      await _pumpUntil(
        tester,
        () =>
            find
                .byKey(const Key('chat-message-target-109'))
                .evaluate()
                .isNotEmpty &&
            find.byType(ChatMediaComposer).evaluate().isNotEmpty,
      );
      await tester.longPress(find.byKey(const Key('chat-message-target-109')));
      await _pumpTransition(tester);
      await tester.tap(find.byKey(const Key('message-action-reply')));
      await _pumpTransition(tester);
      await tester.enterText(
        find.byKey(const Key('chat-composer')),
        'reply line',
      );
      await _pumpUntil(tester, () => _sendButtonEnabled(tester));
      await tester.tap(find.byKey(const Key('send-message-gesture')));
      await tester.pump();
      const standIn = Key('chat-pending-provisional-1');
      expect(find.byKey(standIn), findsOneWidget);

      // A reply is stored under the message it answers, outside the room's
      // own outbox stream. The stand-in waited for a row that never came and
      // stayed "Waiting to send" under a message long delivered.
      await _pumpUntil(tester, () => harness.chatSendStarted.length == 1);
      expect(harness.chatSendFields.single['replyTo'], '109');
      await _pumpUntil(tester, () => find.byKey(standIn).evaluate().isEmpty);
      final row = (await tester.runAsync(
        harness.database.select(harness.database.textSendOperations).getSingle,
      ))!;
      expect(row.replyTo, 109);
      expect(
        find.byKey(Key('chat-pending-${row.operationId}')),
        findsOneWidget,
      );
      expect(find.text('reply line'), findsOneWidget);
      expect(find.text('Sending…'), findsOneWidget);
      expect(find.text('Waiting to send'), findsNothing);

      hold.complete();
      await _pumpUntil(tester, () => harness.sentMessages.length == 1);
      await _pumpTransition(tester);
      expect(find.byKey(standIn), findsNothing);
      expect(harness.sentMessages, ['reply line']);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

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
          () => (harness.database.select(
            harness.database.textSendOperations,
          )..orderBy([(row) => OrderingTerm.asc(row.enqueueSequence)])).get(),
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
      await _pumpUntil(
        tester,
        () => harness.attachmentUploadStarted.isNotEmpty,
      );

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

  testWidgets(
    'lines typed while the first is still being admitted queue up in order',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      await tester.pumpWidget(harness.app());
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
      );
      // Admission starts with a read of the stored password. Held, the first
      // line never reaches the outbox, which is what a slow device looks like
      // to the composer. The server is not asked before the write any more.
      final hold = Completer<void>();
      harness.admissionHold.add(hold);
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });

      for (final line in ['one', 'two', 'three']) {
        await _typeAndSend(tester, line);
        await _pumpUntil(
          tester,
          () => _composer(tester).text.isEmpty && _sendButtonEnabled(tester),
        );
      }
      expect(harness.chatSendStarted, isEmpty);

      hold.complete();
      await _pumpUntil(tester, () => harness.sentMessages.length == 3);

      expect(harness.chatSendStarted, ['one', 'two', 'three']);
      expect(harness.sentMessages, ['one', 'two', 'three']);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'a line that dies on the wire holds the later ones in order behind it',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      harness.chatSendFailures.add('one');
      await tester.pumpWidget(harness.app());
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
      );

      for (final line in ['one', 'two', 'three']) {
        await _typeAndSend(tester, line);
        await _pumpUntil(
          tester,
          () => _composer(tester).text.isEmpty && _sendButtonEnabled(tester),
        );
      }
      await _pumpUntil(tester, () => harness.chatSendStarted.isNotEmpty);
      // Room for a wrongly released second line to show up on the wire.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      final rows = (await tester.runAsync(
        () => (harness.database.select(
          harness.database.textSendOperations,
        )..orderBy([(row) => OrderingTerm.asc(row.enqueueSequence)])).get(),
      ))!;

      // The failed line stays in the outbox, unresolved and retryable, and the
      // two after it are not sent past it: they would reach the chat before it.
      expect(rows.map((row) => row.message), ['one', 'two', 'three']);
      expect(rows.first.outboxState, isNot('completed'));
      expect(rows.skip(1).map((row) => row.outboxState), ['queued', 'queued']);
      expect(harness.chatSendStarted, ['one']);
      expect(harness.sentMessages, isEmpty);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'a double tap on send admits the line once',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      await tester.pumpWidget(harness.app());
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
      );
      await tester.enterText(find.byKey(const Key('chat-composer')), 'once');
      await tester.pump();
      final send = find.byKey(const Key('send-message-gesture'));
      await tester.tap(send);
      await tester.tap(send);
      await _pumpUntil(tester, () => harness.sentMessages.isNotEmpty);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }

      expect(harness.sentMessages, ['once']);
      expect(_composer(tester).text, isEmpty);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'only the first line typed after choosing a reply is a reply',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      await tester.runAsync(harness.seedReplyMessage);
      await tester.pumpWidget(harness.app());
      await _pumpUntil(
        tester,
        () =>
            find
                .byKey(const Key('chat-message-target-109'))
                .evaluate()
                .isNotEmpty &&
            find.byType(ChatMediaComposer).evaluate().isNotEmpty,
      );
      await tester.longPress(find.byKey(const Key('chat-message-target-109')));
      await _pumpTransition(tester);
      await tester.tap(find.byKey(const Key('message-action-reply')));
      await _pumpTransition(tester);
      expect(find.byKey(const Key('chat-reply-banner')), findsOneWidget);

      final hold = Completer<void>();
      harness.admissionHold.add(hold);
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });
      for (final line in ['answer', 'follow-up']) {
        await _typeAndSend(tester, line);
        await _pumpUntil(
          tester,
          () => _composer(tester).text.isEmpty && _sendButtonEnabled(tester),
        );
      }
      expect(find.byKey(const Key('chat-reply-banner')), findsNothing);

      hold.complete();
      var rows = const <StoredTextSendOperation>[];
      for (var attempt = 0; attempt < 600 && rows.length < 2; attempt++) {
        await tester.pump(const Duration(milliseconds: 10));
        rows = (await tester.runAsync(
          () => (harness.database.select(
            harness.database.textSendOperations,
          )..orderBy([(row) => OrderingTerm.asc(row.enqueueSequence)])).get(),
        ))!;
      }

      // The banner went with the first line, so the second is a plain message
      // and not another reply to the same one.
      expect(rows.map((row) => row.message), ['answer', 'follow-up']);
      expect(rows.map((row) => row.replyTo), [109, null]);
      // The request follows the write; it no longer comes before it.
      await _pumpUntil(tester, () => harness.chatSendFields.isNotEmpty);
      expect(harness.chatSendFields.first['replyTo'], '109');
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'lines waiting for admission show as pending bubbles at once, in order, '
    'and are replaced one for one',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      await tester.pumpWidget(harness.app());
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
      );
      final hold = Completer<void>();
      harness.admissionHold.add(hold);
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });

      for (final line in ['one', 'two', 'three']) {
        await _typeAndSend(tester, line);
      }
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('chat-pending-provisional-3'))
            .evaluate()
            .isNotEmpty,
      );

      // Nothing has been admitted, yet all three are on screen, newest last.
      expect(harness.chatSendStarted, isEmpty);
      expect(find.text('Waiting to send'), findsNWidgets(3));
      final tops = [
        for (final line in ['one', 'two', 'three'])
          tester.getTopLeft(find.text(line)).dy,
      ];
      expect(tops, orderedEquals([...tops]..sort()));
      expect(tops.toSet(), hasLength(3));

      hold.complete();
      // Frame by frame, no line is ever drawn twice: not as its stand-in next
      // to its outbox row, and not as the row next to the message it became.
      void expectNoDuplicates() {
        for (final line in ['one', 'two', 'three']) {
          expect(find.text(line).evaluate().length, lessThanOrEqualTo(1));
        }
      }

      for (var i = 0; i < 400 && harness.sentMessages.length < 3; i++) {
        await tester.pump(const Duration(milliseconds: 5));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
        expectNoDuplicates();
      }
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        expectNoDuplicates();
      }

      // The stand-ins are gone and the server saw each line once.
      expect(find.byKey(const Key('chat-pending-provisional-1')), findsNothing);
      expect(find.byKey(const Key('chat-pending-provisional-3')), findsNothing);
      expect(harness.sentMessages, ['one', 'two', 'three']);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'a refused admission takes the stand-in away and gives the text back',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      await tester.pumpWidget(harness.app());
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
      );
      final hold = Completer<void>();
      harness.admissionHold.add(hold);
      harness.admissionRefused = true;
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });

      await _typeAndSend(tester, 'not lost');
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('chat-pending-provisional-1'))
            .evaluate()
            .isNotEmpty,
      );
      expect(_composer(tester).text, isEmpty);

      hold.complete();
      await _pumpUntil(tester, () => _composer(tester).text == 'not lost');

      expect(find.byKey(const Key('chat-pending-provisional-1')), findsNothing);
      expect(harness.chatSendStarted, isEmpty);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'a refused reply survives reopening alongside the new draft and retries once',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      await tester.runAsync(harness.seedReplyMessage);
      await tester.pumpWidget(harness.app());
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
      );
      final parent = find.byKey(const Key('chat-message-target-109'));
      await _pumpUntil(tester, () => parent.evaluate().isNotEmpty);
      await tester.longPress(parent);
      await _pumpTransition(tester);
      await tester.tap(find.byKey(const Key('message-action-reply')));
      await _pumpTransition(tester);
      final hold = Completer<void>();
      harness.admissionHold.add(hold);
      harness.admissionRefused = true;
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });

      await _typeAndSend(tester, 'first');
      await tester.enterText(
        find.byKey(const Key('chat-composer')),
        'typed meanwhile',
      );
      await tester.pump();
      hold.complete();
      await _pumpUntil(
        tester,
        () => find.text('Message could not be sent').evaluate().isNotEmpty,
      );

      // The new draft is untouched and the refused line is still on screen.
      expect(_composer(tester).text, 'typed meanwhile');
      expect(find.text('first'), findsOneWidget);
      expect(harness.chatSendStarted, isEmpty);

      final saved = (await tester.runAsync(
        harness.database.select(harness.database.refusedTextDrafts).getSingle,
      ))!;
      expect(saved.replyTo, 109);
      expect(saved.threadId, isNull);
      expect(saved.message, 'first');
      expect(saved.roomToken, harness.conversation.token);
      expect(saved.accountId, harness.account.id);
      await _unmountComposer(tester);
      harness.admissionRefused = false;
      await tester.pumpWidget(harness.app());
      final retry = find.byKey(
        Key('chat-retry-refused-draft-${saved.draftId}'),
      );
      await _pumpUntil(
        tester,
        () =>
            retry.hitTestable().evaluate().isNotEmpty &&
            _composer(tester).text == 'typed meanwhile',
      );
      expect(harness.chatSendStarted, isEmpty);
      await tester.tap(retry);
      await _pumpUntil(tester, () => harness.sentMessages.isNotEmpty);
      expect(harness.sentMessages, ['first']);
      expect(harness.chatSendFields.single['replyTo'], '109');
      expect(_composer(tester).text, 'typed meanwhile');
      expect(
        await tester.runAsync(
          harness.database.select(harness.database.refusedTextDrafts).get,
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'a draft that could not be written warns and can be retried when storage returns',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      final clipboard = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(harness.app(wrapInScaffold: true));
      final field = find.byKey(const Key('chat-composer'));
      await _pumpUntil(tester, () => field.evaluate().isNotEmpty);
      await tester.runAsync(
        () => harness.database.customStatement(
          "CREATE TRIGGER disk_full BEFORE INSERT ON refused_text_drafts BEGIN SELECT RAISE(ABORT, 'full'); END",
        ),
      );
      await _typeAndSend(tester, 'waiting for storage');
      await tester.enterText(field, 'newer text');
      await _pumpUntil(
        tester,
        () => find
            .textContaining('could not be saved on this device')
            .evaluate()
            .isNotEmpty,
      );
      expect(harness.chatSendStarted, isEmpty);
      expect(clipboard, isEmpty);
      await tester.tap(find.byTooltip('Copy text'));
      await tester.pump();
      expect(clipboard, ['waiting for storage']);
      expect(_composer(tester).text, 'newer text');
      expect(
        await tester.runAsync(
          harness.database.select(harness.database.refusedTextDrafts).get,
        ),
        isEmpty,
      );
      await tester.runAsync(
        () => harness.database.customStatement('DROP TRIGGER disk_full'),
      );
      await tester.tap(find.byTooltip('Retry sending'));
      await _pumpUntil(tester, () => harness.sentMessages.isNotEmpty);
      expect(harness.sentMessages, ['waiting for storage']);
      expect(_composer(tester).text, 'newer text');
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
  );

  for (final changeReply in [true, false]) {
    testWidgets(
      changeReply
          ? 'a new reply selection cannot take over refused plain text'
          : 'a failed transfer back to the composer leaves only one sendable copy',
      (tester) async {
        final harness = (await tester.runAsync(_ComposerHarness.create))!;
        _addHarnessTearDown(tester, harness);
        await tester.runAsync(harness.seedReplyMessage);
        await tester.pumpWidget(harness.app());
        final parent = find.byKey(const Key('chat-message-target-109'));
        await _pumpUntil(tester, () => parent.evaluate().isNotEmpty);
        final hold = Completer<void>();
        harness.admissionHold.add(hold);
        harness.admissionRefused = true;
        addTearDown(() {
          if (!hold.isCompleted) hold.complete();
        });
        await _typeAndSend(tester, 'original');
        if (changeReply) {
          await tester.longPress(parent);
          await _pumpTransition(tester);
          await tester.tap(find.byKey(const Key('message-action-reply')));
          await _pumpTransition(tester);
        } else {
          await tester.runAsync(
            () => harness.database.customStatement(
              "CREATE TRIGGER reject_restore BEFORE INSERT ON chat_drafts BEGIN SELECT RAISE(ABORT, 'write refused'); END",
            ),
          );
        }
        hold.complete();
        final retry = find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'chat-retry-refused-draft-',
              ),
        );
        await _pumpUntil(
          tester,
          () => retry.hitTestable().evaluate().isNotEmpty,
        );
        expect(_composer(tester).text, isEmpty);
        if (changeReply) {
          expect(find.byKey(const Key('chat-reply-banner')), findsOneWidget);
        }
        harness.admissionRefused = false;
        await tester.tap(retry);
        await _pumpUntil(tester, () => harness.sentMessages.isNotEmpty);
        expect(harness.sentMessages, ['original']);
        expect(harness.chatSendFields.single.containsKey('replyTo'), isFalse);
        expect(
          await tester.runAsync(
            harness.database.select(harness.database.refusedTextDrafts).get,
          ),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
        await _unmountComposer(tester);
      },
    );
  }

  testWidgets(
    'the composer keeps focus and the keyboard through a send and its bubble',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      await tester.pumpWidget(harness.app(inRoomScreen: true));
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
      );
      final hold = Completer<void>();
      harness.admissionHold.add(hold);
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });
      final focus = tester
          .widget<TextField>(find.byKey(const Key('chat-composer')))
          .focusNode!;

      await _typeAndSend(tester, 'one');
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('chat-pending-provisional-1'))
            .evaluate()
            .isNotEmpty,
      );
      expect(focus.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      // The next line goes in without tapping the field again.
      tester.testTextInput.enterText('two');
      await tester.pump();
      await tester.tap(find.byKey(const Key('send-message-gesture')));
      await tester.pump();
      expect(_composer(tester).text, isEmpty);
      expect(focus.hasFocus, isTrue);

      hold.complete();
      await _pumpUntil(tester, () => harness.sentMessages.length == 2);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }

      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-composer')))
            .focusNode,
        same(focus),
      );
      expect(focus.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(harness.sentMessages, ['one', 'two']);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  // The framework drops the field's focus, and the soft keyboard with it, for
  // a pointer-down outside the field from a mouse, a stylus or a device of
  // unknown kind. adb's `input tap` is the last: it reported every send tap on
  // a phone as one that closed the keyboard.
  for (final kind in [
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.unknown,
  ]) {
    testWidgets(
      'a ${kind.name} tap on send leaves the focus and keyboard on the composer',
      (tester) async {
        final harness = (await tester.runAsync(_ComposerHarness.create))!;
        _addHarnessTearDown(tester, harness);
        await tester.pumpWidget(harness.app(inRoomScreen: true));
        await _pumpUntil(
          tester,
          () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
        );
        final focus = tester
            .widget<TextField>(find.byKey(const Key('chat-composer')))
            .focusNode!;
        await tester.enterText(find.byKey(const Key('chat-composer')), 'one');
        await tester.pump();
        expect(focus.hasFocus, isTrue);

        await tester.tap(
          find.byKey(const Key('send-message-gesture')),
          kind: kind,
        );
        await tester.pump();
        expect(_composer(tester).text, isEmpty);
        expect(focus.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        await _pumpUntil(tester, () => harness.sentMessages.length == 1);
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 10));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        expect(focus.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        expect(tester.takeException(), isNull);
        await _unmountComposer(tester);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }

  testWidgets(
    'a line sent just before the app is left stays in the draft until the '
    'outbox holds it',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      await tester.pumpWidget(harness.app());
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
      );
      final hold = Completer<void>();
      harness.admissionHold.add(hold);
      var away = false;
      void setAway(bool value) {
        if (away == value) return;
        away = value;
        for (final state
            in value
                ? const [
                    AppLifecycleState.inactive,
                    AppLifecycleState.hidden,
                    AppLifecycleState.paused,
                  ]
                : const [
                    AppLifecycleState.hidden,
                    AppLifecycleState.inactive,
                    AppLifecycleState.resumed,
                  ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
      }

      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
        setAway(false);
      });
      Future<String?> storedDraft() => tester.runAsync<String?>(
        () async =>
            (await harness.database
                    .select(harness.database.refusedTextDrafts)
                    .getSingleOrNull())
                ?.message,
      );
      Future<List<StoredTextSendOperation>> outbox() async =>
          (await tester.runAsync(
            () => harness.database
                .select(harness.database.textSendOperations)
                .get(),
          ))!;

      await _typeAndSend(tester, 'on the way out');
      await _pumpUntil(tester, () => _composer(tester).text.isEmpty);

      // HOME, before the outbox accepts the message.
      setAway(true);
      String? draft;
      for (var attempt = 0; attempt < 200 && draft == null; attempt++) {
        await tester.pump(const Duration(milliseconds: 10));
        draft = await storedDraft();
      }
      expect(draft, 'on the way out');
      expect(await outbox(), isEmpty);

      hold.complete();
      for (var attempt = 0; attempt < 600 && draft != null; attempt++) {
        await tester.pump(const Duration(milliseconds: 10));
        draft = await storedDraft();
      }
      expect(draft, isNull, reason: 'the outbox holds the line now');
      expect((await outbox()).single.message, 'on the way out');
      expect(tester.takeException(), isNull);
      // A paused app draws no frame, and the unmount below needs one.
      setAway(false);
      await _unmountComposer(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

Future<void> _typeAndSend(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('chat-composer')), text);
  await tester.pump();
  await tester.tap(find.byKey(const Key('send-message-gesture')));
  await tester.pump();
}
