part of 'chat_room_composer_focus_test.dart';

void _registerResumeFocusTests() {
  for (final lobby in [false, true]) {
    testWidgets(
      '${lobby ? 'lobby' : 'missing permission'} does not arm deferred composer focus',
      (tester) async {
        final searchFocus = FocusNode();
        addTearDown(searchFocus.dispose);
        final fixture = await pumpRoom(
          tester,
          desktop: true,
          roomOverrides: {
            'participantType': 3,
            'permissions': lobby ? 502 : 374,
            'lobbyState': lobby ? 1 : 0,
          },
          wrapRoom: (pane) => Column(
            children: [
              TextField(focusNode: searchFocus),
              Expanded(child: pane),
            ],
          ),
        );
        expect(find.byKey(const Key('chat-composer')), findsNothing);
        await restoreWindow(tester);
        searchFocus.requestFocus();
        await tester.pump();
        expect(searchFocus.hasFocus, isTrue);
        final allowed =
            Map<String, Object?>.from(
                jsonDecode(fixture.conversation.rawJson) as Map,
              )
              ..['permissions'] = 502
              ..['lobbyState'] = 0;
        await (fixture.database.update(
          fixture.database.cachedConversations,
        )..where((row) => row.accountId.equals(fixture.account.id))).write(
          CachedConversationsCompanion(rawJson: Value(jsonEncode(allowed))),
        );
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 10));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
        }
        expect(find.byKey(const Key('chat-composer')), findsOneWidget);
        expect(searchFocus.hasFocus, isTrue);
        expect(composerHasFocus(tester), isFalse);
        await settle(tester);
      },
    );
  }

  testWidgets(
    'a non-editor selected after resume wins over queued composer focus',
    (tester) async {
      final buttonFocus = FocusNode();
      addTearDown(buttonFocus.dispose);
      await pumpRoom(
        tester,
        desktop: true,
        wrapRoom: (pane) => Column(
          children: [
            TextButton(
              focusNode: buttonFocus,
              onPressed: () {},
              child: const Text('Room action'),
            ),
            Expanded(child: pane),
          ],
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      buttonFocus.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(buttonFocus.hasFocus, isTrue);
      expect(composerHasFocus(tester), isFalse);
      await settle(tester);
    },
  );

  testWidgets('a pending post-frame editor choice wins over composer focus', (
    tester,
  ) async {
    final searchFocus = FocusNode();
    addTearDown(searchFocus.dispose);
    await pumpRoom(
      tester,
      desktop: true,
      wrapRoom: (pane) => Column(
        children: [
          TextField(focusNode: searchFocus),
          Expanded(child: pane),
        ],
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.addPostFrameCallback((_) => searchFocus.requestFocus());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(searchFocus.hasFocus, isTrue);
    expect(composerHasFocus(tester), isFalse);
    await settle(tester);
  });

  for (final threadId in <int?>[null, 42]) {
    testWidgets(
      'desktop window return focuses the ${threadId == null ? 'root' : 'thread'} composer without changing selection',
      (tester) async {
        await pumpRoom(tester, desktop: true, threadId: threadId);
        final field = tester.widget<TextField>(
          find.byKey(const Key('chat-composer')),
        );
        field.controller!.value = const TextEditingValue(
          text: 'A draft',
          selection: TextSelection(baseOffset: 2, extentOffset: 5),
        );
        field.focusNode!.unfocus();
        await tester.pump();
        expect(composerHasFocus(tester), isFalse);
        await restoreWindow(tester);
        expect(composerHasFocus(tester), isTrue);
        expect(
          field.controller!.value,
          const TextEditingValue(
            text: 'A draft',
            selection: TextSelection(baseOffset: 2, extentOffset: 5),
          ),
        );
        await settle(tester);
      },
    );
  }

  testWidgets('window return does not open the mobile composer keyboard', (
    tester,
  ) async {
    await pumpRoom(tester, desktop: false);
    await restoreWindow(tester);
    expect(composerHasFocus(tester), isFalse);
    await settle(tester);
  });

  testWidgets('window return does not focus a read-only room', (tester) async {
    await pumpRoom(tester, desktop: true, readOnly: true);
    await restoreWindow(tester);
    expect(find.byKey(const Key('chat-composer')), findsNothing);
    await settle(tester);
  });

  for (final chooseAfterResume in [false, true]) {
    testWidgets(
      'window return preserves another editor chosen ${chooseAfterResume ? 'after resume' : 'before minimizing'}',
      (tester) async {
        final searchFocus = FocusNode();
        addTearDown(searchFocus.dispose);
        await pumpRoom(
          tester,
          desktop: true,
          wrapRoom: (pane) => Column(
            children: [
              TextField(
                key: const Key('search-editor'),
                focusNode: searchFocus,
              ),
              Expanded(child: pane),
            ],
          ),
        );
        if (chooseAfterResume) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          await tester.pump();
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          searchFocus.requestFocus();
          await tester.pump();
          await tester.pump();
        } else {
          searchFocus.requestFocus();
          await tester.pump();
          await restoreWindow(tester);
        }
        expect(searchFocus.hasFocus, isTrue);
        expect(composerHasFocus(tester), isFalse);
        await settle(tester);
      },
    );
  }

  testWidgets(
    'window return can move focus from a non-editor into the composer',
    (tester) async {
      final buttonFocus = FocusNode();
      addTearDown(buttonFocus.dispose);
      await pumpRoom(
        tester,
        desktop: true,
        wrapRoom: (pane) => Column(
          children: [
            TextButton(
              focusNode: buttonFocus,
              onPressed: () {},
              child: const Text('Room action'),
            ),
            Expanded(child: pane),
          ],
        ),
      );
      buttonFocus.requestFocus();
      await tester.pump();
      await restoreWindow(tester);
      expect(composerHasFocus(tester), isTrue);
      await settle(tester);
    },
  );

  testWidgets('window return ignores a scope tidying up the focus', (
    tester,
  ) async {
    // A window that is away loses the focus entirely, and the manager puts it
    // back on a SCOPE when the window returns - measured on a real Windows
    // minimize: the root scope holds the primary focus when `resumed` arrives
    // and the route's scope holds it one frame later. That is not a person
    // choosing a different focus, and treating it as one left the composer
    // dead until it was clicked. A scope that does NOT contain the composer -
    // a dialog's, a covering route's - still stops the restore; those are the
    // two tests below.
    final roomScope = FocusScopeNode(debugLabel: 'Room scope');
    addTearDown(roomScope.dispose);
    await pumpRoom(
      tester,
      desktop: true,
      wrapRoom: (pane) => FocusScope(node: roomScope, child: pane),
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(composerHasFocus(tester), isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    // The scope takes the primary focus between the resume and the frame that
    // acts on it, exactly as the window's return does it.
    roomScope.requestFocus();
    await tester.pump();
    await tester.pump();

    expect(composerHasFocus(tester), isTrue);
    await settle(tester);
  });

  testWidgets('window return leaves a dialog in control of focus', (
    tester,
  ) async {
    await pumpRoom(tester, desktop: true);
    final context = tester.element(find.byKey(const Key('chat-composer')));
    final dialogFocus = FocusNode();
    addTearDown(dialogFocus.dispose);
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          content: TextField(focusNode: dialogFocus, autofocus: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await restoreWindow(tester);
    expect(dialogFocus.hasFocus, isTrue);
    expect(composerHasFocus(tester), isFalse);
    await settle(tester);
  });

  testWidgets('a hidden pane cannot take focus when the window returns', (
    tester,
  ) async {
    await pumpRoom(
      tester,
      desktop: true,
      wrapRoom: (pane) => TickerMode(enabled: false, child: pane),
    );
    await restoreWindow(tester);
    expect(composerHasFocus(tester), isFalse);
    await settle(tester);
  });

  testWidgets('a second deactivation cancels the pending composer focus', (
    tester,
  ) async {
    await pumpRoom(tester, desktop: true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(composerHasFocus(tester), isFalse);
    await settle(tester);
  });

  testWidgets('a covering route without an editor prevents focus restoration', (
    tester,
  ) async {
    await pumpRoom(tester, desktop: true);
    final context = tester.element(find.byKey(const Key('chat-composer')));
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Another screen')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await restoreWindow(tester);
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>(),
      isNull,
    );
    await settle(tester);
  });

  testWidgets('a room change cancels queued composer focus restoration', (
    tester,
  ) async {
    final fixture = await pumpRoom(tester, desktop: true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    fixture.selected.value = fixture.conversation.copyWith(token: 'roombravo');
    await tester.pump();
    await tester.pump();
    expect(composerHasFocus(tester), isFalse);
    await settle(tester);
  });

  testWidgets('unmounting cancels queued composer focus restoration', (
    tester,
  ) async {
    await pumpRoom(tester, desktop: true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
