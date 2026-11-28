part of 'chat_composer_integration_test.dart';

void _registerDraftHandoffTests() {
  testWidgets('two open editors hand off a draft and keep concurrent edits', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final phone = (await tester.runAsync(_ComposerHarness.create))!;
    final desktop = (await tester.runAsync(_ComposerHarness.create))!;
    _addHarnessTearDown(tester, phone);
    _addHarnessTearDown(tester, desktop);
    final versions = <String, Map<String, Object?>>{};
    final reads = <String>{};
    Widget device(
      String name,
      _ComposerHarness harness,
      DraftHandoffStore store, {
      CachedConversation? conversation,
    }) => Expanded(
      key: ValueKey(name),
      child: harness.app(
        wrapInScaffold: true,
        conversation: conversation,
        overrides: [
          draftHandoffProvider.overrideWithValue(store),
          draftHandoffSupportProvider.overrideWith((_, _) async => true),
        ],
      ),
    );
    DraftHandoffStore store(String name, _ComposerHarness harness) =>
        DraftHandoffStore(({
          required accountId,
          required feature,
          required path,
          method = 'GET',
          query,
          values,
        }) async {
          if (path[1] != harness.conversation.token) return {'variants': []};
          if (method == 'PUT') {
            versions.remove(values!['baseId']);
            versions[path.last] = {'id': path.last, ...values};
          } else if (method == 'DELETE') {
            versions.remove(path.last);
          } else {
            reads.add(name);
          }
          return {'variants': versions.values.toList()};
        }, directory: harness.attachmentRoot);
    final phoneStore = store('phone', phone);
    final desktopStore = store('desktop', desktop);
    await tester.runAsync(() async {
      await phoneStore.setEnabled(phone.account.id, true);
      await desktopStore.setEnabled(desktop.account.id, true);
    });
    await tester.pumpWidget(
      Row(
        textDirection: TextDirection.ltr,
        children: [
          device('phone', phone, phoneStore),
          device('desktop', desktop, desktopStore),
        ],
      ),
    );
    Finder field(String device) => find.descendant(
      of: find.byKey(ValueKey(device)),
      matching: find.byKey(const Key('chat-composer')),
    );
    String value(String device) =>
        tester.widget<TextField>(field(device)).controller!.text;
    try {
      await _pumpUntil(tester, () => reads.length == 2);
      await tester.enterText(field('phone'), 'Start on phone');
      await tester.pump(const Duration(milliseconds: 600));
      await _pumpUntil(
        tester,
        () => versions.values.any((r) => r['text'] == 'Start on phone'),
      );
      await tester.pump(const Duration(seconds: 10));
      await _pumpUntil(tester, () => value('desktop') == 'Start on phone');
      await tester.enterText(
        field('desktop'),
        'Start on phone, finish on desktop',
      );
      await tester.pump(const Duration(milliseconds: 600));
      await _pumpUntil(
        tester,
        () => versions.values.any(
          (r) => r['text'] == 'Start on phone, finish on desktop',
        ),
      );
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await _pumpUntil(
        tester,
        () => value('phone') == 'Start on phone, finish on desktop',
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('desktop')),
          matching: find.byKey(const Key('send-message-gesture')),
        ),
      );
      await _pumpUntil(
        tester,
        () => versions.isEmpty && desktop.sentMessages.length == 1,
      );
      await tester.pump(const Duration(seconds: 10));
      await _pumpUntil(tester, () => value('phone').isEmpty);
      expect(desktop.sentMessages.single, 'Start on phone, finish on desktop');
      expect(phone.sentMessages, isEmpty);

      await tester.enterText(field('phone'), 'Phone edit');
      await tester.enterText(field('desktop'), 'Desktop edit');
      await tester.pump(const Duration(milliseconds: 600));
      await _pumpUntil(tester, () => versions.length == 2);
      await tester.pump(const Duration(seconds: 10));
      await _pumpUntil(
        tester,
        () => find.text('Choose a draft version').evaluate().length == 2,
      );
      expect(value('phone'), 'Phone edit');
      expect(value('desktop'), 'Desktop edit');
      expect(
        versions.values.map((r) => r['text']),
        unorderedEquals(['Phone edit', 'Desktop edit']),
      );
      Finder prompt(String device) => find.descendant(
        of: find.byKey(ValueKey(device)),
        matching: find.text('Choose a draft version'),
      );
      expect(
        tester.getBottomLeft(prompt('phone')).dy,
        lessThan(tester.getTopLeft(field('phone')).dy),
      );
      expect(field('phone').hitTestable(), findsOneWidget);
      await tester.tap(prompt('phone'));
      await _pumpUntil(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await _pumpTransition(tester);
      expect(prompt('phone'), findsNothing);

      final messenger = ScaffoldMessenger.of(tester.element(field('desktop')));
      messenger.showSnackBar(
        const SnackBar(content: Text('Other update'), persist: true),
      );
      versions.clear();
      await tester.pump(const Duration(seconds: 5));
      await _pumpUntil(
        tester,
        () => value('desktop').isEmpty && value('phone').isEmpty,
      );
      expect(prompt('desktop'), findsNothing);
      expect(find.text('Other update'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.enterText(field('phone'), 'Second phone edit');
      await tester.enterText(field('desktop'), 'Second desktop edit');
      await tester.pump(const Duration(milliseconds: 600));
      await _pumpUntil(tester, () => versions.length == 2);
      await tester.pump(const Duration(seconds: 6));
      await _pumpUntil(
        tester,
        () => find.text('Choose a draft version').evaluate().length == 2,
      );
      await tester.pumpWidget(
        Row(
          textDirection: TextDirection.ltr,
          children: [
            device(
              'phone',
              phone,
              phoneStore,
              conversation: phone.conversation.copyWith(token: 'roomnext'),
            ),
            device('desktop', desktop, desktopStore),
          ],
        ),
      );
      expect(prompt('phone'), findsNothing);
      expect(prompt('desktop'), findsOneWidget);
      await tester.pump(const Duration(seconds: 15));
      await _pumpTransition(tester);
      expect(prompt('desktop'), findsNothing);
      expect(prompt('phone'), findsNothing);
      expect(versions, hasLength(2));
      expect(find.text('Other update'), findsOneWidget);
    } finally {
      await _unmountComposer(tester);
    }
  });
  for (final edited in [false, true]) {
    testWidgets(
      'remote removal clears only the exact untouched draft (edited=$edited)',
      (tester) async {
        final harness = (await tester.runAsync(_ComposerHarness.create))!;
        _addHarnessTearDown(tester, harness);
        final scope = (
          accountId: harness.account.id,
          roomToken: harness.conversation.token,
          threadId: null,
        );
        final fetched = Completer<void>();
        final remoteResult = Completer<Map<String, dynamic>>();
        late final HandoffVersion original;
        var puts = 0;
        final local = DraftHandoffStore(({
          required accountId,
          required feature,
          required path,
          method = 'GET',
          query,
          values,
        }) async {
          if (method == 'PUT') {
            puts++;
            return {
              'variants': [
                {'id': path.last, ...values!},
              ],
            };
          }
          if (method == 'GET') {
            if (!fetched.isCompleted) fetched.complete();
            return remoteResult.future;
          }
          return {'variants': []};
        }, directory: harness.attachmentRoot);
        await tester.runAsync(() async {
          await local.setEnabled(scope.accountId, true);
          original = (await local.stage(scope, 'Original text', null))!;
          await local.sync(scope);
          await harness.database
              .into(harness.database.chatDrafts)
              .insert(
                ChatDraftsCompanion.insert(
                  accountId: scope.accountId,
                  roomToken: scope.roomToken,
                  scopeKey: 'root',
                  draftText: original.text,
                  updatedAtMillis: 10,
                  composerContext: const Value('{}'),
                ),
              );
        });
        await tester.pumpWidget(
          harness.app(
            wrapInScaffold: true,
            overrides: [
              draftHandoffProvider.overrideWithValue(local),
              draftHandoffSupportProvider.overrideWith((ref, id) async => true),
            ],
          ),
        );
        await _pumpUntil(
          tester,
          () => fetched.isCompleted && _composer(tester).text == original.text,
        );
        if (edited) {
          await tester.enterText(
            find.byKey(const Key('chat-composer')),
            'New local edit',
          );
        }
        remoteResult.complete({'variants': []});
        await tester.pump();
        await _pumpUntil(
          tester,
          () => _composer(tester).text == (edited ? 'New local edit' : ''),
        );
        expect(puts, 1);
        await _unmountComposer(tester);
      },
    );
  }

  for (final deleted in [false, true]) {
    testWidgets(
      'shared draft keeps its quote when opening and sending (deleted=$deleted)',
      (tester) async {
        final harness = (await tester.runAsync(_ComposerHarness.create))!;
        _addHarnessTearDown(tester, harness);
        await tester.runAsync(harness.seedReplyMessage);
        const id = 'f02194f2-e40c-47bb-8471-0730d26dc6aa';
        final calls = <String>[];
        final versions = <String, Map<String, Object?>>{
          id: {
            'id': id,
            'baseId': null,
            'text': '    Continue the answer\n\n',
            'replyTo': 109,
          },
        };
        final local = DraftHandoffStore(({
          required accountId,
          required feature,
          required path,
          method = 'GET',
          query,
          values,
        }) async {
          expect(accountId, harness.account.id);
          expect(path.take(4), [
            'room',
            harness.conversation.token,
            'drafts',
            '0',
          ]);
          final key = path.last;
          calls.add('$method:$key');
          if (method == 'PUT') {
            versions.remove(values!['baseId']);
            versions[key] = {'id': key, ...values};
          } else if (method == 'DELETE') {
            versions.remove(key);
          }
          return {'variants': versions.values.toList()};
        }, directory: harness.attachmentRoot);
        await tester.pumpWidget(
          harness.app(
            wrapInScaffold: true,
            overrides: [
              draftHandoffProvider.overrideWithValue(local),
              draftHandoffSupportProvider.overrideWith((ref, id) async => true),
            ],
          ),
        );
        await _pumpUntil(
          tester,
          () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
        );
        expect(calls, isEmpty);
        await _openComposerMenu(tester);
        await tester.tap(find.byKey(const Key('draft-handoff')));
        await _pumpTransition(tester);
        final toggle = find.byKey(const Key('enable-draft-handoff'));
        await _pumpUntil(
          tester,
          () =>
              toggle.evaluate().isNotEmpty &&
              tester.widget<SwitchListTile>(toggle).onChanged != null,
        );
        await tester.tap(toggle);
        await _pumpUntil(
          tester,
          () => find.byKey(const ValueKey('handoff-$id')).evaluate().isNotEmpty,
        );
        await tester.tap(find.byKey(const ValueKey('handoff-$id')));
        await _pumpUntil(
          tester,
          () =>
              _composer(tester).text == '    Continue the answer\n\n' &&
              find.byKey(const Key('chat-reply-banner')).evaluate().isNotEmpty,
        );
        if (deleted) {
          await tester.runAsync(
            () =>
                (harness.database.update(
                  harness.database.cachedChatMessages,
                )..where((r) => r.messageId.equals(109))).write(
                  const CachedChatMessagesCompanion(deleted: Value(true)),
                ),
          );
        }
        await tester.tap(find.byKey(const Key('send-message-gesture')));
        if (deleted) {
          await _pumpUntil(
            tester,
            () => find
                .textContaining('The quoted message is no longer available')
                .evaluate()
                .isNotEmpty,
          );
          expect(harness.chatSendFields, isEmpty);
          expect(_composer(tester).text, '    Continue the answer\n\n');
          expect(versions.keys, contains(id));
        } else {
          await _pumpUntil(
            tester,
            () =>
                harness.chatSendFields.isNotEmpty &&
                calls.contains('DELETE:$id'),
          );
          expect(harness.chatSendFields.single['replyTo'], '109');
          expect(versions, isEmpty);
          expect(calls.where((call) => call.startsWith('PUT:')), isEmpty);
        }
        await _unmountComposer(tester);
      },
    );
  }
}
