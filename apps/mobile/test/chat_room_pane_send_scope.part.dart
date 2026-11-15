part of 'chat_room_pane_test.dart';

void _registerChatRoomPaneSendScopeTests() {
  testWidgets(
    'an outbox row that lands before the send returns replaces its stand-in',
    (tester) async {
      final heldVault = _HeldSendCredentialVault();
      final api = HttpNextcloudApi(
        client: MockClient((request) async => http.Response('', 404)),
      );
      final service = ChatService(
        accounts: accounts,
        chat: ChatRepository(database),
        credentials: heldVault,
        api: api,
      );
      addTearDown(service.close);
      addTearDown(api.close);
      await tester.pumpWidget(
        app(
          overrides: [chatServiceProvider.overrideWithValue(service)],
          home: Scaffold(
            body: ChatRoomPane(account: account, conversation: conversation),
          ),
        ),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('chat-composer')),
        'Sent once',
      );
      await tester.pump();
      heldVault.hold = true;
      await tester.tap(find.byKey(const Key('send-message-gesture')));
      await _pumpUntil(tester, () => heldVault.started.isCompleted);
      await tester.pump();
      const standIn = Key('chat-pending-provisional-1');
      const row = Key('chat-pending-op-early');
      expect(find.byKey(standIn), findsOneWidget);

      // The send is still held, so the pane has no operation id to go by.
      await tester.runAsync(
        () => _insertPendingOperation(
          database,
          account,
          conversation,
          operationId: 'op-early',
          outboxState: 'queued',
          message: 'Sent once',
        ),
      );
      for (
        var frame = 0;
        frame < 100 && find.byKey(row).evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
        expect(
          find.byKey(standIn).evaluate().length +
              find.byKey(row).evaluate().length,
          1,
          reason: 'frame $frame',
        );
      }
      expect(find.byKey(row), findsOneWidget);
      expect(find.text('Sent once'), findsOneWidget);

      heldVault.hold = false;
      heldVault.release.complete(null);
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(service.close);
      await tester.pumpAndSettle();
    },
  );

  for (final switchRoom in [false, true]) {
    for (final unexpected in [false, true]) {
      testWidgets(
        'late ${unexpected ? 'unexpected' : 'credential'} send failure after ${switchRoom ? 'room switch' : 'disposal'} cannot restore the old draft',
        (tester) async {
          final heldVault = _HeldSendCredentialVault();
          final api = HttpNextcloudApi(
            client: MockClient((request) async => http.Response('', 404)),
          );
          final service = ChatService(
            accounts: accounts,
            chat: ChatRepository(database),
            credentials: heldVault,
            api: api,
          );
          addTearDown(service.close);
          addTearDown(api.close);
          addTearDown(() {
            heldVault.hold = false;
            if (!heldVault.release.isCompleted) {
              heldVault.release.complete(null);
            }
          });
          final selected = ValueNotifier(conversation);
          addTearDown(selected.dispose);
          await tester.pumpWidget(
            app(
              overrides: [chatServiceProvider.overrideWithValue(service)],
              home: Scaffold(
                body: ValueListenableBuilder<CachedConversation>(
                  valueListenable: selected,
                  builder: (context, room, child) =>
                      ChatRoomPane(account: account, conversation: room),
                ),
              ),
            ),
          );
          await tester.pump();
          final composer = find.byKey(const Key('chat-composer'));
          await tester.enterText(composer, 'Draft from room A');
          await tester.pump();
          heldVault.hold = true;
          await tester.tap(find.byKey(const Key('send-message-gesture')));
          for (var i = 0; i < 200 && !heldVault.started.isCompleted; i++) {
            await tester.pump(const Duration(milliseconds: 10));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 1)),
            );
          }
          expect(heldVault.started.isCompleted, isTrue);
          expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
          await tester.pump();
          const standIn = Key('chat-pending-provisional-1');
          expect(find.byKey(standIn), findsOneWidget);
          final originalState = tester.state(find.byType(ChatRoomPane));
          if (switchRoom) {
            selected.value = conversation.copyWith(
              token: 'roomb456',
              displayName: 'Synthetic room B',
            );
            await tester.pump();
            expect(
              identical(tester.state(find.byType(ChatRoomPane)), originalState),
              isTrue,
            );
            expect(find.byKey(standIn), findsNothing);
          } else {
            await tester.pumpWidget(const SizedBox.shrink());
          }
          heldVault.hold = false;
          if (unexpected) {
            heldVault.release.completeError(
              StateError('credential storage failure'),
            );
          } else {
            heldVault.release.complete(null);
          }
          for (var i = 0; i < 100; i++) {
            await tester.pump(const Duration(milliseconds: 10));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 1)),
            );
          }
          expect(tester.takeException(), isNull);
          expect(find.byKey(standIn), findsNothing);
          if (switchRoom) {
            expect(
              tester.widget<TextField>(composer).controller!.text,
              isEmpty,
            );
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(service.close);
          await tester.pumpAndSettle();
        },
      );
    }
  }
}

final class _HeldSendCredentialVault implements CredentialVault {
  final stored = MemoryCredentialVault();
  final started = Completer<void>();
  final release = Completer<String?>();
  bool hold = false;

  @override
  Future<String?> readAppPassword(String accountId) {
    if (!hold) return stored.readAppPassword(accountId);
    if (!started.isCompleted) started.complete();
    return release.future;
  }

  @override
  Future<void> writeAppPassword(String accountId, String appPassword) =>
      stored.writeAppPassword(accountId, appPassword);

  @override
  Future<void> deleteAppPassword(String accountId) =>
      stored.deleteAppPassword(accountId);
}
