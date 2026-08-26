import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/credential_vault.dart';

void main() {
  test('uses the device-local login Keychain on macOS', () async {
    final storage = _RecordingSecureStorage();
    final vault = SecureCredentialVault(storage: storage);

    await vault.writeAppPassword('account-a', 'app-password');
    expect(await vault.readAppPassword('account-a'), 'app-password');
    await vault.deleteAppPassword('account-a');

    expect(storage.calls, hasLength(3));
    for (final call in storage.calls) {
      expect(call.key, 'account.account-a.appPassword');
      expect(call.iosOptions, isA<IOSOptions>());
      expect(call.macOsOptions, isA<MacOsOptions>());
      expect(call.macOsOptions.toMap(), {
        'accountName': 'flutter_secure_storage_service',
        'accessibility': 'first_unlock_this_device',
        'synchronizable': 'false',
        'useSecureEnclave': 'false',
        'usesDataProtectionKeychain': 'false',
      });
    }
    expect(storage.calls.first.value, 'app-password');
    expect(storage.calls[1].value, isNull);
    expect(storage.calls.last.value, isNull);
  });
}

final class _StorageCall {
  const _StorageCall({
    required this.key,
    required this.value,
    required this.iosOptions,
    required this.macOsOptions,
  });

  final String key;
  final String? value;
  final AppleOptions iosOptions;
  final AppleOptions macOsOptions;
}

final class _RecordingSecureStorage extends FlutterSecureStorage {
  final Map<String, String> _values = {};
  final List<_StorageCall> calls = [];

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
    _record(key: key, value: value, iOptions: iOptions, mOptions: mOptions);
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _record(key: key, value: null, iOptions: iOptions, mOptions: mOptions);
    return _values[key];
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _record(key: key, value: null, iOptions: iOptions, mOptions: mOptions);
    _values.remove(key);
  }

  void _record({
    required String key,
    required String? value,
    required AppleOptions? iOptions,
    required AppleOptions? mOptions,
  }) {
    calls.add(
      _StorageCall(
        key: key,
        value: value,
        iosOptions: iOptions!,
        macOsOptions: mOptions!,
      ),
    );
  }
}
