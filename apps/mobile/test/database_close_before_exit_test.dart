import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:drift/isolate.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/app_database.dart';

/// Hosts an in-memory database the way drift_flutter hosts the real one: the
/// isolate registers itself, serves until the last client leaves, then dies.
void _host(SendPort reply) {
  registerDatabaseHost();
  final server = DriftIsolate.inCurrent(
    () => NativeDatabase.memory(),
    killIsolateWhenDone: true,
    shutdownAfterLastDisconnect: true,
  );
  reply.send(server.connectPort);
}

void main() {
  tearDown(() => IsolateNameServer.removePortNameMapping(databaseHostPortName));

  test('waits for the isolate owning SQLite to exit before quit', () async {
    final connectPort = ReceivePort();
    await Isolate.spawn(_host, connectPort.sendPort);
    final port = await connectPort.first as SendPort;
    final database = AppDatabase.forTesting(
      await DriftIsolate.fromConnectPort(port).connect(),
    );
    // Prepared statements are what the VM teardown used to finalize.
    await database.customSelect('SELECT 1').get();
    await database.select(database.accounts).get();

    expect(await database.closeBeforeExit(), isTrue);
    expect(IsolateNameServer.lookupPortByName(databaseHostPortName), isNull);
  });

  test('closes without waiting when no host isolate is registered', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customSelect('SELECT 1').get();

    expect(await database.closeBeforeExit(), isFalse);
  });
}
