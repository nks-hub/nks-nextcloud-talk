import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

abstract interface class CredentialVault {
  Future<void> writeAppPassword(String accountId, String appPassword);

  Future<String?> readAppPassword(String accountId);

  Future<void> deleteAppPassword(String accountId);
}

/// App passwords of removed accounts whose server-side revocation is still
/// owed (the device was offline when the account left). One opaque JSON
/// document, kept next to the live secrets because it is one; `null` when
/// nothing is pending.
abstract interface class PendingRevocationStore {
  Future<String?> readPendingRevocations();

  Future<void> writePendingRevocations(String? json);

  /// Changes the queue atomically against other writers on this platform.
  /// The callback may run again when an Android compare-and-set loses a race.
  Future<void> updatePendingRevocations(
    String? Function(String? current) update,
  );
}

/// Active owners of records in the shared revocation store.
abstract interface class PendingRevocationClaims {
  Future<bool> tryClaimRevocation(String id, String token);
  Future<void> releaseRevocationClaim(String id, String token);
}

extension PendingRevocationDrain on PendingRevocationStore {
  static final _localDrainTails = Expando<Future<void>>();
  static final _sharedVault = Object();

  Future<void> withPendingRevocationDrain(Future<void> Function() drain) {
    final store = this;
    if (store is SecureCredentialVault && Platform.isAndroid) {
      return store._withAndroidPendingRevocationDrain(drain);
    }
    final key = store is SecureCredentialVault ? _sharedVault : store;
    final previous = _localDrainTails[key] ?? Future<void>.value();
    final next = previous.then((_) => drain());
    _localDrainTails[key] = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }
}

extension CurrentCredential on CredentialVault {
  /// Reads the vault when local credential ownership determines recovery.
  Future<String?> readCurrentAppPassword(String accountId) {
    final vault = this;
    return vault is SecureCredentialVault
        ? vault._readAppPassword(accountId, refresh: true)
        : vault.readAppPassword(accountId);
  }
}

/// The Apple credential store is intact but cannot be accessed in the current
/// device state, for example during a dark wake or while authorization UI is
/// unavailable. Callers may retry after the app returns to the foreground.
final class CredentialVaultTemporarilyUnavailable implements Exception {
  const CredentialVaultTemporarilyUnavailable();

  @override
  String toString() => 'CredentialVaultTemporarilyUnavailable()';
}

