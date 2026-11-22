import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/chat_media_cache.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('chat-media-disk-cache');
  });

  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  ChatMediaDiskCache open({
    int maximumBytes = 64 * 1024 * 1024,
    Future<FileStat> Function(File file)? statFile,
    Future<void> Function(File file)? deleteFile,
    Future<void> Function(File file, DateTime touchedAt)? touchFile,
  }) {
    return ChatMediaDiskCache(
      rootDirectory: () async => Directory('${root.path}/previews'),
      maximumBytes: maximumBytes,
      statFile: statFile,
      deleteFile: deleteFile,
      touchFile: touchFile,
    );
  }

  ChatMediaImage image(int bytes, [int fill = 7]) => ChatMediaImage(
    body: Uint8List(bytes)..fillRange(0, bytes, fill),
    contentType: 'image/png',
  );

  Iterable<File> storedPreviews() => Directory(
    p.join(root.path, 'previews'),
  ).listSync(recursive: true).whereType<File>();

  Uri uriFor(int fileId) => Uri.parse(
    'https://cloud.example.invalid/index.php/core/preview'
    '?fileId=$fileId&x=2048&y=2048&a=0',
  );

  test(
    'exact preview eviction survives reopening and preserves other versions',
    () async {
      final first = uriFor(
        42,
      ).replace(queryParameters: {...uriFor(42).queryParameters, 'c': 'v1'});
      final next = first.replace(
        queryParameters: {...first.queryParameters, 'c': 'v2'},
      );
      final cache = open();
      await cache.write(accountId: 'account-a', uri: first, image: image(10));
      await cache.write(accountId: 'account-a', uri: next, image: image(20));
      await cache.write(accountId: 'account-b', uri: first, image: image(30));
      await cache.evict(accountId: 'account-a', uri: first);
      await cache.evict(accountId: 'account-a', uri: first);
      expect(cache.length, 2);
      expect(cache.byteLength, 70);
      final restarted = open();
      expect(await restarted.read(accountId: 'account-a', uri: first), isNull);
      expect(
        (await restarted.read(accountId: 'account-a', uri: next))?.body.length,
        20,
      );
      expect(
        (await restarted.read(accountId: 'account-b', uri: first))?.body.length,
        30,
      );
      expect(restarted.length, 2);
    },
  );

  test('a preview written by one run is served to the next one', () async {
    final uri = uriFor(42);
    await open().write(accountId: 'account-a', uri: uri, image: image(64, 3));

    // A fresh instance stands in for the next cold start.
    final restarted = open();
    final restored = await restarted.read(accountId: 'account-a', uri: uri);

    expect(restored, isNotNull);
    expect(restored!.contentType, 'image/png');
    expect(restored.body.lengthInBytes, 64);
    expect(restored.body.every((byte) => byte == 3), isTrue);
    expect(
      restored.body.buffer.lengthInBytes,
      greaterThan(restored.body.lengthInBytes),
      reason: 'the cached body should remain a view, not a full second copy',
    );
    expect(restarted.length, 1);
  });

  test(
    'a cold scan removes a partial write left by a stopped process',
    () async {
      final previews = Directory('${root.path}/previews');
      await previews.create(recursive: true);
      final partial = File('${previews.path}/entry.part-7');
      await partial.writeAsBytes(const <int>[1, 2, 3]);

      final restarted = open();
      await restarted.read(accountId: 'account-a', uri: uriFor(42));

      expect(partial.existsSync(), isFalse);
      expect(restarted.length, 0);
      expect(restarted.byteLength, 0);
    },
  );

  test('reading a preview does not wait for its recency stamp', () async {
    final gate = Completer<void>();
    final touching = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final uri = uriFor(42);
    final cache = open(
      touchFile: (file, touchedAt) async {
        touching.complete();
        await gate.future;
      },
    );
    await cache.write(accountId: 'account-a', uri: uri, image: image(64));

    final reading = cache.read(accountId: 'account-a', uri: uri);
    await touching.future;

    expect(await reading.timeout(const Duration(milliseconds: 100)), isNotNull);
    gate.complete();
  });

  test('a delayed touch cannot undo a newer touch after reopening', () async {
    final firstTouchGate = Completer<void>();
    final secondTouchStarted = Completer<void>();
    final persisted = [Completer<void>(), Completer<void>()];
    final epoch = DateTime.utc(2020);
    var stampCount = 0;
    final cache = open(
      touchFile: (file, _) async {
        final index = stampCount++;
        if (index == 0) {
          await firstTouchGate.future;
        } else {
          secondTouchStarted.complete();
        }
        await file.setLastModified(epoch.add(Duration(minutes: 1 + 2 * index)));
        persisted[index].complete();
      },
    );
    await cache.write(
      accountId: 'account-a',
      uri: uriFor(1),
      image: image(10, 1),
    );
    await cache.write(
      accountId: 'account-a',
      uri: uriFor(2),
      image: image(10, 2),
    );
    final olderPreview = Directory('${root.path}/previews')
        .listSync(recursive: true)
        .whereType<File>()
        .singleWhere((file) => file.readAsBytesSync().last == 2);
    await olderPreview.setLastModified(epoch.add(const Duration(minutes: 2)));

    try {
      expect(
        await cache.read(accountId: 'account-a', uri: uriFor(1)),
        isNotNull,
      );
      expect(
        await cache.read(accountId: 'account-a', uri: uriFor(1)),
        isNotNull,
      );
      // If both updates may start together, let the newer stamp reach disk first.
      if (secondTouchStarted.isCompleted) await persisted[1].future;
    } finally {
      firstTouchGate.complete();
    }
    await Future.wait(persisted.map((touch) => touch.future));

    final restarted = open(maximumBytes: 20);
    expect(
      (await restarted.read(accountId: 'account-a', uri: uriFor(1)))?.body.last,
      1,
    );
    expect(
      await restarted.read(accountId: 'account-a', uri: uriFor(2)),
      isNull,
    );
  });

  test('a touch in flight cannot age a replacement preview', () async {
    final oldTouchGate = Completer<void>();
    final oldTouchCompleted = Completer<void>();
    final newTouchCompleted = Completer<void>();
    final newFilePublished = Completer<void>();
    final renameGate = Completer<void>();
    final epoch = DateTime.utc(2020);
    var stampCount = 0;
    final cache = open(
      touchFile: (file, _) async {
        if (stampCount++ == 0) {
          await oldTouchGate.future;
          await file.setLastModified(epoch.add(const Duration(minutes: 1)));
          oldTouchCompleted.complete();
        } else {
          await file.setLastModified(epoch.add(const Duration(minutes: 3)));
          newTouchCompleted.complete();
        }
      },
    );
    await cache.write(
      accountId: 'account-a',
      uri: uriFor(1),
      image: image(10, 1),
    );
    await cache.write(
      accountId: 'account-a',
      uri: uriFor(2),
      image: image(10, 2),
    );
    final olderPreview = storedPreviews().singleWhere(
      (file) => file.readAsBytesSync().last == 2,
    );
    await olderPreview.setLastModified(epoch.add(const Duration(minutes: 2)));
    expect(await cache.read(accountId: 'account-a', uri: uriFor(1)), isNotNull);

    final nativeFiles = _NativeFiles();
    final replacing = IOOverrides.runZoned(
      () => cache.write(
        accountId: 'account-a',
        uri: uriFor(1),
        image: image(15, 3),
      ),
      createFile: (path) {
        final file = nativeFiles.createFile(path);
        if (!path.endsWith('.part-2')) return file;
        return _PreviewIoFile(
          file,
          renameFile: (destination) async {
            final renamed = await file.rename(destination);
            newFilePublished.complete();
            await renameGate.future;
            return renamed;
          },
        );
      },
    );
    try {
      await newFilePublished.future.timeout(const Duration(seconds: 2));
      oldTouchGate.complete();
      await oldTouchCompleted.future;
      // The touch can finish while publish is still waiting for rename.
      await Future<void>.delayed(Duration.zero);
    } finally {
      renameGate.complete();
      if (!oldTouchGate.isCompleted) oldTouchGate.complete();
    }
    await replacing;
    if (stampCount > 1) await newTouchCompleted.future;

    final restarted = open(maximumBytes: 25);
    expect(
      (await restarted.read(accountId: 'account-a', uri: uriFor(1)))?.body.last,
      3,
    );
    expect(
      await restarted.read(accountId: 'account-a', uri: uriFor(2)),
      isNull,
    );
  });

  test('both concurrent hits survive a refresh of the same content', () async {
    final uri = uriFor(42);
    final cache = open();
    await cache.write(accountId: 'account-a', uri: uri, image: image(10));
    final stored = storedPreviews().single;
    final gates = [Completer<void>(), Completer<void>()];
    final bothStarted = Completer<void>();
    final nativeFiles = _NativeFiles();
    var started = 0;
    final reads = IOOverrides.runZoned(
      () => [
        cache.read(accountId: 'account-a', uri: uri),
        cache.read(accountId: 'account-a', uri: uri),
      ],
      createFile: (path) {
        final file = nativeFiles.createFile(path);
        if (p.normalize(path) != p.normalize(stored.path)) return file;
        return _PreviewIoFile(
          file,
          readBytes: () async {
            final gate = gates[started++];
            if (started == 2) bothStarted.complete();
            await gate.future;
            return file.readAsBytes();
          },
        );
      },
    );
    try {
      await bothStarted.future.timeout(const Duration(seconds: 2));
      gates[0].complete();
      expect(await Future.any(reads), isNotNull);
    } finally {
      for (final gate in gates) {
        if (!gate.isCompleted) gate.complete();
      }
    }

    final results = await Future.wait(reads);
    expect(results.map((hit) => hit?.body.length), [10, 10]);
    expect(cache.length, 1);
    expect(cache.byteLength, 20);
  });

  test('a failed replacement keeps the last complete preview', () async {
    final uri = uriFor(42);
    final cache = open();
    await cache.write(accountId: 'account-a', uri: uri, image: image(10, 1));
    final stored = Directory(
      '${root.path}/previews',
    ).listSync(recursive: true).whereType<File>().single;
    final original = await stored.readAsBytes();
    final nativeFiles = _NativeFiles();
    var renameAttempts = 0;
    await IOOverrides.runZoned(
      () => cache.write(accountId: 'account-a', uri: uri, image: image(14, 2)),
      createFile: (path) {
        final file = nativeFiles.createFile(path);
        if (!path.endsWith('.part-1')) return file;
        return _PreviewIoFile(
          file,
          renameFile: (_) async {
            renameAttempts++;
            throw const FileSystemException('interrupted preview publication');
          },
        );
      },
    );

    expect(renameAttempts, 1);
    expect(await stored.exists(), isTrue);
    expect(await stored.readAsBytes(), original);
    expect((await open().read(accountId: 'account-a', uri: uri))?.body.last, 1);
    expect(cache.byteLength, original.length);
    expect(stored.parent.listSync().whereType<File>().length, 1);
  });

  test('an in-flight read does not restore an evicted entry', () async {
    final uri = uriFor(42);
    final cache = open();
    await cache.write(accountId: 'account-a', uri: uri, image: image(10));
    final stored = Directory(
      '${root.path}/previews',
    ).listSync(recursive: true).whereType<File>().single;
    final readStarted = Completer<void>();
    final readGate = Completer<void>();
    final nativeFiles = _NativeFiles();
    final reading = IOOverrides.runZoned(
      () => cache.read(accountId: 'account-a', uri: uri),
      createFile: (path) {
        final file = nativeFiles.createFile(path);
        if (p.normalize(path) != p.normalize(stored.path)) return file;
        return _PreviewIoFile(
          file,
          readBytes: () async {
            final snapshot = await file.readAsBytes();
            readStarted.complete();
            await readGate.future;
            return snapshot;
          },
        );
      },
    );
    try {
      await readStarted.future;
      await cache.evict(accountId: 'account-a', uri: uri);
    } finally {
      readGate.complete();
    }

    expect(await reading, isNull);
    expect(cache.length, 0);
    expect(cache.byteLength, 0);
    expect(await cache.read(accountId: 'account-a', uri: uri), isNull);
    expect(cache.byteLength, 0);
  });

  test('accounts never read each other cached bytes', () async {
    final uri = uriFor(42);
    final cache = open();
    await cache.write(accountId: 'account-a', uri: uri, image: image(32));

    expect(await cache.read(accountId: 'account-b', uri: uri), isNull);
    expect(await cache.read(accountId: 'account-a', uri: uri), isNotNull);
  });

  test('nothing on disk names the account or the preview target', () async {
    await open().write(
      accountId: 'account-a',
      uri: uriFor(42),
      image: image(16),
    );

    final previews = Directory('${root.path}/previews');
    final stored = previews.listSync(recursive: true).whereType<File>().single;
    final components = p
        .split(p.relative(stored.path, from: previews.path))
        .toList(growable: false);

    // Two hashed components: the account directory and the preview file. A
    // digest cannot carry the room token or the remote file name.
    expect(components, hasLength(2));
    for (final component in components) {
      expect(
        RegExp(r'^[0-9a-f]{64}$').hasMatch(component),
        isTrue,
        reason: 'expected a SHA-256 digest, got $component',
      );
    }
  });

  test('the byte bound evicts the least recently read entry', () async {
    final cache = open(maximumBytes: 300);
    await cache.write(
      accountId: 'account-a',
      uri: uriFor(1),
      image: image(100),
    );
    await cache.write(
      accountId: 'account-a',
      uri: uriFor(2),
      image: image(100),
    );

    // Reading 1 makes 2 the least recently used one. The stamps are written
    // with a real clock, so they need to be distinguishable.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(await cache.read(accountId: 'account-a', uri: uriFor(1)), isNotNull);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    await cache.write(
      accountId: 'account-a',
      uri: uriFor(3),
      image: image(100),
    );

    expect(cache.byteLength, lessThanOrEqualTo(300));
    expect(await cache.read(accountId: 'account-a', uri: uriFor(2)), isNull);
    expect(await cache.read(accountId: 'account-a', uri: uriFor(1)), isNotNull);
    expect(await cache.read(accountId: 'account-a', uri: uriFor(3)), isNotNull);
  });

  test('an entry larger than the whole bound is skipped', () async {
    final cache = open(maximumBytes: 100);
    await cache.write(
      accountId: 'account-a',
      uri: uriFor(1),
      image: image(500),
    );

    expect(await cache.read(accountId: 'account-a', uri: uriFor(1)), isNull);
    expect(cache.byteLength, 0);
  });

  test(
    'a shrunken bound is enforced while scanning an existing store',
    () async {
      final seed = open();
      for (var fileId = 1; fileId <= 4; fileId++) {
        await seed.write(
          accountId: 'account-a',
          uri: uriFor(fileId),
          image: image(100),
        );
      }
      expect(seed.length, 4);

      final restarted = open(maximumBytes: 250);
      // Any read forces the scan that applies the new bound.
      await restarted.read(accountId: 'account-a', uri: uriFor(1));

      expect(restarted.byteLength, lessThanOrEqualTo(250));
      expect(restarted.length, 2);
      expect(
        Directory(
          '${root.path}/previews',
        ).listSync(recursive: true).whereType<File>().length,
        2,
      );
    },
  );

  test('a cold scan stats files with bounded concurrency', () async {
    const fileCount = 12;
    final previews = Directory('${root.path}/previews');
    await previews.create(recursive: true);
    for (var index = 0; index < fileCount; index++) {
      await File(
        p.join(previews.path, 'entry-$index'),
      ).writeAsBytes(<int>[index]);
    }

    final gates = <Completer<void>>[];
    final firstStatStarted = Completer<void>();
    var inFlight = 0;
    var peakInFlight = 0;
    final cache = open(
      statFile: (file) async {
        final stat = file.statSync();
        final gate = Completer<void>();
        gates.add(gate);
        if (!firstStatStarted.isCompleted) {
          firstStatStarted.complete();
        }
        inFlight++;
        if (inFlight > peakInFlight) {
          peakInFlight = inFlight;
        }
        await gate.future;
        inFlight--;
        return stat;
      },
    );
    final opening = cache.read(accountId: 'account-a', uri: uriFor(99));

    Future<void> releaseAll() async {
      while (gates.length < fileCount) {
        for (final gate in gates) {
          if (!gate.isCompleted) {
            gate.complete();
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      for (final gate in gates) {
        if (!gate.isCompleted) {
          gate.complete();
        }
      }
      await opening;
    }

    addTearDown(releaseAll);
    await firstStatStarted.future;
    for (var turn = 0; turn < 20 && gates.length < 8; turn++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    expect(gates, hasLength(8));
    expect(peakInFlight, 8);

    gates.first.complete();
    for (var turn = 0; turn < 20 && gates.length < 9; turn++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(gates, hasLength(9));
    expect(peakInFlight, 8);

    await releaseAll();
    expect(cache.length, fileCount);
  });

  test('a preview removed during the cold scan does not count', () async {
    final uri = uriFor(42);
    await open().write(accountId: 'account-a', uri: uri, image: image(10));
    var statCount = 0;
    final restarted = open(
      statFile: (file) async {
        statCount++;
        await file.delete();
        return file.stat();
      },
    );

    // Trigger the scan through an unrelated lookup.
    expect(
      await restarted.read(accountId: 'account-a', uri: uriFor(99)),
      isNull,
    );
    expect(statCount, 1);
    expect(restarted.length, 0);
    expect(restarted.byteLength, 0);
  });

  test('pruning deletes files with bounded concurrency', () async {
    const fileCount = 6;
    final seed = open();
    for (var fileId = 1; fileId <= fileCount; fileId++) {
      await seed.write(
        accountId: 'account-a',
        uri: uriFor(fileId),
        image: image(10),
      );
    }
    final gates = <Completer<void>>[];
    var inFlight = 0;
    var peakInFlight = 0;
    final cache = open(
      maximumBytes: 0,
      deleteFile: (file) async {
        final gate = Completer<void>();
        gates.add(gate);
        inFlight++;
        if (inFlight > peakInFlight) {
          peakInFlight = inFlight;
        }
        await gate.future;
        inFlight--;
        await file.delete();
      },
    );
    final pruning = cache.read(accountId: 'account-a', uri: uriFor(99));

    Future<void> releaseAll() async {
      for (var turn = 0; turn < 100 && gates.length < fileCount; turn++) {
        for (final gate in gates) {
          if (!gate.isCompleted) {
            gate.complete();
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      for (final gate in gates) {
        if (!gate.isCompleted) {
          gate.complete();
        }
      }
      await pruning;
    }

    addTearDown(releaseAll);
    for (var turn = 0; turn < 50 && gates.length < 4; turn++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(gates, hasLength(4));
    expect(peakInFlight, 4);

    gates.first.complete();
    for (var turn = 0; turn < 50 && gates.length < 5; turn++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(gates, hasLength(5));
    expect(peakInFlight, 4);

    await releaseAll();
    expect(gates, hasLength(fileCount));
    expect(cache.length, 0);
    expect(cache.byteLength, 0);
  });

  test('account eviction stops an in-flight stale prune plan', () async {
    const storedBytes = 20;
    final seed = open();
    for (var fileId = 1; fileId <= 6; fileId++) {
      await seed.write(
        accountId: 'account-a',
        uri: uriFor(fileId),
        image: image(10),
      );
    }
    final previews = Directory('${root.path}/previews');
    final accountADirectory = previews.listSync().whereType<Directory>().single;
    for (var fileId = 7; fileId <= 8; fileId++) {
      await seed.write(
        accountId: 'account-b',
        uri: uriFor(fileId),
        image: image(10),
      );
    }

    final oldest = DateTime.utc(2020);
    final accountAFiles = accountADirectory.listSync().whereType<File>().toList(
      growable: false,
    );
    for (final file in accountAFiles) {
      await file.setLastModified(oldest);
    }
    final accountBDirectory = previews
        .listSync()
        .whereType<Directory>()
        .singleWhere((directory) => directory.path != accountADirectory.path);
    for (final file in accountBDirectory.listSync().whereType<File>()) {
      await file.setLastModified(DateTime.utc(2021));
    }

    final firstBatchGate = Completer<void>();
    final firstBatchStarted = Completer<void>();
    final deleteAttempts = <String>[];
    var inFlight = 0;
    var peakInFlight = 0;
    final cache = open(
      maximumBytes: storedBytes * 2,
      deleteFile: (file) async {
        deleteAttempts.add(file.path);
        inFlight++;
        if (inFlight > peakInFlight) peakInFlight = inFlight;
        if (deleteAttempts.length == 4) firstBatchStarted.complete();
        if (deleteAttempts.length <= 4) await firstBatchGate.future;
        inFlight--;
        await file.delete();
      },
    );
    final pruning = cache.read(accountId: 'account-a', uri: uriFor(99));
    addTearDown(() async {
      if (!firstBatchGate.isCompleted) firstBatchGate.complete();
      await pruning;
    });

    await firstBatchStarted.future.timeout(const Duration(seconds: 2));
    expect(deleteAttempts, hasLength(4));
    expect(peakInFlight, 4);
    expect(
      deleteAttempts.every((path) => p.isWithin(accountADirectory.path, path)),
      isTrue,
    );

    await cache.evictAccount('account-b');
    expect(cache.byteLength, storedBytes * 2);
    firstBatchGate.complete();
    await pruning;

    expect(deleteAttempts, hasLength(4));
    expect(cache.length, 2);
    expect(cache.byteLength, storedBytes * 2);
    final survivors = <ChatMediaImage>[];
    for (var fileId = 1; fileId <= 6; fileId++) {
      final survivor = await cache.read(
        accountId: 'account-a',
        uri: uriFor(fileId),
      );
      if (survivor != null) survivors.add(survivor);
    }
    expect(survivors, hasLength(2));
  });

  test(
    'pruning replaces a refreshed candidate and still reaches its bound',
    () async {
      const storedBytes = 20;
      final seed = open();
      for (var fileId = 1; fileId <= 7; fileId++) {
        await seed.write(
          accountId: 'account-a',
          uri: uriFor(fileId),
          image: image(10, fileId),
        );
      }
      final files = Directory(
        '${root.path}/previews',
      ).listSync(recursive: true).whereType<File>();
      final oldest = DateTime.utc(2020);
      for (final file in files) {
        await file.setLastModified(
          oldest.add(Duration(minutes: file.readAsBytesSync().last)),
        );
      }

      final firstBatchGate = Completer<void>();
      final firstBatchStarted = Completer<void>();
      final deletedFileIds = <int>[];
      var inFlight = 0;
      var peakInFlight = 0;
      final cache = open(
        maximumBytes: storedBytes * 2,
        deleteFile: (file) async {
          deletedFileIds.add(file.readAsBytesSync().last);
          inFlight++;
          if (inFlight > peakInFlight) peakInFlight = inFlight;
          if (deletedFileIds.length == 4) firstBatchStarted.complete();
          if (deletedFileIds.length <= 4) await firstBatchGate.future;
          inFlight--;
          await file.delete();
        },
      );
      final pruning = cache.read(accountId: 'account-a', uri: uriFor(99));
      addTearDown(() async {
        if (!firstBatchGate.isCompleted) firstBatchGate.complete();
        await pruning;
      });

      await firstBatchStarted.future.timeout(const Duration(seconds: 2));
      expect(deletedFileIds, unorderedEquals(<int>[1, 2, 3, 4]));
      expect(peakInFlight, 4);

      expect(
        await cache.read(accountId: 'account-a', uri: uriFor(5)),
        isNotNull,
      );
      firstBatchGate.complete();
      await pruning;

      expect(deletedFileIds, unorderedEquals(<int>[1, 2, 3, 4, 6]));
      expect(cache.length, 2);
      expect(cache.byteLength, storedBytes * 2);
      expect(
        await cache.read(accountId: 'account-a', uri: uriFor(5)),
        isNotNull,
      );
      expect(
        await cache.read(accountId: 'account-a', uri: uriFor(7)),
        isNotNull,
      );
    },
  );

  test('evicting an account erases its bytes from disk only', () async {
    final cache = open();
    await cache.write(accountId: 'account-a', uri: uriFor(1), image: image(50));
    await cache.write(accountId: 'account-b', uri: uriFor(1), image: image(70));

    await cache.evictAccount('account-a');

    expect(await cache.read(accountId: 'account-a', uri: uriFor(1)), isNull);
    expect(await cache.read(accountId: 'account-b', uri: uriFor(1)), isNotNull);
    expect(
      Directory(
        '${root.path}/previews',
      ).listSync(recursive: true).whereType<File>().length,
      1,
    );

    // The erased account is usable again afterwards.
    await cache.write(accountId: 'account-a', uri: uriFor(1), image: image(50));
    expect(await cache.read(accountId: 'account-a', uri: uriFor(1)), isNotNull);
  });

  test('a truncated file is dropped instead of surfacing garbage', () async {
    final cache = open();
    await cache.write(accountId: 'account-a', uri: uriFor(1), image: image(50));
    final stored = Directory(
      '${root.path}/previews',
    ).listSync(recursive: true).whereType<File>().single;
    await stored.writeAsBytes(Uint8List.fromList(<int>[0x41, 0x42]));

    expect(await cache.read(accountId: 'account-a', uri: uriFor(1)), isNull);
    expect(stored.existsSync(), isFalse);
    expect(cache.byteLength, 0);
  });

  test('a store that cannot be opened degrades to a miss', () async {
    final cache = ChatMediaDiskCache(
      rootDirectory: () async =>
          throw const FileSystemException('no cache directory'),
    );

    expect(await cache.read(accountId: 'account-a', uri: uriFor(1)), isNull);
    await cache.write(accountId: 'account-a', uri: uriFor(1), image: image(10));
    await cache.evictAccount('account-a');
    expect(cache.byteLength, 0);
  });
}

final class _NativeFiles extends IOOverrides {}

final class _PreviewIoFile implements File {
  _PreviewIoFile(this.file, {this.readBytes, this.renameFile});

  final File file;
  final Future<Uint8List> Function()? readBytes;
  final Future<File> Function(String newPath)? renameFile;

  @override
  Future<Uint8List> readAsBytes() => readBytes?.call() ?? file.readAsBytes();

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      file.open(mode: mode);

  @override
  Future<File> rename(String newPath) =>
      renameFile?.call(newPath) ?? file.rename(newPath);

  @override
  Future<bool> exists() => file.exists();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);

  @override
  Future<void> setLastModified(DateTime time) => file.setLastModified(time);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
