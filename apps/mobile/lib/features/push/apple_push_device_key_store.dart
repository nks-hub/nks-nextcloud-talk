import 'package:flutter/services.dart';

import 'apple_push_channel.dart';
import 'push_device_key_store.dart';

export 'push_device_key_store.dart' show PushDeviceKeyStore;

/// [PushDeviceKeyStore] backed by the same
/// `com.nkshub.nextcloudtalk/apple_push` channel [ApplePushCoordinator]
/// uses — `AppDelegate.swift` wires both onto one native `PushDeviceKeyStore`
/// (the Swift class, not this interface) so a device key always lives next
/// to the Keychain APIs it depends on.
final class ApplePushDeviceKeyChannel implements PushDeviceKeyStore {
  ApplePushDeviceKeyChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(ApplePushCoordinator.channelName);

  final MethodChannel _channel;

  @override
  Future<String> ensureKey(String handle) async {
    final pem = await _channel.invokeMethod<String>('generateDeviceKey', {
      'handle': handle,
    });
    if (pem == null || pem.isEmpty) {
      throw const FormatException('Native device key generation returned nothing.');
    }
    return pem;
  }

  @override
  Future<void> destroyKey(String handle) async {
    await _channel.invokeMethod<void>('destroyDeviceKey', {'handle': handle});
  }

  /// Records which account owns the key at [handle], so the Notification
  /// Service Extension learns the account directly once a push decrypts,
  /// rather than having to reconstruct it later from the server host — which
  /// is ambiguous when two accounts share one server. iOS-only: kept off
  /// [PushDeviceKeyStore] itself because Android, which implements that same
  /// shared interface, has no equivalent need.
  Future<void> recordAccount(String handle, String accountId) async {
    await _channel.invokeMethod<void>('recordDeviceKeyAccount', {
      'handle': handle,
      'accountId': accountId,
    });
  }
}
