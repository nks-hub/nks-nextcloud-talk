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

  @override
  Future<void> writeAppPassword(String accountId, String appPassword) {
    return _storage.write(
      key: _key(accountId),
      value: appPassword,
      aOptions: _androidOptions,
      iOptions: _iosOptions,
      mOptions: _macOsOptions,
    );
  }

  @override
  Future<String?> readAppPassword(String accountId) {
    return _storage.read(
      key: _key(accountId),
      aOptions: _androidOptions,
      iOptions: _iosOptions,
      mOptions: _macOsOptions,
    );
  }

  @override
  Future<void> deleteAppPassword(String accountId) {
    return _storage.delete(
      key: _key(accountId),
      aOptions: _androidOptions,
      iOptions: _iosOptions,
      mOptions: _macOsOptions,
    );
  }

  String _key(String accountId) => 'account.$accountId.appPassword';
}
