part of 'conversation_shell_entry_points_test.dart';

void _registerWindowsInboxTests(
  Future<StoredAccount> Function(AppDatabase) seed,
  Widget Function(
    AppDatabase,
    StoredAccount,
    List<CachedConversation>,
    Set<ChatRoomProviderKey>,
  )
  shell,
) {
  for (final width in [590.0, 1280.0]) {
    final layout = width == 590 ? '590 px window' : '317 px sidebar';
    testWidgets(
      'Windows $layout keeps the inbox controls on two rows',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 620);
        addTearDown(tester.view.reset);
        final database = openTestDatabase();
        addTearDown(database.close);
        final account = (await tester.runAsync(() => seed(database)))!;
        final observed = <ChatRoomProviderKey>{};
        await tester.pumpWidget(
          shell(database, account, [
            _conversation(account.id, 'group', displayName: 'Pracovní skupina'),
            _conversation(
              account.id,
              'notes',
              displayName: 'Poznámka pro mne',
              roomType: 6,
            ).copyWith(favorite: true),
            _conversation(account.id, 'archive', archived: true),
          ], observed),
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        });
        Finder byKey(String key) => find.byKey(Key(key));
        final group = byKey('conversation-tile-group');
        await pumpUntilCondition(tester, () => group.evaluate().isNotEmpty);
        if (width > 590) {
          final container = ProviderScope.containerOf(tester.element(group));
          container.read(conversationListWidthProvider.notifier).preview(317);
          await tester.pump();
          expect(tester.getSize(byKey('conversation-list-pane')).width, 317);
        }
        final heading = byKey('inbox-heading');
        final compose = byKey('open-new-conversation');
        final refresh = byKey('refresh-conversations');
        final search = byKey('conversation-name-search');
        final note = byKey('favorite-room-notes');
        final globalSearch = byKey('open-message-search');
        final filters = byKey('conversation-filter-menu');
        expect(tester.widget<Text>(heading).data, 'Zprávy');
        for (final action in [compose, refresh]) {
          expect(action.hitTestable(), findsOneWidget);
          expect(
            tester.getCenter(action).dy,
            closeTo(tester.getCenter(heading).dy, 1),
          );
        }
        for (final action in [note, globalSearch, filters]) {
          expect(action.hitTestable(), findsOneWidget);
          expect(
            tester.getCenter(action).dy,
            closeTo(tester.getCenter(search).dy, 1),
          );
        }
        expect(
          tester.getTopLeft(group).dy - tester.getBottomLeft(search).dy,
          inInclusiveRange(0, 16),
        );

        await tester.enterText(search, 'Pracovní');
        await tester.pump();
        expect(group, findsOneWidget);
        expect(byKey('conversation-tile-notes'), findsNothing);
        await tester.enterText(search, '');
        await tester.pump();
        await tester.tap(filters);
        await tester.pumpAndSettle();
        expect(find.text('Archivované').hitTestable(), findsOneWidget);
        await tester.tap(find.text('Archivované'));
        await tester.pumpAndSettle();
        expect(group, findsNothing);
        expect(byKey('conversation-tile-archive'), findsOneWidget);
        await tester.tap(find.text('Vše'));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(group, findsOneWidget);
        await tester.tap(note);
        await pumpUntilCondition(
          tester,
          () => observed.any((key) => key.roomToken == 'notes'),
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
}
