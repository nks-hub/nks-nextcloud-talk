// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:talk_protocol/talk_protocol.dart';

import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';
import 'push_device_key_store.dart';
import 'push_gateway_client.dart';

/// Drives `talk_protocol`'s push-v2 state machine for one account at a time:
/// device key, Nextcloud registration, and the `nks-talk-notify` proxy
/// registration that lets the push provider reach the app while it is closed.
/// See that project's README for the wire contract each effect executes.
///
/// Nothing here is platform-specific. The state machine
/// (`packages/talk_protocol/lib/src/push`) is pure: [planNextPushEffect] says
/// what to do next, this coordinator does it (a keystore call or an HTTP
/// request), and [completePushEffect] folds the result back in. The platform
/// supplies exactly two things through the constructor — a
/// [PushDeviceKeyStore] and, via [installToken], the provider token — so the
/// same loop serves an APNs token on iOS and an FCM token on Android.
///
/// Only one effect is ever in flight; the state machine hands out at most one
/// pending effect at a time, so the drive loop needs no concurrency of its own.
final class PushRegistrationCoordinator {
  PushRegistrationCoordinator({
    required AccountRepository accounts,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
    required PushDeviceKeyStore keyStore,
    required PushGatewayOrigin gateway,
    required String tokenHandlePrefix,
    required PushGatewayProvider pushProvider,
    String? pushEnvironment,
    PushGatewayClient? gatewayClient,
    Duration firstRetry = const Duration(seconds: 5),
    Duration maximumRetry = const Duration(minutes: 30),
    Future<void> Function(Duration)? delay,
    Future<void> Function(String handle, String accountId)?
    recordDeviceKeyAccount,
  }) : _accounts = accounts,
       _credentials = credentials,
       _api = api,
       _keyStore = keyStore,
       _gateway = gateway,
       _tokenHandlePrefix = tokenHandlePrefix,
       _pushProvider = pushProvider,
       _pushEnvironment = pushEnvironment,
       _gatewayClient = gatewayClient ?? PushGatewayClient(),
       _firstRetry = firstRetry,
       _maximumRetry = maximumRetry,
       _delay = delay ?? _sleep,
       _recordDeviceKeyAccount = recordDeviceKeyAccount ?? _noAccountRecording {
    if (firstRetry <= Duration.zero || maximumRetry < firstRetry) {
      throw ArgumentError('Invalid push registration retry timing');
    }
    if (tokenHandlePrefix.isEmpty) {
      throw ArgumentError('Missing push token handle prefix');
    }
    // APNs needs the sandbox told apart from production; FCM has no such
    // split and the gateway rejects the field for it.
    if (pushProvider == PushGatewayProvider.apns &&
        pushEnvironment != 'development' &&
        pushEnvironment != 'production') {
      throw ArgumentError('Invalid APNs environment');
    }
    if (pushProvider != PushGatewayProvider.apns && pushEnvironment != null) {
      throw ArgumentError('Push environment applies to APNs only');
    }
  }

  static Future<void> _sleep(Duration duration) =>
      Future<void>.delayed(duration);

  static Future<void> _noAccountRecording(
    String handle,
    String accountId,
  ) async {}

  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final PushDeviceKeyStore _keyStore;
  final PushGatewayOrigin _gateway;
  final String _tokenHandlePrefix;
  final PushGatewayProvider _pushProvider;
  final String? _pushEnvironment;
  final PushGatewayClient _gatewayClient;
  final Duration _firstRetry;
  final Duration _maximumRetry;
  final Future<void> Function(Duration) _delay;
  final Future<void> Function(String handle, String accountId)
  _recordDeviceKeyAccount;

  PushRuntimeSnapshot _snapshot = PushRuntimeSnapshot.empty();
  final Map<String, PushRegistrationAuthority> _authorities = {};
  final Map<String, int> _accountLifecycleGeneration = {};
  final Set<AccountId> _retryInFlight = {};
  final Map<AccountId, Duration> _retryBackoff = {};
  final Map<String, ({int retryGeneration, int lifecycleGeneration})>
  _credentialRetries = {};
  final Map<String, Duration> _credentialRetryBackoff = {};
  var _effectSeq = 0;
  var _accountLifecycleSeq = 0;
  var _credentialRetrySeq = 0;
  var _providerGeneration = 0;
  String? _rawToken;
  var _draining = false;
  var _disposed = false;
  Future<void>? _activeDrain;

