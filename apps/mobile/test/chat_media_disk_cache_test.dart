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

  ChatMediaDiskCache open({int maximumBytes = 64 * 1024 * 1024}) {
    return ChatMediaDiskCache(
      rootDirectory: () async => Directory('${root.path}/previews'),
      maximumBytes: maximumBytes,
    );
  }

  ChatMediaImage image(int bytes, [int fill = 7]) => ChatMediaImage(
    body: Uint8List(bytes)..fillRange(0, bytes, fill),
    contentType: 'image/png',
  );

  Uri uriFor(int fileId) => Uri.parse(
    'https://cloud.example.invalid/index.php/core/preview'
    '?fileId=$fileId&x=2048&y=2048&a=0',
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
    expect(restarted.length, 1);
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
