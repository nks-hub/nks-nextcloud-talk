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
