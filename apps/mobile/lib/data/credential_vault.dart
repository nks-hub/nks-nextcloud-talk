import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class CredentialVault {
  Future<void> writeAppPassword(String accountId, String appPassword);

  Future<String?> readAppPassword(String accountId);

  Future<void> deleteAppPassword(String accountId);
}

final class SecureCredentialVault implements CredentialVault {
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
    return _storage.write(
      key: key,
      value: value,
      aOptions: _androidOptions,
      iOptions: _iosOptions,
      mOptions: _macOsOptions,
    );
  }

  Future<String?> _read(String key) {
    return _storage.read(
      key: key,
      aOptions: _androidOptions,
      iOptions: _iosOptions,
      mOptions: _macOsOptions,
    );
  }

  Future<void> _delete(String key) {
    return _storage.delete(
      key: key,
      aOptions: _androidOptions,
      iOptions: _iosOptions,
      mOptions: _macOsOptions,
    );
  }

  String _legacyKey(String accountId) => 'account.$accountId.appPassword';

  String _currentKey(String accountId) =>
      'credential.v$_currentVersion.account.$accountId.appPassword';

  String _versionKey(String accountId) =>
      'credential.account.$accountId.version';
}
