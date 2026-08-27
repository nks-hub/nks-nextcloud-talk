import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/push/android_push_transport.dart';

final class _RecordingStore implements AndroidPushTransportStore {
  _RecordingStore(this.stored);

  AndroidPushTransport stored;
  final List<String> events = [];

  @override
  Future<AndroidPushTransport> read() async => stored;

  @override
  Future<void> write(AndroidPushTransport transport) async {
    events.add('write:${transport.name}');
    stored = transport;
  }
}

void main() {
  test('an untouched device defaults to the proven Web Push transport', () async {
    final directory = Directory.systemTemp.createTempSync('push-transport');
    addTearDown(() => directory.deleteSync(recursive: true));
    final store = FileAndroidPushTransportStore(directory: directory);

    expect(await store.read(), AndroidPushTransport.webPush);
  });

  test('a stored choice survives a restart', () async {
    final directory = Directory.systemTemp.createTempSync('push-transport');
    addTearDown(() => directory.deleteSync(recursive: true));
    final store = FileAndroidPushTransportStore(directory: directory);

    await store.write(AndroidPushTransport.proxy);

    expect(
      await FileAndroidPushTransportStore(directory: directory).read(),
      AndroidPushTransport.proxy,
    );
  });

  test('a corrupt preference file falls back to the proven transport', () async {
    final directory = Directory.systemTemp.createTempSync('push-transport');
    addTearDown(() => directory.deleteSync(recursive: true));
    File(
      '${directory.path}/android_push_transport.txt',
    ).writeAsStringSync('carrier-pigeon');

    expect(
      await FileAndroidPushTransportStore(directory: directory).read(),
      AndroidPushTransport.webPush,
    );
  });

  test('switching revokes the old transport before storing the new one', () async {
    final store = _RecordingStore(AndroidPushTransport.webPush);
    final transportSwitch = AndroidPushTransportSwitch(
      store: store,
      revoke: (transport) async {
        store.events.add('revoke:${transport.name}');
      },
    );

    final result = await transportSwitch.select(
      AndroidPushTransport.proxy,
      current: AndroidPushTransport.webPush,
    );

    expect(result, AndroidPushTransport.proxy);
    expect(store.events, ['revoke:webPush', 'write:proxy']);
  });

  test('switching back revokes the proxy registration first', () async {
    final store = _RecordingStore(AndroidPushTransport.proxy);
    final transportSwitch = AndroidPushTransportSwitch(
      store: store,
      revoke: (transport) async {
        store.events.add('revoke:${transport.name}');
      },
    );

    await transportSwitch.select(
      AndroidPushTransport.webPush,
      current: AndroidPushTransport.proxy,
    );

    expect(store.events, ['revoke:proxy', 'write:webPush']);
  });

  test('a failed revocation leaves the old transport in force', () async {
    final store = _RecordingStore(AndroidPushTransport.webPush);
    final transportSwitch = AndroidPushTransportSwitch(
      store: store,
      revoke: (_) async => throw const SocketException('offline'),
    );

    await expectLater(
      transportSwitch.select(
        AndroidPushTransport.proxy,
        current: AndroidPushTransport.webPush,
      ),
      throwsA(isA<SocketException>()),
    );
    expect(store.events, isEmpty);
    expect(store.stored, AndroidPushTransport.webPush);
  });

  test('re-selecting the live transport revokes nothing', () async {
    final store = _RecordingStore(AndroidPushTransport.proxy);
    final transportSwitch = AndroidPushTransportSwitch(
      store: store,
      revoke: (transport) async {
        store.events.add('revoke:${transport.name}');
      },
    );

    final result = await transportSwitch.select(
      AndroidPushTransport.proxy,
      current: AndroidPushTransport.proxy,
    );

    expect(result, AndroidPushTransport.proxy);
    expect(store.events, isEmpty);
  });
}
