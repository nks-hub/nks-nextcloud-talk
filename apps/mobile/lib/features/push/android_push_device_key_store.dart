import 'package:flutter/services.dart';

import 'apple_push_device_key_store.dart';

/// [PushDeviceKeyStore] backed by the Android Keystore.
///
/// The private half of the RSA-2048 keypair is generated inside the keystore
/// and never leaves it; [ensureKey] only ever returns the SubjectPublicKeyInfo
/// PEM. That private key is what decrypts an incoming push-v2 `subject`, so it
/// is per account: the handle the coordinator passes in is derived from the
/// account id, and one account can never read another's notification.
final class AndroidPushDeviceKeyChannel implements PushDeviceKeyStore {
  AndroidPushDeviceKeyChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.nkshub.nextcloudtalk/push_device_key';

  final MethodChannel _channel;

  @override
  Future<String> ensureKey(String handle) async {
    final pem = await _channel.invokeMethod<String>('generateDeviceKey', {
      'handle': handle,
    });
    if (pem == null || pem.isEmpty) {
      throw const FormatException(
        'Native device key generation returned nothing.',
      );
    }
    return pem;
  }

  @override
  Future<void> destroyKey(String handle) async {
    await _channel.invokeMethod<void>('destroyDeviceKey', {'handle': handle});
  }
}
