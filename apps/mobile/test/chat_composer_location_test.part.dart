part of 'chat_composer_integration_test.dart';

void _registerLocationComposerTests() {
  testWidgets('paperclip shares a confirmed current location', (tester) async {
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    addTearDown(harness.close);
    final sender = _FakeLocationSender();
    await tester.pumpWidget(
      harness.app(
        wrapInScaffold: true,
        overrides: <Override>[
          currentLocationSourceProvider.overrideWithValue(
            const _FakeLocationSource(),
          ),
          locationShareServiceProvider.overrideWithValue(sender),
        ],
      ),
    );
    await _openLocationConfirmation(tester);
    expect(find.text('50.087500, 14.420760'), findsOneWidget);
    await tester.tap(find.byKey(const Key('location-share-submit')));
    await _pumpUntil(tester, () => sender.positions.isNotEmpty);

    expect(sender.positions.single.latitude, 50.0875);
    expect(sender.threadIds, <int?>[null]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('room change invalidates an open location confirmation', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    addTearDown(harness.close);
    final sender = _FakeLocationSender();
    final overrides = <Override>[
      currentLocationSourceProvider.overrideWithValue(
        const _FakeLocationSource(),
      ),
      locationShareServiceProvider.overrideWithValue(sender),
    ];
    await tester.pumpWidget(
      harness.app(wrapInScaffold: true, overrides: overrides),
    );
    await _openLocationConfirmation(tester);

    final otherConversation = harness.conversation.copyWith(token: 'roomb456');
    await tester.pumpWidget(
      harness.app(
        conversation: otherConversation,
        wrapInScaffold: true,
        overrides: overrides,
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('location-share-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(sender.positions, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('permanent location denial opens app settings once', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    addTearDown(harness.close);
    final opener = _FakeAppSettingsOpener(() async => true);
    await _showLocationError(
      tester,
      harness,
      overrides: _locationErrorOverrides(
        error: CurrentLocationError.permissionDeniedForever,
        opener: opener,
      ),
    );

    expect(find.byType(SnackBarAction), findsOneWidget);
    expect(find.text('Open settings'), findsOneWidget);
    await tester.tap(find.text('Open settings'));
    await _pumpUntil(tester, () => opener.calls == 1);

    expect(opener.calls, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('ordinary location denial has no settings action', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    addTearDown(harness.close);
    final opener = _FakeAppSettingsOpener(() async => true);
    await _showLocationError(
      tester,
      harness,
      overrides: _locationErrorOverrides(
        error: CurrentLocationError.permissionDenied,
        opener: opener,
      ),
    );

    expect(find.byType(SnackBarAction), findsNothing);
    expect(find.text('Open settings'), findsNothing);
    expect(opener.calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('failed app settings launch is reported', (tester) async {
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    addTearDown(harness.close);
    final opener = _FakeAppSettingsOpener(() async => false);
    await _showLocationError(
      tester,
      harness,
      overrides: _locationErrorOverrides(
        error: CurrentLocationError.permissionDeniedForever,
        opener: opener,
      ),
    );

    await tester.tap(find.text('Open settings'));
    await _pumpUntil(
      tester,
      () => find
          .text('The system settings could not be opened.')
          .evaluate()
          .isNotEmpty,
    );

    expect(opener.calls, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('app settings launch exception is reported', (tester) async {
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    addTearDown(harness.close);
    final opener = _FakeAppSettingsOpener(
      () async => throw StateError('fixture failure'),
    );
    await _showLocationError(
      tester,
      harness,
      overrides: _locationErrorOverrides(
        error: CurrentLocationError.permissionDeniedForever,
        opener: opener,
      ),
    );

    await tester.tap(find.text('Open settings'));
    await _pumpUntil(
      tester,
      () => find
          .text('The system settings could not be opened.')
          .evaluate()
          .isNotEmpty,
    );

    expect(opener.calls, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('room change prevents a stale settings action', (tester) async {
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    addTearDown(harness.close);
    final opener = _FakeAppSettingsOpener(() async => true);
    final overrides = _locationErrorOverrides(
      error: CurrentLocationError.permissionDeniedForever,
      opener: opener,
    );
    await _showLocationError(tester, harness, overrides: overrides);
    final action = tester.widget<SnackBarAction>(find.byType(SnackBarAction));

    await tester.pumpWidget(
      harness.app(
        conversation: harness.conversation.copyWith(token: 'roomb456'),
        wrapInScaffold: true,
        overrides: overrides,
      ),
    );
    await tester.pump();
    action.onPressed();
    await tester.pump();

    expect(opener.calls, 0);
    expect(find.text('The system settings could not be opened.'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('room change suppresses a stale settings failure', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    addTearDown(harness.close);
    final completion = Completer<bool>();
    final opener = _FakeAppSettingsOpener(() => completion.future);
    final overrides = _locationErrorOverrides(
      error: CurrentLocationError.permissionDeniedForever,
      opener: opener,
    );
    await _showLocationError(tester, harness, overrides: overrides);
    await tester.tap(find.text('Open settings'));
    await _pumpUntil(tester, () => opener.calls == 1);

    await tester.pumpWidget(
      harness.app(
        conversation: harness.conversation.copyWith(token: 'roomb456'),
        wrapInScaffold: true,
        overrides: overrides,
      ),
    );
    await tester.pump();
    completion.complete(false);
    await tester.runAsync(() async {
      await completion.future;
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();

    expect(opener.calls, 1);
    expect(find.text('The system settings could not be opened.'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('ambiguous location write warns against blind retry', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    addTearDown(harness.close);
    final sender = _FakeLocationSender(
      error: const LocationShareException(LocationShareError.ambiguous),
    );
    await tester.pumpWidget(
      harness.app(
        wrapInScaffold: true,
        overrides: <Override>[
          currentLocationSourceProvider.overrideWithValue(
            const _FakeLocationSource(),
          ),
          locationShareServiceProvider.overrideWithValue(sender),
        ],
      ),
    );
    await _openLocationConfirmation(tester);
    await tester.tap(find.byKey(const Key('location-share-submit')));
    await _pumpUntil(
      tester,
      () => find
          .text(
            'The server may have received the location. '
            'Check the chat before trying again.',
          )
          .evaluate()
          .isNotEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('unexpected location error stays inside the UI boundary', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    addTearDown(harness.close);
    await tester.pumpWidget(
      harness.app(
        wrapInScaffold: true,
        overrides: <Override>[
          currentLocationSourceProvider.overrideWithValue(
            const _FailingLocationSource(),
          ),
        ],
      ),
    );
    await _openLocationAction(tester);
    await _pumpUntil(
      tester,
      () =>
          find.text('The location could not be shared.').evaluate().isNotEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

Future<void> _openLocationConfirmation(WidgetTester tester) async {
  await _openLocationAction(tester);
  await _pumpUntil(
    tester,
    () => find
        .byKey(const Key('location-share-confirmation'))
        .evaluate()
        .isNotEmpty,
  );
}

Future<void> _showLocationError(
  WidgetTester tester,
  _ComposerHarness harness, {
  required List<Override> overrides,
}) async {
  await tester.pumpWidget(
    harness.app(wrapInScaffold: true, overrides: overrides),
  );
  await _openLocationAction(tester);
  await _pumpUntil(tester, () => find.byType(SnackBar).evaluate().isNotEmpty);
  await _pumpTransition(tester);
}

List<Override> _locationErrorOverrides({
  required CurrentLocationError error,
  required _FakeAppSettingsOpener opener,
}) => <Override>[
  currentLocationSourceProvider.overrideWithValue(_LocationErrorSource(error)),
  appSettingsOpenerProvider.overrideWithValue(opener),
];

Future<void> _openLocationAction(WidgetTester tester) async {
  await _pumpUntil(
    tester,
    () => find.byKey(const Key('pick-image-attachment')).evaluate().isNotEmpty,
  );
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
  await tester.tap(find.byKey(const Key('pick-image-attachment')));
  await _pumpTransition(tester);
  await tester.tap(find.byKey(const Key('share-current-location')));
}

final class _FakeLocationSource implements CurrentLocationSource {
  const _FakeLocationSource();

  @override
  Future<SharedPosition> current() async =>
      const SharedPosition(50.0875, 14.42076);
}

final class _FailingLocationSource implements CurrentLocationSource {
  const _FailingLocationSource();

  @override
  Future<SharedPosition> current() async {
    throw StateError('fixture failure');
  }
}

final class _LocationErrorSource implements CurrentLocationSource {
  const _LocationErrorSource(this.error);

  final CurrentLocationError error;

  @override
  Future<SharedPosition> current() async {
    throw CurrentLocationException(error);
  }
}

final class _FakeAppSettingsOpener implements AppSettingsOpener {
  _FakeAppSettingsOpener(this._open);

  final Future<bool> Function() _open;
  int calls = 0;

  @override
  Future<bool> open() {
    calls++;
    return _open();
  }
}

final class _FakeLocationSender implements LocationShareSender {
  _FakeLocationSender({this.error});

  final LocationShareException? error;
  final List<SharedPosition> positions = [];
  final List<int?> threadIds = [];

  @override
  Future<ChatMessage> share({
    required String accountId,
    required String roomToken,
    required SharedPosition position,
    required String name,
    required int? threadId,
  }) async {
    if (error != null) {
      throw error!;
    }
    positions.add(position);
    threadIds.add(threadId);
    return ChatMessage.fromJson({
      'id': 900,
      'token': roomToken,
      'actorType': 'users',
      'actorId': 'fixture-user',
      'actorDisplayName': 'Fixture User',
      'timestamp': 1787443000,
      'systemMessage': 'object_shared',
      'messageType': 'system',
      'isReplyable': true,
      'referenceId': 'location-test',
      'message': '{object}',
      'messageParameters': <String, Object?>{},
      'markdown': false,
      'reactions': <String, Object?>{},
    });
  }
}
