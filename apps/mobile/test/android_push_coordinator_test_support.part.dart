part of 'android_push_coordinator_test.dart';

AndroidWebPushEvent _messageEvent({
  required String id,
  required Map<String, Object> content,
  String accountId = 'account-a',
  int generation = 1,
  AndroidWebPushEventType type = AndroidWebPushEventType.message,
}) {
  return AndroidWebPushEvent(
    id: id,
    accountId: accountId,
    generation: generation,
    type: type,
    createdAt: DateTime.utc(2026),
    coalescedCount: 1,
    stale: false,
    content: Uint8List.fromList(utf8.encode(jsonEncode(content))),
    decrypted: true,
  );
}

AndroidWebPushEvent _endpointEvent({
  required String id,
  String accountId = 'account-a',
  int generation = 1,
}) {
  return AndroidWebPushEvent(
    id: id,
    accountId: accountId,
    generation: generation,
    type: AndroidWebPushEventType.endpoint,
    createdAt: DateTime.utc(2026),
    coalescedCount: 1,
    stale: false,
    endpoint: AndroidWebPushEndpoint(
      url: 'https://push.example.invalid/subscription',
      temporary: false,
      publicKey: 'B${'b' * 86}',
      authSecret: 'c' * 22,
    ),
  );
}

AndroidWebPushEvent _platformEvent({
  required String id,
  required AndroidWebPushEventType type,
  String accountId = 'account-a',
  int generation = 1,
}) {
  return AndroidWebPushEvent(
    id: id,
    accountId: accountId,
    generation: generation,
    type: type,
    createdAt: DateTime.utc(2026),
    coalescedCount: 1,
    stale: false,
  );
}

Future<({AccountRepository accounts, MemoryCredentialVault credentials})>
_createAccounts(List<String> accountIds) async {
  final database = openTestDatabase();
  addTearDown(database.close);
  final accounts = AccountRepository(database);
  final credentials = MemoryCredentialVault();
  for (final accountId in accountIds) {
    await accounts.upsertAccount(
      accountId: accountId,
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-$accountId',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    credentials.values[accountId] = 'fixture-password';
  }
  return (accounts: accounts, credentials: credentials);
}

Map<String, Object?> _ocs(Object? data, [int statusCode = 200]) {
  return <String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': statusCode,
        'message': 'OK',
      },
      'data': data,
    },
  };
}

class _FakeAndroidWebPushPlatform implements AndroidWebPushPlatform {
  final eventsController = StreamController<int>.broadcast();
  final openController = StreamController<AndroidNotificationOpen>.broadcast();
  final events = <AndroidWebPushEvent>[];
  final registrations = <({String accountId, int generation})>[];
  final preparedServerRevocations = <String>[];
  final retiredServerRevocations = <({String accountId, int generation})>[];
  final registrationStates = <String, AndroidWebPushRegistrationState>{};
  final pendingServerRevocations = <String, Set<int>>{};
  final committedEventIds = <String>[];
  final acknowledgedEventIds = <String>[];
  final notificationActions = <AndroidNotificationAction>[];
  final actionAttempts = <String, int>{};
  final exhaustedActionIds = <String>[];
  final resolvedActions =
      <({String actionId, AndroidNotificationActionOutcome outcome})>[];
  var maximumActionAttempts = 8;
  final endpointCommitted = Completer<void>();
  AndroidWebPushRegistrationPhase? phase;
  int? generation;
  Object? drainFailure;
  AndroidNotificationOpen? launchNotification;
  Future<AndroidWebPushAvailability>? availabilityFuture;
  var emitEndpointOnRegister = true;
  var permission = AndroidNotificationPermission.notDetermined;
  var permissionRequests = 0;

  @override
  Stream<int> get eventsAvailable => eventsController.stream;

  @override
  Stream<AndroidNotificationOpen> get notificationOpened =>
      openController.stream;

