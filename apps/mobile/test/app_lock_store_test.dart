import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/settings/app_lock/app_lock_store.dart';

void main() {
  test('a missing preference leaves app lock disabled', () async {
    final store = SecureAppLockStore(storage: _MemorySecureStorage());

    expect(await store.readEnabled(), isFalse);
  });

  test(
    'enabled and disabled values round-trip through secure storage',
    () async {
      final storage = _MemorySecureStorage();
      final store = SecureAppLockStore(storage: storage);

      await store.writeEnabled(true);
      expect(await store.readEnabled(), isTrue);
      await store.writeEnabled(false);
      expect(await store.readEnabled(), isFalse);
    },
  );

  test('an invalid value fails closed instead of disabling the lock', () async {
    final storage = _MemorySecureStorage()..value = 'damaged';
    final store = SecureAppLockStore(storage: storage);

    await expectLater(store.readEnabled(), throwsFormatException);
  });
}

final class _MemorySecureStorage extends FlutterSecureStorage {
  String? value;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => value;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    this.value = value;
  }
}
