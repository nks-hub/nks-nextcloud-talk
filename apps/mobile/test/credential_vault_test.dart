import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/credential_vault.dart';

void main() {
  test('writes current credentials with device-local Apple options', () async {
    final storage = _RecordingSecureStorage();
    final vault = SecureCredentialVault(storage: storage);

    await vault.writeAppPassword('account-a', 'app-password');
    expect(await vault.readAppPassword('account-a'), 'app-password');
    await vault.deleteAppPassword('account-a');

    expect(storage.valueFor('credential.account.account-a.version'), '2');
    expect(
      storage.valueFor('credential.v2.account.account-a.appPassword'),
      isNull,
    );
    for (final call in storage.calls) {
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
  });

  test('migrates a legacy account once and removes its old key', () async {
    final storage = _RecordingSecureStorage()
      ..seed('account.account-a.appPassword', 'legacy-password');
    final vault = SecureCredentialVault(storage: storage);

    expect(await vault.readAppPassword('account-a'), 'legacy-password');

    expect(
      storage.valueFor('credential.v2.account.account-a.appPassword'),
      'legacy-password',
    );
    expect(storage.valueFor('credential.account.account-a.version'), '2');
    expect(storage.valueFor('account.account-a.appPassword'), isNull);
    expect(
      storage.calls.where((call) => call.operation == _Operation.delete),
      hasLength(1),
    );
  });

  test(
    'resumes after interruption without losing either credential copy',
    () async {
      const versionKey = 'credential.account.account-a.version';
      const currentKey = 'credential.v2.account.account-a.appPassword';
      const legacyKey = 'account.account-a.appPassword';
      final storage = _RecordingSecureStorage()
        ..seed(legacyKey, 'legacy-password')
        ..failNextWrite(versionKey);

      await expectLater(
        SecureCredentialVault(storage: storage).readAppPassword('account-a'),
        throwsA(isA<StateError>()),
      );
      expect(storage.valueFor(legacyKey), 'legacy-password');
      expect(storage.valueFor(currentKey), 'legacy-password');
      expect(storage.valueFor(versionKey), isNull);

      final restarted = SecureCredentialVault(storage: storage);
      expect(await restarted.readAppPassword('account-a'), 'legacy-password');
      expect(storage.valueFor(versionKey), '2');
      expect(storage.valueFor(legacyKey), isNull);
    },
  );

  test('serializes concurrent migration requests for one account', () async {
    const versionKey = 'credential.account.account-a.version';
    final storage = _RecordingSecureStorage()
      ..seed('account.account-a.appPassword', 'legacy-password');
    final vault = SecureCredentialVault(storage: storage);

    final values = await Future.wait([
      vault.readAppPassword('account-a'),
      vault.readAppPassword('account-a'),
    ]);

    expect(values, ['legacy-password', 'legacy-password']);
    expect(
      storage.calls.where(
        (call) => call.operation == _Operation.write && call.key == versionKey,
      ),
      hasLength(1),
    );
  });

  test(
    'fails closed on conflicting values and preserves both copies',
    () async {
      const currentKey = 'credential.v2.account.account-a.appPassword';
      const legacyKey = 'account.account-a.appPassword';
      final storage = _RecordingSecureStorage()
        ..seed(legacyKey, 'legacy-password')
        ..seed(currentKey, 'different-password');

      await expectLater(
        SecureCredentialVault(storage: storage).readAppPassword('account-a'),
        throwsA(isA<StateError>()),
      );

      expect(storage.valueFor(legacyKey), 'legacy-password');
      expect(storage.valueFor(currentKey), 'different-password');
      expect(storage.valueFor('credential.account.account-a.version'), isNull);
    },
  );

  test(
    'rejects a newer vault version without touching its credential',
    () async {
      const versionKey = 'credential.account.account-a.version';
      const currentKey = 'credential.v2.account.account-a.appPassword';
      final storage = _RecordingSecureStorage()
        ..seed(versionKey, '3')
        ..seed(currentKey, 'future-password');

      await expectLater(
        SecureCredentialVault(storage: storage).readAppPassword('account-a'),
        throwsA(isA<StateError>()),
      );

      expect(storage.valueFor(versionKey), '3');
      expect(storage.valueFor(currentKey), 'future-password');
    },
  );

  for (final status in const <int>[-25320, -60008]) {
    test(
      'keeps a credential retryable when Apple security returns $status',
      () async {
        const currentKey = 'credential.v2.account.account-a.appPassword';
        final storage = _RecordingSecureStorage()
          ..seed('credential.account.account-a.version', '2')
          ..seed(currentKey, 'app-password')
          ..failNextReadWithAppleStatus(status);
        final vault = SecureCredentialVault(storage: storage);

        await expectLater(
          vault.readAppPassword('account-a'),
          throwsA(isA<CredentialVaultTemporarilyUnavailable>()),
        );

        expect(storage.valueFor(currentKey), 'app-password');
        expect(await vault.readAppPassword('account-a'), 'app-password');
      },
    );
  }

  test('preserves non-transient Apple security failures', () async {
    final storage = _RecordingSecureStorage()
      ..failNextReadWithAppleStatus(-25293);

    await expectLater(
      SecureCredentialVault(storage: storage).readAppPassword('account-a'),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.details,
          'details',
          -25293,
        ),
      ),
    );
  });

  test(
    'a shared transient migration stays retryable for every waiter',
    () async {
      const currentKey = 'credential.v2.account.account-a.appPassword';
      final storage = _RecordingSecureStorage()
        ..seed('credential.account.account-a.version', '2')
        ..seed(currentKey, 'app-password')
        ..failNextReadWithAppleStatus(-25320);
      final vault = SecureCredentialVault(storage: storage);

      final first = vault.readAppPassword('account-a');
      final second = vault.readAppPassword('account-a');
      await Future.wait<void>([
        expectLater(
          first,
          throwsA(isA<CredentialVaultTemporarilyUnavailable>()),
        ),
        expectLater(
          second,
          throwsA(isA<CredentialVaultTemporarilyUnavailable>()),
        ),
      ]);

      expect(storage.valueFor(currentKey), 'app-password');
      expect(await vault.readAppPassword('account-a'), 'app-password');
    },
  );
}

