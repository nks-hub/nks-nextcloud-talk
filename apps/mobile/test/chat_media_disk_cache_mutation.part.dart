part of 'chat_media_disk_cache_test.dart';

void _previewMutationTests(
  ChatMediaDiskCache Function({
    int maximumBytes,
    Future<void> Function(File file)? deleteFile,
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
}

Future<void> _writeObservedPreview(
  ChatMediaDiskCache cache, {
  required String account,
  required Uri uri,
  required ChatMediaImage image,
  required Future<File> Function(File file, String destination) rename,
  void Function()? afterClose,
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
