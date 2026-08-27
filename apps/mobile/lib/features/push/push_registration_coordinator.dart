// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:talk_protocol/talk_protocol.dart';

import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';
import 'apple_push_device_key_store.dart';
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
    PushGatewayClient? gatewayClient,
    Duration firstRetry = const Duration(seconds: 5),
    Duration maximumRetry = const Duration(minutes: 30),
    Future<void> Function(Duration)? delay,
  }) : _accounts = accounts,
       _credentials = credentials,
       _api = api,
       _keyStore = keyStore,
       _gateway = gateway,
       _tokenHandlePrefix = tokenHandlePrefix,
       _gatewayClient = gatewayClient ?? PushGatewayClient(),
       _firstRetry = firstRetry,
       _maximumRetry = maximumRetry,
       _delay = delay ?? _sleep {
    if (firstRetry <= Duration.zero || maximumRetry < firstRetry) {
      throw ArgumentError('Invalid push registration retry timing');
    }
    if (tokenHandlePrefix.isEmpty) {
      throw ArgumentError('Missing push token handle prefix');
    }
  }

  static Future<void> _sleep(Duration duration) =>
      Future<void>.delayed(duration);

  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final PushDeviceKeyStore _keyStore;
  final PushGatewayOrigin _gateway;
  final String _tokenHandlePrefix;
  final PushGatewayClient _gatewayClient;
  final Duration _firstRetry;
  final Duration _maximumRetry;
  final Future<void> Function(Duration) _delay;

  PushRuntimeSnapshot _snapshot = PushRuntimeSnapshot.empty();
  final Map<String, PushRegistrationAuthority> _authorities = {};
  final Set<AccountId> _retryInFlight = {};
  final Map<AccountId, Duration> _retryBackoff = {};
  var _effectSeq = 0;
  var _providerGeneration = 0;
  String? _rawToken;
  var _draining = false;
  var _disposed = false;

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
    final resolved = await _credentialsFor(accountId);
    if (resolved == null) {
      return;
    }
    final server = ServerBase.parse(resolved.account.serverUrl);
    final capabilities = await _api.getAuthenticatedCapabilities(
      server: server,
      loginName: resolved.account.loginName,
      appPassword: resolved.appPassword,
    );
    if (_disposed) {
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
    final authority = _authorities.remove(accountId);
    if (authority == null) {
      return;
    }
    _apply(requestPushAccountRemoval(_snapshot, authority));
    await _drain();
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

  /// Whether no account is still mid-flight or stuck. The transport switch
  /// reads this after [unfollowAll] to tell a clean revocation from one that
  /// only got as far as a retry.
  bool get isSettled => _snapshot.accounts.values.every(
    (account) =>
        account.phase == PushAccountPhase.registered ||
        account.phase == PushAccountPhase.removed,
  );

  Future<void> dispose() async {
    _disposed = true;
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
    final resolved = await _credentialsFor(effect.context.accountId.value);
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
    final resolved = await _credentialsFor(effect.context.accountId.value);
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
      return await _gatewayClient.register(effect, rawPushToken: rawToken);
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
  }
}