  /// Feeds a freshly issued (or refreshed) provider token in. Every account
  /// still needing to register picks this up on the next drain.
  ///
  /// Until this has been called at least once nothing is planned at all:
  /// without a provider token [planNextPushEffect] returns empty-handed, so
  /// not even the device key gets created.
  void installToken(String token) {
    if (_disposed) {
      return;
    }
    _providerGeneration++;
    final generation = _providerGeneration;
    final handle = PushTokenHandle.parse('$_tokenHandlePrefix-$generation');
    // The proxy's `pushTokenHash` contract hashes the UTF-8 token string, not
    // any decoded form of it, and Nextcloud validates the result against
    // /^([a-f0-9]{128})$/ — lowercase hex, which `toString()` produces.
    final sha512Hex = crypto.sha512.convert(utf8.encode(token)).toString();
    _rawToken = token;
    _apply(
      installPushProviderToken(
        _snapshot,
        PushProviderTokenBinding(
          handle: handle,
          sha512: sha512Hex,
          generation: generation,
        ),
      ),
    );
    unawaited(_drain());
  }

  /// Starts, or refreshes, registration for [accountId]. Safe to call again
  /// after capabilities change — a re-add with the same authority is a
  /// no-op, a changed one re-registers.
  Future<void> follow(String accountId) async {
    if (_disposed) {
      return;
    }
    final lifecycleGeneration = ++_accountLifecycleSeq;
    _accountLifecycleGeneration[accountId] = lifecycleGeneration;
    final ({StoredAccount account, String appPassword})? resolved;
    try {
      resolved = await _credentialsFor(accountId);
    } on CredentialVaultTemporarilyUnavailable {
      if (_isCurrentFollow(accountId, lifecycleGeneration)) {
        _scheduleCredentialRetry(accountId, lifecycleGeneration);
      }
      return;
    }
    if (!_isCurrentFollow(accountId, lifecycleGeneration)) {
      return;
    }
    if (resolved == null) {
      _clearCredentialRetry(accountId);
      return;
    }
    _clearCredentialRetry(accountId);
    // The account stream re-emits on every write to the row, so this runs far
    // more often than the push identity changes. It stays cheap without a
    // guard here: `getAuthenticatedCapabilities` serves an in-memory snapshot
    // for five minutes, and nothing in this coordinator triggers a sync, so
    // there is no loop to close.
    final server = ServerBase.parse(resolved.account.serverUrl);
    final CapabilitySnapshot capabilities;
    try {
      capabilities = await _api.getAuthenticatedCapabilities(
        server: server,
        loginName: resolved.account.loginName,
        appPassword: resolved.appPassword,
      );
    } on NextcloudApiException catch (error) {
      // Every caller fires `follow` and forgets it, so an exception here
      // escaped to the zone and was reported as a fatal crash (timeout,
      // network and 401 on builds 45 to 48). A server that cannot answer now
      // is retried with backoff; a rejected login is left to the account's
      // own re-login flow, which calls `follow` again once it succeeds.
      if (error.statusCode != 401 &&
          _isCurrentFollow(accountId, lifecycleGeneration)) {
        _scheduleCredentialRetry(accountId, lifecycleGeneration);
      }
      return;
    }
    if (!_isCurrentFollow(accountId, lifecycleGeneration)) {
      return;
    }
    final authority = PushRegistrationAuthority(
      accountId: AccountId.parse(accountId),
      server: server,
      gateway: _gateway,
      // ponytail: no credential/capability rotation tracking exists yet in
      // this app, so both stay pinned at 1. Add real generations if an
      // app-password refresh or a capability change needs to force a
      // re-registration without a full account remove/re-add.
      credentialGeneration: 1,
      capabilityGeneration: 1,
      cloudId: '${resolved.account.loginName}@${server.uri.host}',
      supportsPushV2: capabilities.supportsNotificationPush('devices'),
    );
    final existing = _authorities[accountId];
    if (existing != null && existing.bindingEquals(authority)) {
      return;
    }
    _authorities[accountId] = authority;
    _apply(
      existing == null
          ? addPushAccount(_snapshot, authority)
          : refreshPushAccountAuthority(_snapshot, authority),
    );
    await _drain();
  }

