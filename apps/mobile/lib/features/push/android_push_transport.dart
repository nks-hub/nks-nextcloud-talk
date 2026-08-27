// ignore_for_file: prefer_initializing_formals

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Which way this Android device registers for push.
///
/// [proxy] is the native path: push v2 against our own `nks-talk-notify`
/// proxy, the same wire contract iOS uses. [webPush] is the Web Push /
/// UnifiedPush path — it routes through the public
/// `fcm.distributor.unifiedpush.org` rewrite gateway, which is exactly what
/// [proxy] exists to avoid.
///
/// [webPush] is still the default. It is the only branch proven end to end on
/// a real device, and shipping an unproven default would take notifications
/// away on the one platform where they work today. The default flips to
/// [proxy] once the proxy path has registered a real device.
enum AndroidPushTransport { proxy, webPush }

/// What an untouched device uses. See [AndroidPushTransport] for why this is
/// not the proxy yet.
const _defaultTransport = AndroidPushTransport.webPush;

/// The same value, for the provider that seeds the runtime state before the
/// stored choice has been read back.
const androidPushTransportDefault = _defaultTransport;

/// Persists the chosen [AndroidPushTransport]. Not per-account: one device
/// registers one way, the same shape as the theme preference.
///
/// Anything unreadable reads back as the default, so a corrupt file leaves
/// the device on the proven transport rather than on none.
abstract interface class AndroidPushTransportStore {
  Future<AndroidPushTransport> read();

  Future<void> write(AndroidPushTransport transport);
}

final class FileAndroidPushTransportStore implements AndroidPushTransportStore {
  FileAndroidPushTransportStore({Directory? directory})
    : _directory = directory;

  final Directory? _directory;

  Future<File> _file() async {
    final dir = _directory ?? await getApplicationSupportDirectory();
    return File('${dir.path}/android_push_transport.txt');
  }

  @override
  Future<AndroidPushTransport> read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return _defaultTransport;
      }
      final raw = (await file.readAsString()).trim();
      return AndroidPushTransport.values.firstWhere(
        (transport) => transport.name == raw,
        orElse: () => _defaultTransport,
      );
    } on Object {
      return _defaultTransport;
    }
  }

  @override
  Future<void> write(AndroidPushTransport transport) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(transport.name);
  }
}

/// Moves this device from one push transport to the other.
///
/// The order matters more than anything else here. Nextcloud keys a push
/// registration by device, not by transport, so registering the new path
/// before the old one is gone leaves two rows claiming the same device and
/// notifications start arriving twice, or down the dead path. [select]
/// therefore revokes the current transport at Nextcloud *and* at its gateway
/// first, and only stores the new choice once that came back clean. A failed
/// revocation keeps the old transport in place — a device that still works
/// the old way beats a device registered nowhere.
final class AndroidPushTransportSwitch {
  AndroidPushTransportSwitch({
    required AndroidPushTransportStore store,
    required Future<void> Function(AndroidPushTransport transport) revoke,
  }) : _store = store,
       _revoke = revoke;

  final AndroidPushTransportStore _store;
  final Future<void> Function(AndroidPushTransport transport) _revoke;

  Future<AndroidPushTransport> load() => _store.read();

  /// Revokes [current] and stores [next], returning the transport that is now
  /// in force. Returns [current] unchanged when the two are the same; throws
  /// without switching when the revocation fails.
  Future<AndroidPushTransport> select(
    AndroidPushTransport next, {
    required AndroidPushTransport current,
  }) async {
    if (next == current) {
      return current;
    }
    await _revoke(current);
    await _store.write(next);
    return next;
  }
}
