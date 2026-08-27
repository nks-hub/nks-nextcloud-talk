import 'package:flutter/services.dart';

import 'apple_push_channel.dart';

/// Generates and stores this device's per-account RSA-2048 push key.
///
/// The private half never leaves the platform Keychain — [ensureKey] only
/// ever returns the public key's PEM. A Notification Service Extension
/// (not built yet) would be the only other thing on-device that ever touches
/// the private key, to decrypt an incoming push.
abstract interface class PushDeviceKeyStore {
  /// Returns the SubjectPublicKeyInfo PEM for [handle], generating a
  /// Keychain-resident RSA-2048 keypair on first use and reusing it on every
  /// later call with the same handle.
  Future<String> ensureKey(String handle);

  /// Deletes the Keychain-resident keypair for [handle], if any.
  Future<void> destroyKey(String handle);
}

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
}
