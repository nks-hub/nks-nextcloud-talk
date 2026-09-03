import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart' show PlatformException;

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
    implements CredentialVault, PendingRevocationStore {
  SecureCredentialVault({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

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
  final Map<String, Future<void>> _migrations = {};

  static const _currentVersion = 2;

  @override
  Future<void> writeAppPassword(String accountId, String appPassword) async {
    await _ensureCurrent(accountId);
    await _write(_currentKey(accountId), appPassword);
  }

  @override
  Future<String?> readAppPassword(String accountId) async {
    await _ensureCurrent(accountId);
    return _read(_currentKey(accountId));
  }

  @override
  Future<void> deleteAppPassword(String accountId) async {
    await _ensureCurrent(accountId);
    await _delete(_currentKey(accountId));
  }

  static const _pendingRevocationsKey = 'nks.pending_revocations';

  @override
  Future<String?> readPendingRevocations() => _read(_pendingRevocationsKey);

  @override
  Future<void> writePendingRevocations(String? json) => json == null
      ? _delete(_pendingRevocationsKey)
      : _write(_pendingRevocationsKey, json);

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

  Future<String?> _read(String key) {
    return _translateTemporaryAppleFailure(
      () => _storage.read(
        key: key,
        aOptions: _androidOptions,
        iOptions: _iosOptions,
        mOptions: _macOsOptions,
      ),
    );
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