  /// Unregisters [accountId] and stops tracking it.
  Future<void> unfollow(String accountId) async {
    await revokeAccount(accountId);
  }

  /// Requests account-scoped proxy cleanup and reports whether the complete
  /// Nextcloud, gateway and key-destruction chain settled synchronously.
  /// Retryable state remains owned by this coordinator for its bounded retry.
  Future<bool> revokeAccount(String accountId) async {
    _accountLifecycleGeneration[accountId] = ++_accountLifecycleSeq;
    _clearCredentialRetry(accountId);
    final authority = _authorities[accountId];
    if (authority == null) {
      return true;
    }
    _apply(requestPushAccountRemoval(_snapshot, authority));
    await _drain();
    return _retireAuthorityIfRemoved(authority.accountId);
  }

  /// Unregisters every account this coordinator still tracks, at Nextcloud
  /// and at the proxy, and destroys their device keys.
  ///
  /// Called when the device leaves this transport: whatever registered here
  /// has to be gone before the other transport claims the same device.
  Future<void> unfollowAll() async {
    for (final accountId in _authorities.keys.toList(growable: false)) {
      await unfollow(accountId);
    }
  }

  /// Revokes every proxy registration or fails while retryable work remains.
  Future<void> revokeAll() async {
    await unfollowAll();
    if (!isSettled) {
      throw StateError('Proxy push revocation is still pending');
    }
  }

  /// Re-registers every account after a failed transport handover.
  Future<void> followAll() async {
    if (_snapshot.accounts.values.any(
      (account) => account.phase != PushAccountPhase.removed,
    )) {
      throw StateError(
        'Proxy push restoration requires a completed revocation',
      );
    }
    final providerToken = _snapshot.providerToken;
    _snapshot = PushRuntimeSnapshot.empty();
    if (providerToken != null) {
      _apply(installPushProviderToken(_snapshot, providerToken));
    }
    for (final account in await _accounts.listAccounts()) {
      await follow(account.id);
    }
    if (!isSettled) {
      throw StateError('Proxy push restoration is still pending');
    }
  }

  /// Whether no account is still mid-flight or stuck. The transport switch
  /// reads this after [unfollowAll] to tell a clean revocation from one that
  /// only got as far as a retry.
  bool get isSettled => _snapshot.accounts.values.every(
    (account) =>
        account.phase == PushAccountPhase.registered ||
        account.phase == PushAccountPhase.removed,
  );

  /// Waits for a currently in-flight [_drain] to actually stop before closing
  /// the gateway client — closing it out from under a mid-flight
  /// register/unregister call would abort that HTTP request, potentially
  /// leaving a device registered with Nextcloud but not the proxy (or the
  /// reverse), the exact split state a clean unregister exists to avoid.
  Future<void> dispose() async {
    _disposed = true;
    _credentialRetries.clear();
    _credentialRetryBackoff.clear();
    await _activeDrain;
    _gatewayClient.close();
  }

