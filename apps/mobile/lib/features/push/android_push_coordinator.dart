// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:talk_protocol/talk_protocol.dart';

import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';
import 'android_web_push_bridge.dart';

typedef AndroidPushWakeUp = Future<void> Function(String accountId);

final class AndroidPushCoordinator {
  AndroidPushCoordinator({
    required AccountRepository accounts,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
    required AndroidWebPushPlatform platform,
    required AndroidPushWakeUp onWakeUp,
    this.retryDelay = const Duration(seconds: 30),
  }) : _accounts = accounts,
       _credentials = credentials,
       _api = api,
       _platform = platform,
       _onWakeUp = onWakeUp;

  static const _drainBatchSize = 50;
  static const _maximumDrainBatches = 8;
  static const _maximumPayloadBytes = 16 * 1024;

  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final AndroidWebPushPlatform _platform;
  final AndroidPushWakeUp _onWakeUp;
  final Duration retryDelay;

  final Map<String, StoredAccount> _knownAccounts = {};
  final Map<String, Future<void>> _accountTails = {};
  final Map<String, Timer> _retryTimers = {};
  final ListQueue<AndroidNotificationOpen> _pendingOpens = ListQueue();
  final StreamController<void> _notificationOpenedController =
      StreamController<void>.broadcast();

  StreamSubscription<List<StoredAccount>>? _accountsSubscription;
  StreamSubscription<int>? _eventsSubscription;
  StreamSubscription<AndroidNotificationOpen>? _openSubscription;
  Future<void>? _startFuture;
  Future<void>? _permissionFuture;
  var _permissionChecked = false;
  var _closed = false;

  Stream<void> get notificationOpened => _notificationOpenedController.stream;

  AndroidNotificationOpen? takeNextNotificationOpen() {
    return _pendingOpens.isEmpty ? null : _pendingOpens.removeFirst();
  }

  Future<void> start() => _startFuture ??= _start();

  Future<void> _start() async {
    final availability = await _platform.getAvailability();
    if (_closed || !availability.available) {
      return;
    }
    _eventsSubscription = _platform.eventsAvailable.listen((_) {
      for (final accountId in _knownAccounts.keys.toList(growable: false)) {
        _runDetached(drainAccount(accountId));
      }
    });
    _openSubscription = _platform.notificationOpened.listen((open) {
      _runDetached(_acceptNotificationOpen(open));
    });
    _accountsSubscription = _accounts.watchAccounts().listen((accounts) {
      _knownAccounts
        ..clear()
        ..addEntries(accounts.map((account) => MapEntry(account.id, account)));
      for (final account in accounts) {
        _runDetached(reconcileAccount(account.id));
      }
    });
    final launchNotification = await _platform.getLaunchNotification();
    if (!_closed && launchNotification != null) {
      await _acceptNotificationOpen(launchNotification);
    }
  }

  Future<void> reconcileAll() async {
    final accounts = await _accounts.watchAccounts().first;
    await Future.wait(accounts.map((account) => reconcileAccount(account.id)));
  }

  Future<void> reconcileAccount(String accountId) {
    return _retryAccountOperation(
      accountId,
      () => _serialize(accountId, () => _reconcileAccount(accountId)),
    );
  }

  Future<void> drainAccount(String accountId) {
    return _retryAccountOperation(
      accountId,
      () => _serialize(accountId, () => _drainAccount(accountId)),
    );
  }

  Future<void> _reconcileAccount(String accountId) async {
    final context = await _loadContext(accountId);
    if (context == null) {
      return;
    }
    final capabilities = await _api.getAuthenticatedCapabilities(
      server: context.server,
      loginName: context.account.loginName,
      appPassword: context.appPassword,
    );
    if (!capabilities.supportsNotificationPush('webpush')) {
      return;
    }
    await _ensureNotificationPermission();
    final vapid = await _api.getWebPushVapid(
      server: context.server,
      loginName: context.account.loginName,
      appPassword: context.appPassword,
    );
    final state = await _platform.getRegistrationState(accountId: accountId);
    final generation = switch (state.phase) {
      AndroidWebPushRegistrationPhase.registering ||
      AndroidWebPushRegistrationPhase.active =>
        state.generation ?? state.nextGeneration,
      _ => state.nextGeneration,
    };
    await _platform.register(
      accountId: accountId,
      generation: generation,
      vapidPublicKey: vapid,
    );
    await _drainAccount(accountId, context: context);
  }

