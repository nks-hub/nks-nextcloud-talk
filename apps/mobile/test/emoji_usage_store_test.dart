import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/emoji_usage_store.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nctalk-emoji-usage-test-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('keeps bounded unique recents newest first across restarts', () async {
    final account = AccountId.parse('account-a');
    final store = FileEmojiUsageStore(directory: root, recentLimit: 3);

    for (final emoji in <String>['😀', '🎉', '👍', '😀']) {
      await store.recordSelection(account, emoji);
    }

    final restarted = FileEmojiUsageStore(directory: root, recentLimit: 3);
    final usage = await restarted.read(account);
    expect(usage.recent, <String>['😀', '👍', '🎉']);
    expect(usage.favorites, isEmpty);
  });

  test('isolates accounts behind opaque SHA-256 file names', () async {
    final first = AccountId.parse('server-a:user-a');
    final second = AccountId.parse('server-b:user-b');
    final store = FileEmojiUsageStore(directory: root);

    await store.recordSelection(first, '😀');
    await store.recordSelection(second, '🎉');

    expect((await store.read(first)).recent, <String>['😀']);
    expect((await store.read(second)).recent, <String>['🎉']);
    final files = await _filesBelow(root);
    expect(files, hasLength(2));
    for (final file in files) {
      final name = file.uri.pathSegments.last;
      expect(name, matches(RegExp(r'^[0-9a-f]{64}\.json$')));
      expect(file.path, isNot(contains('server-a')));
      expect(file.path, isNot(contains('user-a')));
      expect(file.path, isNot(contains('server-b')));
      expect(file.path, isNot(contains('user-b')));
    }
  });

  test('toggles favorites without changing recent selections', () async {
    final account = AccountId.parse('account-a');
    final store = FileEmojiUsageStore(directory: root);
    await store.recordSelection(account, '😀');

    await store.toggleFavorite(account, '🎉');
    final favorited = await store.toggleFavorite(account, '👍');
    expect(favorited.favorites, <String>['👍', '🎉']);
    var usage = await store.read(account);
    expect(usage.recent, <String>['😀']);
    expect(usage.favorites, <String>['👍', '🎉']);

    await store.toggleFavorite(account, '🎉');
    usage = await store.read(account);
    expect(usage.favorites, <String>['👍']);
    expect(() => usage.recent.add('x'), throwsUnsupportedError);
    expect(() => usage.favorites.add('x'), throwsUnsupportedError);
  });

  test('recovers from corrupt state on the next mutation', () async {
    final account = AccountId.parse('account-a');
    final store = FileEmojiUsageStore(directory: root);
    await store.recordSelection(account, '😀');
    final file = (await _filesBelow(root)).single;
    await file.writeAsString('{not-json', flush: true);

    final restarted = FileEmojiUsageStore(directory: root);
    final damaged = await restarted.read(account);
    expect(damaged.recent, isEmpty);
    expect(damaged.favorites, isEmpty);

    final recovered = await restarted.recordSelection(account, '🎉');
    expect(recovered.recent, <String>['🎉']);
    expect((await restarted.read(account)).recent, <String>['🎉']);
  });

  test('delete removes only the selected account state', () async {
    final first = AccountId.parse('account-a');
    final second = AccountId.parse('account-b');
    final store = FileEmojiUsageStore(directory: root);
    await store.recordSelection(first, '😀');
    await store.toggleFavorite(first, '🎉');
    await store.recordSelection(second, '👍');

    await store.delete(first);

    expect((await store.read(first)).recent, isEmpty);
    expect((await store.read(first)).favorites, isEmpty);
    expect((await store.read(second)).recent, <String>['👍']);
    expect(await _filesBelow(root), hasLength(1));
  });

  test('serializes overlapping mutations without losing state', () async {
    final account = AccountId.parse('account-a');
    final store = FileEmojiUsageStore(directory: root);

    await Future.wait(<Future<void>>[
      store.recordSelection(account, '😀'),
      store.recordSelection(account, '🎉'),
      store.toggleFavorite(account, '👍'),
    ]);

    final usage = await store.read(account);
    expect(usage.recent, <String>['🎉', '😀']);
    expect(usage.favorites, <String>['👍']);
  });
}

Future<List<File>> _filesBelow(Directory directory) async {
  if (!await directory.exists()) {
    return <File>[];
  }
  return directory
      .list(recursive: true, followLinks: false)
      .where((entity) => entity is File)
      .cast<File>()
      .toList();
}
