import 'package:local_auth/local_auth.dart';

abstract interface class AppLockAuthenticator {
  Future<bool> isSupported();

  Future<bool> authenticate(String reason);
}

final class SystemAppLockAuthenticator implements AppLockAuthenticator {
  SystemAppLockAuthenticator({LocalAuthentication? authentication})
    : _authentication = authentication ?? LocalAuthentication();

  final LocalAuthentication _authentication;

  @override
  Future<bool> isSupported() => _authentication.isDeviceSupported();

  @override
  Future<bool> authenticate(String reason) {
    return _authentication.authenticate(
      localizedReason: reason,
      biometricOnly: false,
      persistAcrossBackgrounding: true,
    );
  }
}