  Future<void> _drainAccount(
    String accountId, {
    _PushAccountContext? context,
  }) async {
    final accountContext = context ?? await _loadContext(accountId);
    if (accountContext == null) {
      return;
    }
    var shouldReregister = false;
    for (var batch = 0; batch < _maximumDrainBatches; batch++) {
      final events = await _platform.drainEvents(
        accountId: accountId,
        limit: _drainBatchSize,
      );
      if (events.isEmpty) {
        break;
      }
      for (final event in events) {
        if (event.accountId != accountId || event.stale) {
          await _acknowledge(accountId, event.id);
          continue;
        }
        switch (event.type) {
          case AndroidWebPushEventType.endpoint:
            await _handleEndpoint(accountContext, event);
          case AndroidWebPushEventType.activation ||
              AndroidWebPushEventType.message:
            await _handleMessage(accountContext, event);
          case AndroidWebPushEventType.registrationFailed ||
              AndroidWebPushEventType.unregistered:
            await _acknowledge(accountId, event.id);
            shouldReregister = true;
          case AndroidWebPushEventType.temporaryUnavailable:
            await _acknowledge(accountId, event.id);
            _scheduleRetry(accountId);
        }
      }
      if (events.length < _drainBatchSize) {
        break;
      }
    }
    if (shouldReregister) {
      _scheduleRetry(accountId, immediate: true);
    }
  }

  Future<void> _handleEndpoint(
    _PushAccountContext context,
    AndroidWebPushEvent event,
  ) async {
    final endpoint = event.endpoint;
    if (endpoint == null ||
        endpoint.temporary ||
        endpoint.publicKey == null ||
        endpoint.authSecret == null) {
      _scheduleRetry(context.account.id);
      return;
    }
    await _api.registerWebPush(
      server: context.server,
      loginName: context.account.loginName,
      appPassword: context.appPassword,
      endpoint: endpoint.url,
      uaPublicKey: endpoint.publicKey!,
      authSecret: endpoint.authSecret!,
    );
    final commit = await _platform.commitEndpoint(
      accountId: context.account.id,
      generation: event.generation,
      eventId: event.id,
    );
    for (final generation in commit.serverRevokeGenerations) {
      await _platform.retireAfterServerRevocation(
        accountId: context.account.id,
        generation: generation,
      );
    }
    await _acknowledge(context.account.id, event.id);
  }

  Future<void> _handleMessage(
    _PushAccountContext context,
    AndroidWebPushEvent event,
  ) async {
    final payload = _decodePayload(event);
    if (payload == null) {
      await _acknowledge(context.account.id, event.id);
      return;
    }
    if (payload.activationToken != null) {
      final state = await _platform.getRegistrationState(
        accountId: context.account.id,
      );
      if (state.generation != event.generation ||
          state.phase != AndroidWebPushRegistrationPhase.active) {
        _scheduleRetry(context.account.id);
        return;
      }
      await _api.activateWebPush(
        server: context.server,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
        activationToken: payload.activationToken!,
      );
      await _acknowledge(context.account.id, event.id);
      return;
    }
    try {
      await _onWakeUp(context.account.id);
      await _acknowledge(context.account.id, event.id);
    } on Object {
      _scheduleRetry(context.account.id);
    }
  }

