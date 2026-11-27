part of 'chat_composer_integration_test.dart';

void _registerDraftHandoffTests() {
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
