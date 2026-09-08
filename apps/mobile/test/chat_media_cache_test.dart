import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/chat_media_cache.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';

void main() {
  test(
    'entry operations serialize after errors without blocking another key',
    () async {
      final cache = ChatMediaCache();
      final held = Completer<void>();
      final events = <String>[];
      final first = cache.withEntry('first', () async {
        events.add('load');
        await held.future;
        throw StateError('failed load');
      });
      final failure = expectLater(first, throwsStateError);
      final retry = cache.withEntry('first', () async => events.add('evict'));
      await cache.withEntry('second', () async => events.add('independent'));
      expect(events, ['load', 'independent']);
      held.complete();
      await failure;
      await retry;
      expect(events, ['load', 'independent', 'evict']);
      await cache.withEntry('first', () async => events.add('next'));
      expect(events.last, 'next');
    },
  );

  ChatMediaImage image(int bytes) =>
      ChatMediaImage(body: Uint8List(bytes), contentType: 'image/png');

  test('evicting one preview preserves other accounts and etag versions', () {
    final cache = ChatMediaCache();
    final uri = Uri.parse(
      'https://cloud.example.invalid/index.php/core/preview?fileId=42&c=v1',
    );
    final first = ChatMediaCache.keyOf(accountId: 'account-a', uri: uri);
    final otherAccount = ChatMediaCache.keyOf(accountId: 'account-b', uri: uri);
    final otherVersion = ChatMediaCache.keyOf(
      accountId: 'account-a',
      uri: uri.replace(queryParameters: {'fileId': '42', 'c': 'v2'}),
    );
    cache.write(first, image(10));
    cache.write(otherAccount, image(20));
    cache.write(otherVersion, image(30));
    cache.evict(first);
    cache.evict(first);
    expect(cache.read(first), isNull);
    expect(cache.read(otherAccount), isNotNull);
    expect(cache.read(otherVersion), isNotNull);
    expect(cache.length, 2);
    expect(cache.byteLength, 50);
  });

  test('a stored preview is served again without a refetch', () {
    final cache = ChatMediaCache();
    final key = ChatMediaCache.keyOf(
      accountId: 'account-a',
      uri: Uri.parse('https://cloud.example.invalid/index.php/core/preview'),
    );

    expect(cache.read(key), isNull);
    cache.write(key, image(10));
    expect(cache.read(key), isNotNull);
    expect(cache.byteLength, 10);
  });

  test('accounts never read each other cached bytes', () {
    final cache = ChatMediaCache();
    final uri = Uri.parse(
      'https://cloud.example.invalid/index.php/core/preview',
    );
    cache.write(
      ChatMediaCache.keyOf(accountId: 'account-a', uri: uri),
      image(10),
    );

    expect(
      cache.read(ChatMediaCache.keyOf(accountId: 'account-b', uri: uri)),
      isNull,
    );
  });

  test('the least recently used entry is evicted past the count bound', () {
    final cache = ChatMediaCache(maximumEntries: 2);
    cache.write('a', image(1));
    cache.write('b', image(1));
    // Touching 'a' makes 'b' the least recently used one.
    expect(cache.read('a'), isNotNull);
    cache.write('c', image(1));

    expect(cache.read('b'), isNull);
    expect(cache.read('a'), isNotNull);
    expect(cache.read('c'), isNotNull);
    expect(cache.length, 2);
  });

  test('the byte bound is respected and never goes negative', () {
    final cache = ChatMediaCache(maximumEntries: 10, maximumBytes: 100);
    cache.write('a', image(60));
    cache.write('b', image(60));

    expect(cache.length, 1);
    expect(cache.byteLength, 60);

    cache.write('huge', image(1000));
    expect(cache.read('huge'), isNull, reason: 'an oversized entry is skipped');
    expect(cache.byteLength, 60);
  });

  test('removing an account drops only its bytes', () {
    final cache = ChatMediaCache();
    final uri = Uri.parse(
      'https://cloud.example.invalid/index.php/core/preview',
    );
    cache
      ..write(ChatMediaCache.keyOf(accountId: 'account-a', uri: uri), image(10))
      ..write(ChatMediaCache.keyOf(accountId: 'account-b', uri: uri), image(20))
      ..evictAccount('account-a');

    expect(
      cache.read(ChatMediaCache.keyOf(accountId: 'account-a', uri: uri)),
      isNull,
    );
    expect(
      cache.read(ChatMediaCache.keyOf(accountId: 'account-b', uri: uri)),
      isNotNull,
    );
    expect(cache.byteLength, 20);
  });
}
