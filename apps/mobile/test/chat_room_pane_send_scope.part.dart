part of 'chat_room_pane_test.dart';

void _registerChatRoomPaneSendScopeTests() {
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
