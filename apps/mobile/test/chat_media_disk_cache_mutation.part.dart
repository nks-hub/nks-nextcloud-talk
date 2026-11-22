part of 'chat_media_disk_cache_test.dart';

void _previewMutationTests(
  ChatMediaDiskCache Function({
    int maximumBytes,
    Future<void> Function(File file)? deleteFile,
    Future<void> Function(File file, DateTime touchedAt)? touchFile,
  })
  open,
  ChatMediaImage Function(int, [int]) image,
  Uri Function(int) uriFor,
  Iterable<File> Function() storedPreviews,
) {
  const account = 'account-a';
  const deadline = Duration(seconds: 5);

  for (final (name, prune, failDelete) in [
    (
      'a replacement survives an already running preview deletion',
      false,
      false,
    ),
    (
      'a refilled preview survives an already running quota deletion',
      true,
      false,
    ),
    ('a replacement is published after a failed deletion', false, true),
  ]) {
    test(name, () async {
      final uri = uriFor(1);
      final other = uriFor(2);
      await open().write(accountId: account, uri: uri, image: image(24, 1));
      await storedPreviews().single.setLastModified(DateTime.utc(2020));
      final deleteStarted = Completer<void>();
      final deleteGate = Completer<void>();
      final cache = open(
        maximumBytes: 42,
        deleteFile: (file) async {
          deleteStarted.complete();
          await deleteGate.future;
          if (failDelete) throw const FileSystemException('deletion failed');
          await file.delete();
        },
      );
      final evicting = prune
          ? cache.write(accountId: account, uri: other, image: image(8, 3))
          : cache.evict(accountId: account, uri: uri);
      addTearDown(() async {
        if (!deleteGate.isCompleted) deleteGate.complete();
        await evicting;
      });
      await deleteStarted.future.timeout(deadline);

      final prepared = Completer<void>();
      var renameStarted = false;
      final replacing = _writeObservedPreview(
        cache,
        account: account,
        uri: uri,
        image: image(14, 2),
        afterClose: prepared.complete,
        rename: (file, destination) {
          renameStarted = true;
          return file.rename(destination);
        },
      );
      try {
        await prepared.future.timeout(deadline);
        if (renameStarted) {
          // Complete the early rename so the real delete reaches the new file.
          await replacing.timeout(deadline);
          expect(
            (await cache.read(accountId: account, uri: uri))?.body.last,
            2,
          );
        }
        if (!prune) {
          await cache
              .write(accountId: account, uri: other, image: image(8, 3))
              .timeout(deadline);
        }
        final otherHit = await cache
            .read(accountId: account, uri: other)
            .timeout(deadline);
        expect(otherHit?.body.last, 3);
      } finally {
        deleteGate.complete();
        await Future.wait([evicting, replacing]).timeout(deadline);
      }

      expect((await cache.read(accountId: account, uri: uri))?.body.last, 2);
      final restarted = open();
      expect(
        (await restarted.read(accountId: account, uri: uri))?.body.last,
        2,
      );
      expect(restarted.length, 2);
      expect(restarted.byteLength, 42);
    });
  }

  for (final failRename in [false, true]) {
    test(
      failRename
          ? 'a waiting eviction runs after a failed preview publication'
          : 'a waiting eviction removes the completed replacement',
      () async {
        final uri = uriFor(1);
        int? deletedByte;
        final cache = open(
          deleteFile: (file) async {
            deletedByte = (await file.readAsBytes()).last;
            await file.delete();
          },
        );
        await cache.write(accountId: account, uri: uri, image: image(10, 1));
        final renameStarted = Completer<void>();
        final renameGate = Completer<void>();
        final replacing = _writeObservedPreview(
          cache,
          account: account,
          uri: uri,
          image: image(14, 2),
          rename: (file, destination) async {
            renameStarted.complete();
            await renameGate.future;
            if (failRename) throw const FileSystemException('rename failed');
            return file.rename(destination);
          },
        );
        Future<void>? evicting;
        try {
          await renameStarted.future.timeout(deadline);
          evicting = cache.evict(accountId: account, uri: uri);
          final hit = await cache
              .read(accountId: account, uri: uri)
              .timeout(deadline);
          expect(hit?.body.last, 1);
        } finally {
          renameGate.complete();
          await replacing.timeout(deadline);
          await evicting?.timeout(deadline);
        }

        expect(deletedByte, failRename ? 1 : 2);
        expect(cache.length, 0);
        expect(cache.byteLength, 0);
        expect(storedPreviews(), isEmpty);
      },
    );
  }

  test('a corrupt read cannot discard the replacement it waited for', () async {
    final uri = uriFor(1);
    final cache = open();
    await cache.write(accountId: account, uri: uri, image: image(10, 1));
    final corrupt = storedPreviews().single;
    await corrupt.writeAsBytes([0x41, 0x42]);

    final renameStarted = Completer<void>();
    final renameGate = Completer<void>();
    final replacing = _writeObservedPreview(
      cache,
      account: account,
      uri: uri,
      image: image(14, 2),
      rename: (file, destination) async {
        renameStarted.complete();
        await renameGate.future;
        return file.rename(destination);
      },
    );
    final corruptRead = Completer<void>();
    final nativeFiles = _NativeFiles();
    late final Future<ChatMediaImage?> reading;
    try {
      await renameStarted.future.timeout(deadline);
      reading = IOOverrides.runZoned(
        () => cache.read(accountId: account, uri: uri),
        createFile: (path) {
          final file = nativeFiles.createFile(path);
          if (p.normalize(path) != p.normalize(corrupt.path)) return file;
          return _PreviewIoFile(
            file,
            readBytes: () async {
              final stored = await file.readAsBytes();
              Timer.run(corruptRead.complete);
              return stored;
            },
          );
        },
      );
      await corruptRead.future.timeout(deadline);
    } finally {
      renameGate.complete();
      await replacing.timeout(deadline);
    }

    expect(await reading.timeout(deadline), isNull);
    expect((await open().read(accountId: account, uri: uri))?.body.last, 2);
    expect(cache.length, 1);
    expect(cache.byteLength, 24);
  });

  test('account purge waits for a write before its directory exists', () async {
    final cache = open();
    final first = uriFor(1);
    final second = uriFor(2);
    const otherAccount = 'account-b';
    await cache.write(
      accountId: otherAccount,
      uri: second,
      image: image(10, 2),
    );
    final createStarted = Completer<void>();
    final createGate = Completer<void>();
    final nativeFiles = _NativeFiles();
    final writing = IOOverrides.runZoned(
      () => cache.write(accountId: account, uri: first, image: image(10, 1)),
      createDirectory: (path) {
        final directory = nativeFiles.createDirectory(path);
        if (createStarted.isCompleted) return directory;
        return _ObservedPreviewDirectory(
          directory,
          beforeCreate: () {
            createStarted.complete();
            return createGate.future;
          },
        );
      },
    );
    Future<void>? removing;
    try {
      await createStarted.future.timeout(deadline);
      var deleteStarted = false;
      final purge = IOOverrides.runZoned(
        () => cache.evictAccount(account),
        createDirectory: (path) => _ObservedPreviewDirectory(
          nativeFiles.createDirectory(path),
          beforeDelete: () => deleteStarted = true,
        ),
      );
      removing = purge;
      // The cache is warm. An unguarded purge starts deleting after the open
      // microtask. In that case finish deleting before releasing the write.
      await Future<void>.delayed(Duration.zero);
      if (deleteStarted) await purge.timeout(deadline);
    } finally {
      createGate.complete();
      await writing.timeout(deadline);
      await removing?.timeout(deadline);
    }

    expect(cache.length, 1);
    expect(cache.byteLength, 20);
    final remaining = storedPreviews().single;
    expect((await remaining.readAsBytes()).last, 2);
    final reopened = open();
    expect(await reopened.read(accountId: account, uri: first), isNull);
    final other = await reopened.read(accountId: otherAccount, uri: second);
    expect(other?.body.last, 2);
  });

  test('account purge can finish while unrelated pruning waits', () async {
    const otherAccount = 'account-b';
    final seed = open();
    final oldest = uriFor(1);
    final kept = uriFor(2);
    final removed = uriFor(3);
    await seed.write(accountId: otherAccount, uri: oldest, image: image(10, 1));
    final oldestFile = storedPreviews().single;
    await oldestFile.setLastModified(DateTime.utc(2020));
    await seed.write(accountId: otherAccount, uri: kept, image: image(10, 2));

    final deleteStarted = Completer<String>();
    final deleteGate = Completer<void>();
    final cache = open(
      maximumBytes: 40,
      deleteFile: (file) async {
        deleteStarted.complete(p.normalize(file.path));
        await deleteGate.future;
        await file.delete();
      },
    );
    final writing = cache.write(
      accountId: account,
      uri: removed,
      image: image(10, 3),
    );
    try {
      expect(
        await deleteStarted.future.timeout(deadline),
        p.normalize(oldestFile.path),
      );
      await cache.evictAccount(account).timeout(deadline);
      expect(cache.length, 1);
      expect(await cache.read(accountId: account, uri: removed), isNull);
      final other = await cache.read(accountId: otherAccount, uri: kept);
      expect(other?.body.last, 2);
    } finally {
      deleteGate.complete();
      await writing.timeout(deadline);
    }
  });

  for (final writesFirst in [false, true]) {
    test(
      writesFirst
          ? 'a cold write can publish while unrelated pruning waits'
          : 'a cold account purge can finish while unrelated pruning waits',
      () async {
        const otherAccount = 'account-b';
        final oldest = uriFor(1);
        final kept = uriFor(2);
        final removed = uriFor(3);
        final seed = open();
        await seed.write(
          accountId: otherAccount,
          uri: oldest,
          image: image(20, 1),
        );
        final oldestFile = storedPreviews().single;
        await oldestFile.setLastModified(DateTime.utc(2020));
        await seed.write(
          accountId: otherAccount,
          uri: kept,
          image: image(10, 2),
        );
        if (!writesFirst) {
          await seed.write(
            accountId: account,
            uri: removed,
            image: image(10, 3),
          );
        }

        final deleteStarted = Completer<String>();
        final deleteGate = Completer<void>();
        final cache = open(
          maximumBytes: 40,
          deleteFile: (file) async {
            deleteStarted.complete(p.normalize(file.path));
            await deleteGate.future;
            await file.delete();
          },
        );
        final operation = writesFirst
            ? cache.write(accountId: account, uri: removed, image: image(10, 3))
            : cache.evictAccount(account);
        var coldReadFinished = false;
        final coldRead = cache.read(accountId: otherAccount, uri: kept).then((
          image,
        ) {
          coldReadFinished = true;
          return image;
        });

        try {
          expect(
            await deleteStarted.future.timeout(deadline),
            p.normalize(oldestFile.path),
          );
          await operation.timeout(deadline);
          if (writesFirst) {
            final published = await cache.read(
              accountId: account,
              uri: removed,
            );
            expect(published?.body.last, 3);
            await cache.evictAccount(account).timeout(deadline);
          }
          expect(coldReadFinished, isFalse);
          expect(await cache.read(accountId: account, uri: removed), isNull);
          expect(cache.length, 1);
        } finally {
          deleteGate.complete();
          await Future.wait([operation, coldRead]).timeout(deadline);
        }

        expect((await coldRead)?.body.last, 2);
        expect(storedPreviews(), hasLength(1));
        expect(cache.byteLength, 20);
      },
    );
  }

  for (final enoughSpace in [true, false]) {
    test(
      enoughSpace
          ? 'a write prunes an idle path while four older renames wait'
          : 'a write falls back when idle older files cannot cover the excess',
      () async {
        const otherAccount = 'account-b';
        const incomingAccount = 'account-c';
        const replacementCount = 4;
        const previewBytes = 20;
        final uris = List.generate(6, (index) => uriFor(index + 1));
        final seed = open();
        for (var index = 0; index < replacementCount; index++) {
          final size = !enoughSpace && index == 0 ? 30 : 10;
          await seed.write(
            accountId: account,
            uri: uris[index],
            image: image(size, 10 + index),
          );
        }
        await seed.write(
          accountId: otherAccount,
          uri: uris[4],
          image: image(enoughSpace ? 10 : 4, 14),
        );
        final budget = seed.byteLength;
        final originals = {
          for (final file in storedPreviews())
            file.readAsBytesSync().last: file,
        };
        for (var index = 0; index < 5; index++) {
          await originals[10 + index]!.setLastModified(
            DateTime.utc(2020, 1, 1, 0, index),
          );
        }
        final eligible = originals[14]!;
        final deleteStarted = Completer<void>();
        final releaseDelete = Completer<void>();
        final deleted = <String>[];
        final cache = open(
          maximumBytes: budget,
          touchFile: (_, _) async {},
          deleteFile: (file) async {
            deleted.add(p.normalize(file.path));
            if (!deleteStarted.isCompleted) deleteStarted.complete();
            await releaseDelete.future;
            await file.delete();
          },
        );
        await cache.read(accountId: account, uri: uriFor(99));

        final entered = List.generate(
          replacementCount,
          (_) => Completer<void>(),
        );
        final release = List.generate(
          replacementCount,
          (_) => Completer<void>(),
        );
        final replacements = [
          for (var index = 0; index < replacementCount; index++)
            _writeObservedPreview(
              cache,
              account: account,
              uri: uris[index],
              image: image(10, 20 + index),
              rename: (file, destination) async {
                entered[index].complete();
                await release[index].future;
                return file.rename(destination);
              },
            ),
        ];
        Future<void>? writing;
        try {
          await Future.wait(
            entered.map((event) => event.future),
          ).timeout(deadline);
          final staged = Completer<void>();
          var finished = false;
          final incoming = _writeObservedPreview(
            cache,
            account: incomingAccount,
            uri: uris[5],
            image: image(10, 30),
            rename: (file, destination) => file.rename(destination),
            afterCleanup: staged.complete,
          ).then<void>((_) => finished = true);
          writing = incoming;
          await staged.future.timeout(deadline);

          if (enoughSpace) {
            await deleteStarted.future.timeout(deadline);
            expect(deleted, [p.normalize(eligible.path)]);
            expect(eligible.existsSync(), isTrue);
            expect(finished, isFalse);
            releaseDelete.complete();
            await incoming.timeout(deadline);
            expect(cache.byteLength, budget);
            expect(eligible.existsSync(), isFalse);
          } else {
            expect(deleted, isEmpty);
            expect(cache.byteLength, budget + previewBytes);
            expect(finished, isFalse);
            // The first replacement shrinks enough to make deletion unnecessary.
            release.first.complete();
            await replacements.first.timeout(deadline);
          }
        } finally {
          if (!releaseDelete.isCompleted) releaseDelete.complete();
          for (final gate in release) {
            if (!gate.isCompleted) gate.complete();
          }
          await Future.wait([...replacements, ?writing]).timeout(deadline);
        }

        final reopened = open(maximumBytes: budget, touchFile: (_, _) async {});
        for (var index = 0; index < replacementCount; index++) {
          final replacement = await reopened.read(
            accountId: account,
            uri: uris[index],
          );
          expect(replacement?.body.last, 20 + index);
        }
        final incoming = await reopened.read(
          accountId: incomingAccount,
          uri: uris[5],
        );
        final remaining = await reopened.read(
          accountId: otherAccount,
          uri: uris[4],
        );
        expect(incoming?.body.last, 30);
        expect(remaining?.body.last, enoughSpace ? null : 14);
        expect(deleted, enoughSpace ? [p.normalize(eligible.path)] : isEmpty);
        expect(cache.byteLength, budget);
        expect(reopened.byteLength, budget);
        expect(storedPreviews(), hasLength(enoughSpace ? 5 : 6));
      },
    );
  }
}