  @override
  Future<AndroidWebPushAvailability> getAvailability() async {
    final configured = availabilityFuture;
    if (configured != null) {
      return configured;
    }
    return const AndroidWebPushAvailability(
      available: true,
      playServicesAvailable: true,
    );
  }

  @override
  Future<AndroidWebPushRegistrationState> getRegistrationState({
    required String accountId,
  }) async {
    final scoped = registrationStates[accountId];
    if (scoped != null) {
      return scoped;
    }
    return AndroidWebPushRegistrationState(
      generation: generation,
      nextGeneration: (generation ?? 0) + 1,
      phase: phase,
      pendingEventCount: events.length,
    );
  }

  @override
  Future<AndroidNotificationPermission> getNotificationPermission() async {
    return permission;
  }

  @override
  Future<AndroidNotificationPermission> requestNotificationPermission() async {
    permissionRequests++;
    return permission = AndroidNotificationPermission.granted;
  }

  @override
  Future<AndroidNotificationOpen?> getLaunchNotification() async {
    final result = launchNotification;
    launchNotification = null;
    return result;
  }

  @override
  Future<AndroidWebPushRegistrationResult> register({
    required String accountId,
    required int generation,
    required String vapidPublicKey,
  }) async {
    final scopedState = registrationStates[accountId];
    final existingActiveRegistration =
        scopedState?.generation == generation &&
            scopedState?.phase == AndroidWebPushRegistrationPhase.active ||
        scopedState == null &&
            this.generation == generation &&
            phase == AndroidWebPushRegistrationPhase.active;
    registrations.add((accountId: accountId, generation: generation));
    this.generation = generation;
    if (!existingActiveRegistration) {
      phase = AndroidWebPushRegistrationPhase.registering;
    }
    final registrationPhase = existingActiveRegistration
        ? AndroidWebPushRegistrationPhase.active
        : AndroidWebPushRegistrationPhase.registering;
    registrationStates[accountId] = AndroidWebPushRegistrationState(
      generation: generation,
      nextGeneration: generation + 1,
      phase: registrationPhase,
      pendingEventCount: events.length,
    );
    if (emitEndpointOnRegister &&
        events
            .where((event) => event.type == AndroidWebPushEventType.endpoint)
            .isEmpty) {
      events.add(
        AndroidWebPushEvent(
          id: 'endpoint-1',
          accountId: accountId,
          generation: generation,
          type: AndroidWebPushEventType.endpoint,
          createdAt: DateTime.utc(2026),
          coalescedCount: 1,
          stale: false,
          endpoint: AndroidWebPushEndpoint(
            url: 'https://push.example.invalid/subscription',
            temporary: false,
            publicKey: 'B${'b' * 86}',
            authSecret: 'c' * 22,
          ),
        ),
      );
    }
    return AndroidWebPushRegistrationResult(
      generation: generation,
      status: AndroidWebPushRegistrationStatus.created,
    );
  }

  @override
  Future<AndroidWebPushCommitResult> commitEndpoint({
    required String accountId,
    required int generation,
    required String eventId,
  }) async {
    committedEventIds.add(eventId);
    phase = AndroidWebPushRegistrationPhase.active;
    registrationStates[accountId] = AndroidWebPushRegistrationState(
      generation: generation,
      nextGeneration: generation + 1,
      phase: AndroidWebPushRegistrationPhase.active,
      pendingEventCount: events.length,
    );
    if (!endpointCommitted.isCompleted) {
      endpointCommitted.complete();
    }
    final serverRevokeGenerations =
        pendingServerRevocations[accountId]?.toList(growable: false) ?? <int>[];
    serverRevokeGenerations.sort();
    return AndroidWebPushCommitResult(
      serverRevokeGenerations: serverRevokeGenerations,
    );
  }