final class SecureCredentialVault
    implements
        CredentialVault,
        PendingRevocationStore,
        PendingRevocationClaims {
  SecureCredentialVault({
    FlutterSecureStorage? storage,
    Future<Directory> Function()? supportDirectory,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  static const _androidOptions = AndroidOptions(
    resetOnError: false,
    migrateWithBackup: true,
    storageNamespace: 'nks_nextcloud_talk',
  );
  static const _iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
    synchronizable: false,
  );
  static const _macOsOptions = MacOsOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
    synchronizable: false,
    // The login Keychain supports sandboxed ad-hoc builds without a restricted
    // access-group entitlement.
    usesDataProtectionKeychain: false,
  );

  final FlutterSecureStorage _storage;
  final Future<Directory> Function() _supportDirectory;
  final Map<String, Future<void>> _migrations = {};

  static const _currentVersion = 2;

  /// Passwords already read on iOS and desktop. Android's vault worker shares
  /// its cache across engines. A null result may precede a ready keystore.
  final Map<String, String> _passwords = {};
  var _passwordEpoch = 0;

  /// Dropped before and after a change, and the epoch moves, so a read that
  /// overlaps it can neither be served nor leave behind the old value.
  void _forgetPassword(String accountId) {
    _passwordEpoch++;
    _passwords.remove(accountId);
  }

  @override
  Future<void> writeAppPassword(String accountId, String appPassword) async {
    if (Platform.isAndroid) {
      await _androidVault.invokeMethod<void>('writeAppPassword', {
        'accountId': accountId,
        'password': appPassword,
      });
      return;
    }
    _forgetPassword(accountId);
    try {
      await _ensureCurrent(accountId);
      await _write(_currentKey(accountId), appPassword);
    } finally {
      _forgetPassword(accountId);
    }
  }

  @override
  Future<String?> readAppPassword(String accountId) =>
      _readAppPassword(accountId, refresh: false);

  Future<String?> _readAppPassword(
    String accountId, {
    required bool refresh,
  }) async {
    if (Platform.isAndroid) {
      return _androidVault.invokeMethod<String>('readAppPassword', {
        'accountId': accountId,
        if (refresh) 'refresh': true,
      });
    }
    if (refresh) _forgetPassword(accountId);
    final cached = _passwords[accountId];
    if (cached != null) {
      return cached;
    }
    final epoch = _passwordEpoch;
    await _ensureCurrent(accountId);
    final password = await _read(_currentKey(accountId));
    if (password != null && epoch == _passwordEpoch) {
      _passwords[accountId] = password;
    }
    return password;
  }

  @override
  Future<void> deleteAppPassword(String accountId) async {
    if (Platform.isAndroid) {
      await _androidVault.invokeMethod<void>('deleteAppPassword', {
        'accountId': accountId,
      });
      return;
    }
    _forgetPassword(accountId);
    try {
      await _ensureCurrent(accountId);
      await _delete(_currentKey(accountId));
    } finally {
      _forgetPassword(accountId);
    }
  }

  static const _pendingRevocationsKey = 'nks.pending_revocations';
  static const _pendingRevocationsMarker = 'pending-revocations';
  static const _pendingRevocationsReconciled = 'pending-revocations-reconciled';
  static const _androidVault = MethodChannel(
    'com.nkshub.nextcloudtalk/credential_vault',
  );
  static Future<void> _pendingRevocationMutationTail = Future<void>.value();
  static final _localRevocationClaims = <String, String>{};

  Future<void> _withAndroidPendingRevocationDrain(
    Future<void> Function() drain,
  ) async {
    final token = {'token': const Uuid().v4()};
    final acquired = await _androidVault.invokeMethod<bool>(
      'acquireRevocationDrain',
      token,
    );
    if (acquired != true) return;
    try {
      await drain();
    } finally {
      await _androidVault.invokeMethod<void>('releaseRevocationDrain', token);
    }
  }

  @override
  Future<bool> tryClaimRevocation(String id, String token) async {
    if (Platform.isAndroid) {
      return await _androidVault.invokeMethod<bool>('claimRevocation', {
            'id': id,
            'token': token,
          }) ==
          true;
    }
    if (_localRevocationClaims.containsKey(id)) return false;
    _localRevocationClaims[id] = token;
    return true;
  }

  @override
  Future<void> releaseRevocationClaim(String id, String token) async {
    if (Platform.isAndroid) {
      await _androidVault.invokeMethod<void>('releaseRevocationClaim', {
        'id': id,
        'token': token,
      });
    } else if (_localRevocationClaims[id] == token) {
      _localRevocationClaims.remove(id);
    }
  }

  var _reconciled = false;

  /// Says whether the queue holds anything, outside the platform keystore.
  ///
  /// Every drain — start, connectivity, resume — reads the queue, and on Linux
  /// the keystore unlocks the keyring synchronously on the platform thread.
  /// A locked keyring whose prompt nobody answers never returns, and that is
  /// the thread that shows the window, so the app ends up with no window at
  /// all. The queue is empty on almost every device, and this file answers
  /// that without opening the keystore.
  Future<File> _pendingRevocationsMarkerFile() async =>
      File('${(await _supportDirectory()).path}/$_pendingRevocationsMarker');

  @override
  Future<String?> readPendingRevocations() async {
    if (Platform.isAndroid) {
      return _androidVault.invokeMethod<String>('readPendingRevocations');
    }
    if (!await (await _pendingRevocationsMarkerFile()).exists()) {
      return null;
    }
    return _read(_pendingRevocationsKey);
  }

  @override
  Future<void> writePendingRevocations(String? json) {
    if (Platform.isAndroid) {
      return _updateAndroidPendingRevocations((_) => json);
    }
    return _withLocalPendingRevocationsLock(
      () => _writePendingRevocations(json),
    );
  }

  @override
  Future<void> updatePendingRevocations(
    String? Function(String? current) update,
  ) {
    if (Platform.isAndroid) {
      return _updateAndroidPendingRevocations(update);
    }
    return _withLocalPendingRevocationsLock(() async {
      final current = await readPendingRevocations();
      await _writePendingRevocations(update(current));
    });
  }

  Future<void> _writePendingRevocations(String? json) async {
    final marker = await _pendingRevocationsMarkerFile();
    if (json == null) {
      await _delete(_pendingRevocationsKey);
      if (await marker.exists()) {
        await marker.delete();
      }
      return;
    }
    // Marker first: one left behind costs a single keystore read, one missing
    // would hide a revocation the server is still waiting for.
    await marker.create(recursive: true);
    await _write(_pendingRevocationsKey, json);
  }

  Future<void> _updateAndroidPendingRevocations(
    String? Function(String? current) update,
  ) async {
    while (true) {
      final current = await readPendingRevocations();
      final next = update(current);
      final written =
          await _androidVault.invokeMethod<bool>(
            'compareAndSetPendingRevocations',
            <String, Object?>{'expected': current, 'updated': next},
          ) ??
          false;
      if (written) {
        return;
      }
    }
  }

  Future<T> _withLocalPendingRevocationsLock<T>(
    Future<T> Function() operation,
  ) {
    final result = _pendingRevocationMutationTail.then((_) => operation());
    _pendingRevocationMutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// Gives the marker to an installation that queued a revocation before the
  /// marker existed, which would otherwise never be drained again and would
  /// leave an app password alive on its server.
  ///
  /// Runs off the back of a keystore read that has already returned, so the
  /// keyring is provably open and this cannot be the call that blocks. Once
  /// per installation: the second file records that it happened.
  Future<void> _reconcilePendingMarker() async {
    if (_reconciled) {
      return;
    }
    _reconciled = true;
    // Android owns this one key in a process-wide native queue. It neither
    // needs the Linux keyring marker nor may race that native writer through
    // flutter_secure_storage from another engine.
    if (Platform.isAndroid) {
      return;
    }
    final done = File(
      '${(await _supportDirectory()).path}/$_pendingRevocationsReconciled',
    );
    if (await done.exists()) {
      return;
    }
    if (await _read(_pendingRevocationsKey) != null) {
      await (await _pendingRevocationsMarkerFile()).create(recursive: true);
    }
    await done.create(recursive: true);
  }

  Future<void> _ensureCurrent(String accountId) async {
    final running = _migrations[accountId];
    if (running != null) {
      return running;
    }
    final migration = _migrate(accountId);
    _migrations[accountId] = migration;
    try {
      await migration;
    } on Object {
      if (identical(_migrations[accountId], migration)) {
        _migrations.remove(accountId);
      }
      rethrow;
    }
  }

  Future<void> _migrate(String accountId) async {
    final versionKey = _versionKey(accountId);
    final marker = await _read(versionKey);
    final version = marker == null ? 1 : int.tryParse(marker);
    if (version == null || version < 1 || version > _currentVersion) {
      throw StateError('Unsupported credential vault version');
    }

    final legacyKey = _legacyKey(accountId);
    final currentKey = _currentKey(accountId);
    final legacy = await _read(legacyKey);
    var current = await _read(currentKey);
    if (legacy != null && current != null && legacy != current) {
      throw StateError('Conflicting credential vault values');
    }
    if (current == null && legacy != null) {
      await _write(currentKey, legacy);
      current = await _read(currentKey);
      if (current != legacy) {
        throw StateError('Credential vault copy verification failed');
      }
    }

    if (version < _currentVersion) {
      await _write(versionKey, '$_currentVersion');
      if (await _read(versionKey) != '$_currentVersion') {
        throw StateError('Credential vault marker verification failed');
      }
    }
    if (legacy != null) {
      await _delete(legacyKey);
    }
  }

  Future<void> _write(String key, String value) {
    return _translateTemporaryAppleFailure(
      () => _storage.write(
        key: key,
        value: value,
        aOptions: _androidOptions,
        iOptions: _iosOptions,
        mOptions: _macOsOptions,
      ),
    );
  }

  Future<String?> _read(String key) async {
    final value = await _translateTemporaryAppleFailure(
      () => _storage.read(
        key: key,
        aOptions: _androidOptions,
        iOptions: _iosOptions,
        mOptions: _macOsOptions,
      ),
    );
    try {
      await _reconcilePendingMarker();
    } on Object {
      // A bookkeeping chore must never fail the credential read it rode in on;
      // the next launch retries it, because nothing was written down.
    }
    return value;
  }

  Future<void> _delete(String key) {
    return _translateTemporaryAppleFailure(
      () => _storage.delete(
        key: key,
        aOptions: _androidOptions,
        iOptions: _iosOptions,
        mOptions: _macOsOptions,
      ),
    );
  }

  Future<T> _translateTemporaryAppleFailure<T>(
    Future<T> Function() operation,
  ) async {
    try {
      return await operation();
    } on PlatformException catch (error) {
      final status = switch (error.details) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value),
        _ => null,
      };
      if (status == -25320 || status == -60008) {
        throw const CredentialVaultTemporarilyUnavailable();
      }
      rethrow;
    }
  }

  String _legacyKey(String accountId) => 'account.$accountId.appPassword';

  String _currentKey(String accountId) =>
      'credential.v$_currentVersion.account.$accountId.appPassword';

  String _versionKey(String accountId) =>
      'credential.account.$accountId.version';
}