enum _Operation { read, write, delete }

final class _StorageCall {
  const _StorageCall({
    required this.operation,
    required this.key,
    required this.value,
    required this.iosOptions,
    required this.macOsOptions,
  });

  final _Operation operation;
  final String key;
  final String? value;
  final AppleOptions iosOptions;
  final AppleOptions macOsOptions;
}

final class _RecordingSecureStorage extends FlutterSecureStorage {
  final Map<String, String> _values = {};
  final Set<String> _failingWrites = {};
  final List<int> _failingReadStatuses = [];
  final List<_StorageCall> calls = [];

  void seed(String key, String value) => _values[key] = value;

  String? valueFor(String key) => _values[key];

  void failNextWrite(String key) => _failingWrites.add(key);

  void failNextReadWithAppleStatus(int status) {
    _failingReadStatuses.add(status);
  }

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
    _record(
      operation: _Operation.write,
      key: key,
      value: value,
      iOptions: iOptions,
      mOptions: mOptions,
    );
    if (_failingWrites.remove(key)) {
      throw StateError('interrupted secure-storage write');
    }
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
    _record(
      operation: _Operation.read,
      key: key,
      value: null,
      iOptions: iOptions,
      mOptions: mOptions,
    );
    if (_failingReadStatuses.isNotEmpty) {
      final status = _failingReadStatuses.removeAt(0);
      throw PlatformException(
        code: 'Unexpected security result code',
        message: 'Synthetic Apple security failure',
        details: status,
      );
    }
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
    _record(
      operation: _Operation.delete,
      key: key,
      value: null,
      iOptions: iOptions,
      mOptions: mOptions,
    );
    _values.remove(key);
  }

  void _record({
    required _Operation operation,
    required String key,
    required String? value,
    required AppleOptions? iOptions,
    required AppleOptions? mOptions,
  }) {
    calls.add(
      _StorageCall(
        operation: operation,
        key: key,
        value: value,
        iosOptions: iOptions!,
        macOsOptions: mOptions!,
      ),
    );
  }
}
