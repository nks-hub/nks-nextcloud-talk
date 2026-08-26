import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/chat_media_cache.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';

import 'test_support.dart';

/// Voice files are the only chat cache without a size bound: one file per
/// voice message ever played, kept until the account is removed. They are pure
/// cache, so dropping the oldest costs a refetch and nothing else.
void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('voice-cache-');
  });

  tearDown(() => directory.delete(recursive: true));

  /// Writes [count] files of [bytes] each, oldest first, and returns their
  /// names in that order.
  Future<List<String>> seed({
    required String accountId,
    required int count,
    required int bytes,
  }) async {
    final names = <String>[];
    for (var index = 0; index < count; index++) {
      final name = chatVoiceCacheKey(accountId: accountId, messageId: index);
      final file = File('${directory.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(Uint8List(bytes), flush: true);
      // Explicit stamps, so recency is the test's choice rather than the
      // file system's clock resolution.
      await file.setLastModified(
        DateTime(2026, 1, 1).add(Duration(minutes: index)),
      );
      names.add(name);
    }
    return names;
  }

  int directoryBytes() => directory.listSync().whereType<File>().fold(
    0,
    (total, file) => total + file.lengthSync(),
  );

  test('prunes to the bound and keeps the most recently written files', () async {
    const bytes = 1024 * 1024;
    final names = await seed(accountId: 'account-a', count: 20, bytes: bytes);
    final before = directoryBytes();
    expect(before, 20 * bytes);

    await pruneAccountVoiceFiles(
      directory: directory,
      accountId: 'account-a',
      maximumBytes: 12 * bytes,
    );

    final after = directoryBytes();
    // ignore: avoid_print
    print(
      'VOICE before=${before ~/ (1024 * 1024)}MB after=${after ~/ (1024 * 1024)}MB '
      'kept=${directory.listSync().length}/20',
    );
    expect(after, lessThanOrEqualTo(12 * bytes));

    final survivors = directory
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .toSet();
    // The eight oldest go, the twelve newest stay.
    expect(survivors, containsAll(names.sublist(8)));
    for (final dropped in names.sublist(0, 8)) {
      expect(survivors, isNot(contains(dropped)));
    }
  });

  test('leaves another account untouched', () async {
    const bytes = 1024 * 1024;
    await seed(accountId: 'account-a', count: 20, bytes: bytes);
    final other = await seed(accountId: 'account-b', count: 4, bytes: bytes);

    await pruneAccountVoiceFiles(
      directory: directory,
      accountId: 'account-a',
      maximumBytes: 4 * bytes,
    );

    final survivors = directory
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .toSet();
    expect(survivors, containsAll(other));
    expect(survivors.length, 8);
  });

  test('does nothing while the account is under the bound', () async {
    await seed(accountId: 'account-a', count: 3, bytes: 1024);
    await pruneAccountVoiceFiles(
      directory: directory,
      accountId: 'account-a',
      maximumBytes: 64 * 1024 * 1024,
    );
    expect(directory.listSync(), hasLength(3));
  });

  test('playback recovers after a file is pruned away', () async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final vault = MemoryCredentialVault()..values['account-a'] = 'app-password';
    final account = await AccountRepository(database).upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 1, 1),
    );

    var downloads = 0;
    final repository = ChatMediaRepository(
      vault,
      client: MockClient((request) async {
        downloads++;
        return http.Response.bytes(
          Uint8List(2048),
          200,
          headers: {'content-type': 'audio/mp4'},
        );
      }),
    );
    final uri = Uri.parse(
      'https://cloud.example.invalid/remote.php/dav/voice-7.m4a',
    );
    final cacheKey = chatVoiceCacheKey(accountId: account.id, messageId: 7);

    final first = await repository.loadVoiceFile(
      account: account,
      uri: uri,
      directory: directory,
      cacheKey: cacheKey,
    );
    expect(File(first.path).existsSync(), isTrue);

    // Drop everything this account owns, the way a full cache would.
    await pruneAccountVoiceFiles(
      directory: directory,
      accountId: account.id,
      maximumBytes: 0,
    );
    expect(File(first.path).existsSync(), isFalse);

    final second = await repository.loadVoiceFile(
      account: account,
      uri: uri,
      directory: directory,
      cacheKey: cacheKey,
    );
    expect(File(second.path).existsSync(), isTrue);
    expect(second.path, first.path);
    expect(downloads, 2, reason: 'an evicted voice file is simply refetched');
  });
}