  @override
  Future<List<int>> prepareServerRevocation({required String accountId}) async {
    preparedServerRevocations.add(accountId);
    final state = await getRegistrationState(accountId: accountId);
    final currentGeneration = state.generation;
    if (currentGeneration != null &&
        (state.phase == AndroidWebPushRegistrationPhase.active ||
            state.phase == AndroidWebPushRegistrationPhase.registering ||
            state.phase ==
                AndroidWebPushRegistrationPhase.serverRevokePending)) {
      pendingServerRevocations
          .putIfAbsent(accountId, () => <int>{})
          .add(currentGeneration);
      registrationStates[accountId] = AndroidWebPushRegistrationState(
        generation: currentGeneration,
        nextGeneration: state.nextGeneration,
        phase: AndroidWebPushRegistrationPhase.serverRevokePending,
        pendingEventCount: state.pendingEventCount,
      );
      if (accountId == 'account-a') {
        phase = AndroidWebPushRegistrationPhase.serverRevokePending;
      }
    }
    final generations =
        pendingServerRevocations[accountId]?.toList() ?? <int>[];
    generations.sort();
    return generations;
  }

  @override
  Future<int> retireAfterServerRevocation({
    required String accountId,
    required int generation,
  }) async {
    retiredServerRevocations.add((
      accountId: accountId,
      generation: generation,
    ));
    pendingServerRevocations[accountId]?.remove(generation);
    final state = registrationStates[accountId];
    if (state?.generation == generation) {
      registrationStates.remove(accountId);
    }
    return 1;
  }

  @override
  Future<int> pendingEventCount({required String accountId}) async {
    return events.length;
  }

  @override
  Future<List<AndroidWebPushEvent>> drainEvents({
    required String accountId,
    int limit = 50,
  }) async {
    final failure = drainFailure;
    if (failure != null) {
      throw failure;
    }
    return events
        .where((event) => event.accountId == accountId)
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<int> acknowledge({
    required String accountId,
    required Iterable<String> eventIds,
  }) async {
    final ids = eventIds.toSet();
    acknowledgedEventIds.addAll(ids);
    final before = events.length;
    events.removeWhere(
      (event) => event.accountId == accountId && ids.contains(event.id),
    );
    return before - events.length;
  }

  @override
  Future<List<AndroidNotificationAction>> drainNotificationActions({
    required String accountId,
    int limit = 20,
  }) async {
    final claimed = notificationActions
        .where((action) => action.accountId == accountId)
        .take(limit)
        .toList(growable: false);
    for (final action in claimed) {
      final attempts = (actionAttempts[action.id] ?? 0) + 1;
      actionAttempts[action.id] = attempts;
      if (attempts > maximumActionAttempts) {
        notificationActions.remove(action);
        exhaustedActionIds.add(action.id);
      }
    }
    return claimed
        .where((action) => !exhaustedActionIds.contains(action.id))
        .toList(growable: false);
  }

  @override
  Future<bool> resolveNotificationAction({
    required String accountId,
    required String actionId,
    required AndroidNotificationActionOutcome outcome,
  }) async {
    final index = notificationActions.indexWhere(
      (action) => action.accountId == accountId && action.id == actionId,
    );
    if (index < 0) {
      return false;
    }
    notificationActions.removeAt(index);
    resolvedActions.add((actionId: actionId, outcome: outcome));
    return true;
  }

  @override
  Future<void> dispose() async {
    await eventsController.close();
    await openController.close();
  }
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue);
}

final class _ManualRetryTimer implements Timer {
  _ManualRetryTimer(this.duration, this._callback);

  final Duration duration;
  final void Function() _callback;
  var _active = true;
  var _tick = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  void fire() {
    if (!_active) {
      return;
    }
    _active = false;
    _tick = 1;
    _callback();
  }

  @override
  void cancel() {
    _active = false;
  }
}

final class _ManualPeriodicTimer implements Timer {
  _ManualPeriodicTimer(this.duration, this._callback);

  final Duration duration;
  final void Function() _callback;
  var _active = true;
  var _tick = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  void fire() {
    if (!_active) {
      return;
    }
    _tick++;
    _callback();
  }

  @override
  void cancel() {
    _active = false;
  }
}