  Future<({StoredAccount account, String appPassword})?> _credentialsFor(
    String accountId,
  ) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      return null;
    }
    final appPassword = await _credentials.readAppPassword(accountId);
    if (appPassword == null) {
      return null;
    }
    return (account: account, appPassword: appPassword);
  }

  void _apply(PushRuntimeResult result) {
    if (result.canCommit) {
      _snapshot = commitPushRuntime(_snapshot, result);
    }
  }

  Future<void> _drain() async {
    if (_draining || _disposed) {
      return;
    }
    _draining = true;
    final completer = Completer<void>();
    _activeDrain = completer.future;
    try {
      while (!_disposed) {
        final planned = planNextPushEffect(
          _snapshot,
          effectId: PushEffectId.parse('push-effect-${_effectSeq++}'),
        );
        if (!planned.canCommit) {
          break;
        }
        _snapshot = commitPushRuntime(_snapshot, planned);
        final completion = await _execute(planned.effect!);
        if (_disposed) {
          return;
        }
        final completed = completePushEffect(_snapshot, completion);
        if (!completed.canCommit) {
          break;
        }
        _snapshot = commitPushRuntime(_snapshot, completed);
      }
    } finally {
      _draining = false;
      completer.complete();
    }
    _scheduleRetries();
  }

  Future<PushEffectCompletion> _execute(PushEffect effect) => switch (effect) {
    final EnsurePushDeviceKeyEffect e => _executeKey(e),
    final RegisterPushWithNextcloudEffect e => _executeRegisterNextcloud(e),
    final RegisterPushWithGatewayEffect e => _executeRegisterGateway(e),
    final UnregisterPushFromNextcloudEffect e => _executeUnregisterNextcloud(e),
    final UnregisterPushFromGatewayEffect e => _executeUnregisterGateway(e),
    final DestroyPushDeviceKeyEffect e => _executeDestroyKey(e),
  };

  Future<PushDeviceKeyCompletion> _executeKey(
    EnsurePushDeviceKeyEffect effect,
  ) async {
    try {
      final handle = _keyHandleFor(effect.context.accountId);
      final pem = await _keyStore.ensureKey(handle.value);
      // Lets the Notification Service Extension learn the account directly
      // once a decrypt succeeds — see PushNotificationRouteStore.swift.
      // `ensureKey` above is idempotent, so retrying this whole effect on
      // failure (the same path every other exception here takes) is safe.
      await _recordDeviceKeyAccount(
        handle.value,
        effect.context.accountId.value,
      );
      final key = PushDeviceKeyBinding(
        handle: handle,
        publicKey: PushRsaPublicKey.parse(pem),
        generation: effect.context.keyGeneration + 1,
      );
      return PushDeviceKeyCompletion.success(effect: effect, key: key);
    } on Object {
      return PushDeviceKeyCompletion.failure(
        effect: effect,
        classification: PushCompletionClass.transientFailure,
      );
    }
  }

  Future<PushDeviceKeyDestructionCompletion> _executeDestroyKey(
    DestroyPushDeviceKeyEffect effect,
  ) async {
    try {
      await _keyStore.destroyKey(effect.key.handle.value);
      return PushDeviceKeyDestructionCompletion.success(effect: effect);
    } on Object {
      return PushDeviceKeyDestructionCompletion.transientFailure(
        effect: effect,
      );
    }
  }

  Future<PushNextcloudRegistrationCompletion> _executeRegisterNextcloud(
    RegisterPushWithNextcloudEffect effect,
  ) async {
    final ({StoredAccount account, String appPassword})? resolved;
    try {
      resolved = await _credentialsFor(effect.context.accountId.value);
    } on CredentialVaultTemporarilyUnavailable {
      return PushNextcloudRegistrationCompletion.transientFailure(
        effect: effect,
      );
    }
    if (resolved == null) {
      return PushNextcloudRegistrationCompletion.reauthenticationRequired(
        effect: effect,
      );
    }
    try {
      return await _api.registerPushWithNextcloud(
        effect: effect,
        loginName: resolved.account.loginName,
        appPassword: resolved.appPassword,
      );
    } on Object {
      return PushNextcloudRegistrationCompletion.transientFailure(
        effect: effect,
      );
    }
  }

  Future<PushNextcloudUnregistrationCompletion> _executeUnregisterNextcloud(
    UnregisterPushFromNextcloudEffect effect,
  ) async {
    final ({StoredAccount account, String appPassword})? resolved;
    try {
      resolved = await _credentialsFor(effect.context.accountId.value);
    } on CredentialVaultTemporarilyUnavailable {
      return PushNextcloudUnregistrationCompletion.transientFailure(
        effect: effect,
      );
    }
    if (resolved == null) {
      return PushNextcloudUnregistrationCompletion.reauthenticationRequired(
        effect: effect,
      );
    }
    try {
      return await _api.unregisterPushFromNextcloud(
        effect: effect,
        loginName: resolved.account.loginName,
        appPassword: resolved.appPassword,
      );
    } on Object {
      return PushNextcloudUnregistrationCompletion.transientFailure(
        effect: effect,
      );
    }
  }

  Future<PushGatewayRegistrationCompletion> _executeRegisterGateway(
    RegisterPushWithGatewayEffect effect,
  ) async {
    final rawToken = _rawToken;
    if (rawToken == null) {
      return PushGatewayRegistrationCompletion.transientFailure(effect: effect);
    }
    try {
      return await _gatewayClient.register(
        effect,
        rawPushToken: rawToken,
        pushProvider: _pushProvider,
        pushEnvironment: _pushEnvironment,
      );
    } on Object {
      return PushGatewayRegistrationCompletion.transientFailure(effect: effect);
    }
  }

  Future<PushGatewayUnregistrationCompletion> _executeUnregisterGateway(
    UnregisterPushFromGatewayEffect effect,
  ) async {
    try {
      return await _gatewayClient.unregister(effect);
    } on Object {
      return PushGatewayUnregistrationCompletion.transientFailure(
        effect: effect,
      );
    }
  }

  PushKeyHandle _keyHandleFor(AccountId accountId) => PushKeyHandle.parse(
    crypto.sha256.convert(utf8.encode(accountId.value)).toString(),
  );

  void _scheduleRetries() {
    final retryable = <AccountId>{};
    for (final entry in _snapshot.accounts.entries) {
      if (entry.value.phase != PushAccountPhase.retryable) {
        continue;
      }
      retryable.add(entry.key);
      if (_retryInFlight.contains(entry.key)) {
        continue;
      }
      _retryInFlight.add(entry.key);
      final backoff = _retryBackoff[entry.key] ?? _firstRetry;
      final doubled = backoff * 2;
      _retryBackoff[entry.key] = doubled > _maximumRetry
          ? _maximumRetry
          : doubled;
      unawaited(_retryAfter(entry.key, backoff));
    }
    _retryBackoff.removeWhere((accountId, _) => !retryable.contains(accountId));
  }

  Future<void> _retryAfter(AccountId accountId, Duration backoff) async {
    await _delay(backoff);
    _retryInFlight.remove(accountId);
    if (_disposed) {
      return;
    }
    final authority = _authorities[accountId.value];
    if (authority == null) {
      return;
    }
    _apply(retryPushAccount(_snapshot, authority));
    await _drain();
    _retireAuthorityIfRemoved(accountId);
  }

  void _scheduleCredentialRetry(String accountId, int lifecycleGeneration) {
    if (_disposed) {
      return;
    }
    final pending = _credentialRetries[accountId];
    if (pending?.lifecycleGeneration == lifecycleGeneration) {
      return;
    }
    final retry = (
      retryGeneration: ++_credentialRetrySeq,
      lifecycleGeneration: lifecycleGeneration,
    );
    _credentialRetries[accountId] = retry;
    final backoff = _credentialRetryBackoff[accountId] ?? _firstRetry;
    final doubled = backoff * 2;
    _credentialRetryBackoff[accountId] = doubled > _maximumRetry
        ? _maximumRetry
        : doubled;
    unawaited(_retryCredentialAfter(accountId, retry, backoff));
  }

  Future<void> _retryCredentialAfter(
    String accountId,
    ({int retryGeneration, int lifecycleGeneration}) retry,
    Duration backoff,
  ) async {
    await _delay(backoff);
    if (_credentialRetries[accountId] != retry ||
        !_isCurrentFollow(accountId, retry.lifecycleGeneration)) {
      return;
    }
    _credentialRetries.remove(accountId);
    if (!_disposed) {
      await follow(accountId);
    }
  }

  void _clearCredentialRetry(String accountId) {
    _credentialRetries.remove(accountId);
    _credentialRetryBackoff.remove(accountId);
  }

  bool _isCurrentFollow(String accountId, int generation) {
    return !_disposed && _accountLifecycleGeneration[accountId] == generation;
  }

  bool _retireAuthorityIfRemoved(AccountId accountId) {
    if (_snapshot.accounts[accountId]?.phase != PushAccountPhase.removed) {
      return false;
    }
    _authorities.remove(accountId.value);
    _retryInFlight.remove(accountId);
    _retryBackoff.remove(accountId);
    return true;
  }
}
