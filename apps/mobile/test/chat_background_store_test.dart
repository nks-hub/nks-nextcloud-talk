import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/chat_background_store.dart';

void main() {
  late Directory directory;
  late ChatBackgroundStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('nctalk-background-');
    store = ChatBackgroundStore.forTesting(directory);
  });

  tearDown(() async {
    await store.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('persists isolated room colours without exposing identifiers', () async {
    const first = (accountId: 'account-a', roomToken: 'rooma123');
    const second = (accountId: 'account-a', roomToken: 'roomb123');
    const other = (accountId: 'account-b', roomToken: 'rooma123');

    await store.write(first, '#12abEF');
    await store.write(second, '#334455');
    await store.write(other, '#667788');

    final reopened = ChatBackgroundStore.forTesting(directory);
    addTearDown(reopened.close);
    expect(await reopened.read(first), '#12ABEF');
    expect(await reopened.read(second), '#334455');
    expect(await reopened.read(other), '#667788');

    final names = await directory.list().map((file) => file.path).toList();
    expect(names.join(), isNot(contains('account-a')));
    final content = await File(names.first).readAsString();
    expect(content, isNot(contains('rooma123')));
  });

  test('serializes overlapping writes and emits the committed value', () async {
    const key = (accountId: 'account-a', roomToken: 'rooma123');
    final values = <String?>[];
    final initialRead = Completer<void>();
    final subscription = store.watch(key).listen((value) {
      values.add(value);
      if (!initialRead.isCompleted) {
        initialRead.complete();
      }
    });
    addTearDown(subscription.cancel);
    await initialRead.future;

    await Future.wait(<Future<void>>[
      store.write(key, '#111111'),
      store.write(key, '#222222'),
      store.write(key, '#333333'),
    ]);

    expect(await store.read(key), '#333333');
    await Future<void>.delayed(Duration.zero);
    expect(values, <String?>[null, '#111111', '#222222', '#333333']);
  });

  test(
    'registers snapshot and concurrent write without an event gap',
    () async {
      await store.close();
      final snapshotReached = Completer<void>();
      final releaseSnapshot = Completer<void>();
      store = ChatBackgroundStore.forTesting(
        directory,
        beforeWatchSnapshot: () {
          if (!snapshotReached.isCompleted) {
            snapshotReached.complete();
          }
          return releaseSnapshot.future;
        },
      );
      const key = (accountId: 'account-a', roomToken: 'rooma123');
      final values = <String?>[];
      final committed = Completer<void>();
      final subscription = store.watch(key).listen((value) {
        values.add(value);
        if (value == '#445566' && !committed.isCompleted) {
          committed.complete();
        }
      });
      addTearDown(subscription.cancel);

      await snapshotReached.future;
      expect(store.activeWatcherCount, 1);
      final write = store.write(key, '#445566');
      releaseSnapshot.complete();
      await write;
      await committed.future;

      expect(values, <String?>[null, '#445566']);
    },
  );

  test('cancelled watchers are removed from the store', () async {
    const key = (accountId: 'account-a', roomToken: 'rooma123');
    final initial = Completer<void>();
    final subscription = store.watch(key).listen((_) {
      if (!initial.isCompleted) {
        initial.complete();
      }
    });

    await initial.future;
    expect(store.activeWatcherCount, 1);
    await subscription.cancel();
    expect(store.activeWatcherCount, 0);
  });

  test('remove clears only the selected room', () async {
    const removed = (accountId: 'account-a', roomToken: 'rooma123');
    const survivor = (accountId: 'account-a', roomToken: 'roomb123');
    await store.write(removed, '#112233');
    await store.write(survivor, '#445566');

    await store.remove(removed);

    expect(await store.read(removed), isNull);
    expect(await store.read(survivor), '#445566');
  });

  test(
    'remove account clears only that account and notifies watchers',
    () async {
      const removed = (accountId: 'account-a', roomToken: 'rooma123');
      const survivor = (accountId: 'account-b', roomToken: 'rooma123');
      await store.write(removed, '#112233');
      await store.write(survivor, '#445566');
      final values = <String?>[];
      final subscription = store.watch(removed).listen(values.add);
      addTearDown(subscription.cancel);
      await Future<void>.delayed(Duration.zero);

      await store.removeAccount('account-a');

      expect(await store.read(removed), isNull);
      expect(await store.read(survivor), '#445566');
      await Future<void>.delayed(Duration.zero);
      expect(values.last, isNull);
    },
  );

  test('recovers backup after an interrupted replacement', () async {
    const key = (accountId: 'account-a', roomToken: 'rooma123');
    await store.write(key, '#123456');
    final file =
        (await directory.list().where((entry) => entry is File).first) as File;
    await file.rename('${file.path}.bak');

    final reopened = ChatBackgroundStore.forTesting(directory);
    addTearDown(reopened.close);
    expect(await reopened.read(key), '#123456');
    expect(await file.exists(), isTrue);
  });

  test('corrupt and oversized state fail closed to the default', () async {
    const key = (accountId: 'account-a', roomToken: 'rooma123');
    await store.write(key, '#123456');
    final state =
        (await directory.list().where((entry) => entry is File).first) as File;
    await state.writeAsString('{not-json', flush: true);
    expect(await store.read(key), isNull);

    await state.writeAsBytes(
      List<int>.filled(512 * 1024 + 1, 0x20),
      flush: true,
    );
    expect(await store.read(key), isNull);
    expect(
      () => store.write(key, 'transparent'),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('failed writes do not poison the serial executor', () async {
    await store.close();
    final blocked = File('${directory.path}${Platform.pathSeparator}blocked')
      ..writeAsStringSync('not a directory');
    store = ChatBackgroundStore.forTesting(Directory(blocked.path));
    const key = (accountId: 'account-a', roomToken: 'rooma123');

    await expectLater(store.write(key, '#123456'), throwsA(isA<Object>()));

    await store.close().timeout(const Duration(seconds: 1));
  });
}
