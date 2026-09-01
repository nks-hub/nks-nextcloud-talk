import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class AppLockStore {
  Future<bool> readEnabled();

  Future<void> writeEnabled(bool enabled);
}

final class SecureAppLockStore implements AppLockStore {
  SecureAppLockStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'app_lock_enabled_v1';
  final FlutterSecureStorage _storage;

  @override
  Future<bool> readEnabled() async {
    return switch (await _storage.read(key: _key)) {
      null || 'disabled' => false,
      'enabled' => true,
      _ => throw const FormatException('Invalid app lock preference.'),
    };
  }

  @override
  Future<void> writeEnabled(bool enabled) async {
    await _storage.write(key: _key, value: enabled ? 'enabled' : 'disabled');
  }
}
