part of 'room_details_screen_test.dart';

void _registerBackgroundTests() {
  testWidgets('chat background colour is stored for only this room', (
    tester,
  ) async {
    final key = (accountId: account.id, roomToken: conversation.token);
    final store = _temporaryBackgroundStore(tester);
    await openDetails(
      tester,
      forAccount: account,
      forConversation: conversation,
      client: participantsClient(const <Object?>[]),
      overrides: [
        chatBackgroundStoreProvider.overrideWith((ref) async => store),
        chatBackgroundProvider(key).overrideWith((ref) => store.watch(key)),
      ],
    );
    await tester.tap(find.byKey(const Key('room-details-chat-background')));
    await tester.tap(find.byKey(const Key('room-details-chat-background')));
    await _pumpUntil(
      tester,
      () =>
          find.byKey(const Key('chat-background-field')).evaluate().isNotEmpty,
    );
    expect(find.byKey(const Key('chat-background-dialog')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('chat-background-field')),
      '#FF00FF',
    );
    await tester.tap(find.byKey(const Key('chat-background-save')));
    await _pumpUntil(
      tester,
      () =>
          _textByKey(tester, 'room-details-chat-background-subtitle') ==
          '#FF00FF',
    );

    expect(
      _textByKey(tester, 'room-details-chat-background-subtitle'),
      '#FF00FF',
    );
    final stored = await tester.runAsync(() => store.read(key));
    final otherRoom = await tester.runAsync(
      () => store.read((accountId: account.id, roomToken: 'other123')),
    );
    expect(stored, '#FF00FF');
    expect(otherRoom, isNull);

    await tester.tap(
      find.byKey(const Key('room-details-chat-background-reset')),
    );
    await _pumpUntil(
      tester,
      () =>
          _textByKey(tester, 'room-details-chat-background-subtitle') ==
          'Follow bright or dark mode',
    );
    expect(await tester.runAsync(() => store.read(key)), isNull);
  });

  testWidgets('invalid chat background is rejected without replacing state', (
    tester,
  ) async {
    final key = (accountId: account.id, roomToken: conversation.token);
    final store = _temporaryBackgroundStore(tester);
    await tester.runAsync(() => store.write(key, '#123456'));

    await openDetails(
      tester,
      forAccount: account,
      forConversation: conversation,
      client: participantsClient(const <Object?>[]),
      overrides: [
        chatBackgroundStoreProvider.overrideWith((ref) async => store),
        chatBackgroundProvider(key).overrideWith((ref) => store.watch(key)),
      ],
    );
    await tester.tap(find.byKey(const Key('room-details-chat-background')));
    await _pumpUntil(
      tester,
      () =>
          find.byKey(const Key('chat-background-field')).evaluate().isNotEmpty,
    );
    await tester.enterText(
      find.byKey(const Key('chat-background-field')),
      'magenta',
    );
    await tester.tap(find.byKey(const Key('chat-background-save')));
    await _pumpUntil(tester, () => find.byType(SnackBar).evaluate().isNotEmpty);

    expect(await tester.runAsync(() => store.read(key)), '#123456');
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('chat background storage failure stays inside the screen', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync(
      'nctalk-room-background-failure-',
    );
    final blocked = File('${root.path}${Platform.pathSeparator}blocked')
      ..writeAsStringSync('not a directory');
    final store = ChatBackgroundStore.forTesting(Directory(blocked.path));
    _registerBackgroundStoreTeardown(tester, store, root, closeStore: false);
    final key = (accountId: account.id, roomToken: conversation.token);

    await openDetails(
      tester,
      forAccount: account,
      forConversation: conversation,
      client: participantsClient(const <Object?>[]),
      overrides: [
        chatBackgroundStoreProvider.overrideWith((ref) async => store),
        chatBackgroundProvider(key).overrideWith((ref) => store.watch(key)),
      ],
    );
    await tester.tap(find.byKey(const Key('room-details-chat-background')));
    await _pumpUntil(
      tester,
      () =>
          find.byKey(const Key('chat-background-field')).evaluate().isNotEmpty,
    );
    await tester.enterText(
      find.byKey(const Key('chat-background-field')),
      '#112233',
    );
    await tester.tap(find.byKey(const Key('chat-background-save')));
    await _pumpUntil(tester, () => find.byType(SnackBar).evaluate().isNotEmpty);

    expect(find.byType(SnackBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

ChatBackgroundStore _temporaryBackgroundStore(WidgetTester tester) {
  final directory = Directory.systemTemp.createTempSync(
    'nctalk-room-background-',
  );
  final store = ChatBackgroundStore.forTesting(directory);
  _registerBackgroundStoreTeardown(tester, store, directory);
  return store;
}

void _registerBackgroundStoreTeardown(
  WidgetTester tester,
  ChatBackgroundStore store,
  Directory directory, {
  bool closeStore = true,
}) {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(() async {
      if (closeStore) {
        await store.close();
      }
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
  });
}