Future<void> _writeObservedPreview(
  ChatMediaDiskCache cache, {
  required String account,
  required Uri uri,
  required ChatMediaImage image,
  required Future<File> Function(File file, String destination) rename,
  void Function()? afterClose,
  void Function()? afterCleanup,
}) {
  final nativeFiles = _NativeFiles();
  return IOOverrides.runZoned(
    () => cache.write(accountId: account, uri: uri, image: image),
    createFile: (path) {
      final file = nativeFiles.createFile(path);
      if (!p.basename(path).contains('.part-')) return file;
      return _PreviewIoFile(
        file,
        openFile: afterClose == null
            ? null
            : (mode) async =>
                  _PreviewOutput(await file.open(mode: mode), afterClose),
        renameFile: (destination) => rename(file, destination),
        fileExists: afterCleanup == null
            ? null
            : () async {
                final exists = await file.exists();
                // Let the writer resume into pruning before observing it.
                if (!exists) Timer.run(afterCleanup);
                return exists;
              },
      );
    },
  );
}

final class _PreviewOutput implements RandomAccessFile {
  _PreviewOutput(this.output, this.afterClose);

  final RandomAccessFile output;
  final void Function() afterClose;

  @override
  Future<void> close() async {
    await output.close();
    // Let the write resume from close before looking for a dispatched rename.
    Timer.run(afterClose);
  }

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) => output.writeFrom(buffer, start, end);

  @override
  Future<RandomAccessFile> writeByte(int value) => output.writeByte(value);

  @override
  Future<RandomAccessFile> flush() => output.flush();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ObservedPreviewDirectory implements Directory {
  _ObservedPreviewDirectory(
    this.directory, {
    this.beforeCreate,
    this.beforeDelete,
  });

  final Directory directory;
  final Future<void> Function()? beforeCreate;
  final void Function()? beforeDelete;

  @override
  String get path => directory.path;

  @override
  Future<Directory> create({bool recursive = false}) async {
    await beforeCreate?.call();
    return directory.create(recursive: recursive);
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) {
    beforeDelete?.call();
    return directory.delete(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