  _DecodedPushPayload? _decodePayload(AndroidWebPushEvent event) {
    final content = event.content;
    if (event.decrypted != true ||
        event.payloadOversized ||
        content == null ||
        content.isEmpty ||
        content.length > _maximumPayloadBytes) {
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(content));
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    final activationToken = decoded['activationToken'];
    if (activationToken != null) {
      return activationToken is String &&
              _uuidV4Pattern.hasMatch(activationToken)
          ? _DecodedPushPayload(activationToken: activationToken)
          : null;
    }
    if (decoded['delete-all'] == true) {
      return const _DecodedPushPayload();
    }
    if (decoded['delete-multiple'] == true) {
      final nids = decoded['nids'];
      return nids is List<Object?> &&
              nids.isNotEmpty &&
              nids.length <= 10 &&
              nids.every(_validNotificationId)
          ? const _DecodedPushPayload()
          : null;
    }
    if (decoded['delete'] == true) {
      return _validNotificationId(decoded['nid'])
          ? const _DecodedPushPayload()
          : null;
    }
    final app = decoded['app'];
    final subject = decoded['subject'];
    final nid = decoded['nid'];
    if (app is! String ||
        app.isEmpty ||
        app.length > 64 ||
        subject is! String ||
        subject.isEmpty ||
        subject.length > 4096 ||
        nid != null && !_validNotificationId(nid)) {
      return null;
    }
    final type = decoded['type'];
    final objectId = decoded['id'];
    if (type != null && (type is! String || type.length > 128) ||
        objectId != null && (objectId is! String || objectId.length > 512)) {
      return null;
    }
    return const _DecodedPushPayload();
  }

  Future<_PushAccountContext?> _loadContext(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      return null;
    }
    final appPassword = await _credentials.readAppPassword(accountId);
    if (appPassword == null) {
      return null;
    }
    return _PushAccountContext(
      account: account,
      server: ServerBase.parse(account.serverUrl),
      appPassword: appPassword,
    );
  }

  Future<void> _ensureNotificationPermission() {
    if (_permissionChecked) {
      return Future<void>.value();
    }
    final existing = _permissionFuture;
    if (existing != null) {
      return existing;
    }
    late final Future<void> current;
    current =
        () async {
          final current = await _platform.getNotificationPermission();
          if (current == AndroidNotificationPermission.notDetermined) {
            await _platform.requestNotificationPermission();
          }
          _permissionChecked = true;
        }().whenComplete(() {
          if (identical(_permissionFuture, current)) {
            _permissionFuture = null;
          }
        });
    _permissionFuture = current;
    return current;
  }

  Future<void> _acceptNotificationOpen(AndroidNotificationOpen open) async {
    if (_closed || await _accounts.getAccount(open.accountId) == null) {
      return;
    }
    _pendingOpens.add(open);
    _notificationOpenedController.add(null);
    try {
      await _onWakeUp(open.accountId);
    } on Object {
      _scheduleRetry(open.accountId);
    }
  }

  Future<void> _acknowledge(String accountId, String eventId) async {
    await _platform.acknowledge(
      accountId: accountId,
      eventIds: <String>[eventId],
    );
  }

  Future<void> _serialize(String accountId, Future<void> Function() operation) {
    final previous = _accountTails[accountId] ?? Future<void>.value();
    late final Future<void> current;
    current = previous
        .catchError((Object _) {})
        .then((_) => _closed ? null : operation())
        .whenComplete(() {
          if (identical(_accountTails[accountId], current)) {
            _accountTails.remove(accountId);
          }
        });
    _accountTails[accountId] = current;
    return current;
  }

  Future<void> _retryAccountOperation(
    String accountId,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } on Object {
      _scheduleRetry(accountId);
      rethrow;
    }
  }

  void _scheduleRetry(String accountId, {bool immediate = false}) {
    if (_closed || _retryTimers.containsKey(accountId)) {
      return;
    }
    _retryTimers[accountId] = Timer(immediate ? Duration.zero : retryDelay, () {
      _retryTimers.remove(accountId);
      _runDetached(reconcileAccount(accountId));
    });
  }

  void _runDetached(Future<void> task) {
    unawaited(task.catchError((Object _) {}));
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    await _accountsSubscription?.cancel();
    await _eventsSubscription?.cancel();
    await _openSubscription?.cancel();
    await Future.wait(
      _accountTails.values.map((tail) => tail.catchError((Object _) {})),
    );
    await _notificationOpenedController.close();
  }
}

final RegExp _uuidV4Pattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB]'
  r'[0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

bool _validNotificationId(Object? value) => value is int && value > 0;

final class _DecodedPushPayload {
  const _DecodedPushPayload({this.activationToken});

  final String? activationToken;
}

final class _PushAccountContext {
  const _PushAccountContext({
    required this.account,
    required this.server,
    required this.appPassword,
  });

  final StoredAccount account;
  final ServerBase server;
  final String appPassword;
}
