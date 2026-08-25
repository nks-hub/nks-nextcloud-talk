part of 'android_push_coordinator_test.dart';

void _registerAndroidPushActionTests() {
  test('runs notification actions only inside their own account', () async {
    final fixture = await _createAccounts(<String>['account-a', 'account-b']);
    final api = _capabilityApi();
    addTearDown(api.close);
    final platform = _FakeAndroidWebPushPlatform()
      ..notificationActions.addAll(<AndroidNotificationAction>[
        _replyAction(id: 'action-a', accountId: 'account-a', room: 'rooma'),
        _replyAction(id: 'action-b', accountId: 'account-b', room: 'roomb'),
        _markReadAction(id: 'action-c', accountId: 'account-b', room: 'roomb'),
      ]);
    final handled = <AndroidNotificationAction>[];
    final coordinator = AndroidPushCoordinator(
      accounts: fixture.accounts,
      credentials: fixture.credentials,
      api: api,
      platform: platform,
      onWakeUp: (_) async {},
      onNotificationAction: (action) async {
        handled.add(action);
        return AndroidPushActionOutcome.completed;
      },
    );
    addTearDown(coordinator.close);

    await coordinator.drainAccount('account-b');

    expect(
      handled.map((action) => action.id),
      <String>['action-b', 'action-c'],
      reason: 'account-a work must not run while draining account-b',
    );
    expect(handled.every((action) => action.accountId == 'account-b'), isTrue);
    expect(handled.first.replyText, 'notification reply');
    expect(handled.last.kind, AndroidNotificationActionKind.markRead);
    expect(
      platform.resolvedActions
          .map((resolved) => resolved.outcome)
          .toSet()
          .single,
      AndroidNotificationActionOutcome.completed,
    );
    expect(platform.notificationActions.map((action) => action.id), <String>[
      'action-a',
    ]);
  });

  test('keeps a retryable notification action queued and retries', () async {
    final fixture = await _createAccounts(<String>['account-a']);
    final api = _capabilityApi();
    addTearDown(api.close);
    final platform = _FakeAndroidWebPushPlatform()
      ..notificationActions.add(
        _replyAction(id: 'action-a', accountId: 'account-a', room: 'rooma'),
      );
    final timers = <_ManualRetryTimer>[];
    var attempts = 0;
    final coordinator = AndroidPushCoordinator(
      accounts: fixture.accounts,
      credentials: fixture.credentials,
      api: api,
      platform: platform,
      onWakeUp: (_) async {},
      onNotificationAction: (_) async {
        attempts++;
        return attempts == 1
            ? AndroidPushActionOutcome.retry
            : AndroidPushActionOutcome.completed;
      },
      randomDouble: () => 0.5,
      createRetryTimer: (duration, callback) {
        final timer = _ManualRetryTimer(duration, callback);
        timers.add(timer);
        return timer;
      },
    );
    addTearDown(coordinator.close);

    await coordinator.drainAccount('account-a');

    expect(attempts, 1);
    expect(platform.resolvedActions, isEmpty);
    expect(platform.notificationActions, hasLength(1));
    expect(timers, hasLength(1));

    timers.single.fire();
    await _waitUntil(() => platform.resolvedActions.isNotEmpty);

    expect(attempts, 2);
    expect(
      platform.resolvedActions.single.outcome,
      AndroidNotificationActionOutcome.completed,
    );
    expect(platform.notificationActions, isEmpty);
  });

  test(
    'reports a deterministic action failure instead of dropping it',
    () async {
      final fixture = await _createAccounts(<String>['account-a']);
      final api = _capabilityApi();
      addTearDown(api.close);
      final platform = _FakeAndroidWebPushPlatform()
        ..notificationActions.add(
          _replyAction(id: 'action-a', accountId: 'account-a', room: 'rooma'),
        );
      final coordinator = AndroidPushCoordinator(
        accounts: fixture.accounts,
        credentials: fixture.credentials,
        api: api,
        platform: platform,
        onWakeUp: (_) async {},
        onNotificationAction: (_) async => AndroidPushActionOutcome.failed,
      );
      addTearDown(coordinator.close);

      await coordinator.drainAccount('account-a');

      expect(
        platform.resolvedActions.single.outcome,
        AndroidNotificationActionOutcome.failed,
      );
      expect(platform.notificationActions, isEmpty);
    },
  );

  test('answers queued actions of an account without a credential', () async {
    final fixture = await _createAccounts(<String>['account-a']);
    fixture.credentials.values.remove('account-a');
    final api = _capabilityApi();
    addTearDown(api.close);
    final platform = _FakeAndroidWebPushPlatform()
      ..notificationActions.add(
        _replyAction(id: 'action-a', accountId: 'account-a', room: 'rooma'),
      );
    final coordinator = AndroidPushCoordinator(
      accounts: fixture.accounts,
      credentials: fixture.credentials,
      api: api,
      platform: platform,
      onWakeUp: (_) async {},
      onNotificationAction: (_) async => AndroidPushActionOutcome.failed,
    );
    addTearDown(coordinator.close);

    await coordinator.drainAccount('account-a');

    expect(
      platform.resolvedActions.single.outcome,
      AndroidNotificationActionOutcome.failed,
    );
  });

  test('rejects a stored action that names a foreign account', () async {
    final fixture = await _createAccounts(<String>['account-a']);
    final api = _capabilityApi();
    addTearDown(api.close);
    final platform = _ForeignActionPlatform()
      ..notificationActions.add(
        _replyAction(id: 'action-x', accountId: 'account-b', room: 'roomb'),
      );
    final handled = <AndroidNotificationAction>[];
    final coordinator = AndroidPushCoordinator(
      accounts: fixture.accounts,
      credentials: fixture.credentials,
      api: api,
      platform: platform,
      onWakeUp: (_) async {},
      onNotificationAction: (action) async {
        handled.add(action);
        return AndroidPushActionOutcome.completed;
      },
    );
    addTearDown(coordinator.close);

    await coordinator.drainAccount('account-a');

    expect(handled, isEmpty);
    expect(
      platform.resolvedActions.single.outcome,
      AndroidNotificationActionOutcome.failed,
    );
  });

  test('redacted action toString keeps the reply and room private', () {
    final action = _replyAction(
      id: 'action-a',
      accountId: 'account-a',
      room: 'rooma',
    );
    final text = action.toString();
    expect(text, contains('replyText: <redacted>'));
    expect(text, contains('roomToken: <redacted>'));
    expect(text, isNot(contains('notification reply')));
    expect(text, isNot(contains('rooma')));
    expect(text, isNot(contains('account-a')));
  });

  test('rejects a native action payload without reply text', () {
    expect(
      () => AndroidNotificationAction.fromMap(const <Object?, Object?>{
        'id': 'nksact1_x',
        'accountId': 'account-a',
        'kind': 'REPLY',
        'notificationId': 7,
        'roomToken': 'rooma',
        'replyText': '   ',
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => AndroidNotificationAction.fromMap(const <Object?, Object?>{
        'id': 'nksact1_x',
        'accountId': 'account-a',
        'kind': 'SEND_MONEY',
        'notificationId': 7,
        'roomToken': 'rooma',
        'replyText': null,
      }),
      throwsA(isA<FormatException>()),
    );
  });
}

HttpNextcloudApi _capabilityApi() {
  return HttpNextcloudApi(
    client: MockClient((request) async {
      if (request.url.path.endsWith('/webpush/vapid')) {
        return http.Response(
          jsonEncode(_ocs(<String, Object>{'vapid': 'B${'a' * 86}'})),
          200,
        );
      }
      if (request.url.path.endsWith('/webpush/activate')) {
        return http.Response(jsonEncode(_ocs(const <Object>[], 202)), 202);
      }
      if (request.url.path.endsWith('/webpush')) {
        return http.Response(jsonEncode(_ocs(const <Object>[], 201)), 201);
      }
      return http.Response(
        jsonEncode(
          capabilitiesJson(
            notificationPushFeatures: const <String>[
              'devices',
              'object-data',
              'delete',
              'webpush',
            ],
          ),
        ),
        200,
      );
    }),
  );
}

AndroidNotificationAction _replyAction({
  required String id,
  required String accountId,
  required String room,
}) {
  return AndroidNotificationAction(
    id: id,
    accountId: accountId,
    kind: AndroidNotificationActionKind.reply,
    notificationId: 7,
    roomToken: room,
    replyText: 'notification reply',
  );
}

AndroidNotificationAction _markReadAction({
  required String id,
  required String accountId,
  required String room,
}) {
  return AndroidNotificationAction(
    id: id,
    accountId: accountId,
    kind: AndroidNotificationActionKind.markRead,
    notificationId: 8,
    roomToken: room,
    replyText: null,
  );
}

/// Hands out every stored action regardless of the requested account so the
/// coordinator's own scope guard is exercised.
final class _ForeignActionPlatform extends _FakeAndroidWebPushPlatform {
  @override
  Future<List<AndroidNotificationAction>> drainNotificationActions({
    required String accountId,
    int limit = 20,
  }) async => notificationActions.toList(growable: false);

  @override
  Future<bool> resolveNotificationAction({
    required String accountId,
    required String actionId,
    required AndroidNotificationActionOutcome outcome,
  }) async {
    notificationActions.removeWhere((action) => action.id == actionId);
    resolvedActions.add((actionId: actionId, outcome: outcome));
    return true;
  }
}
