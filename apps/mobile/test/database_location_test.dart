import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/app_database.dart';

void main() {
  late Directory root;
  late Directory documents;
  late Directory support;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nctalk-location-');
    documents = await Directory(
      '${root.path}${Platform.pathSeparator}documents',
    ).create();
    support = await Directory(
      '${root.path}${Platform.pathSeparator}support',
    ).create();
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  File file(Directory directory, String name) =>
      File('${directory.path}${Platform.pathSeparator}$name');

  test('moves the database and its write-ahead log out of documents', () async {
    await file(documents, 'nks_nextcloud_talk.sqlite').writeAsString('main');
    await file(documents, 'nks_nextcloud_talk.sqlite-wal').writeAsString('wal');
    await file(documents, 'nks_nextcloud_talk.sqlite-shm').writeAsString('shm');

    final moved = await moveLegacyDatabaseFiles(documents, support);

    expect(moved, hasLength(3));
    expect(
      await file(support, 'nks_nextcloud_talk.sqlite').readAsString(),
      'main',
    );
    expect(
      await file(support, 'nks_nextcloud_talk.sqlite-wal').readAsString(),
      'wal',
    );
    expect(
      await file(documents, 'nks_nextcloud_talk.sqlite').exists(),
      isFalse,
    );
  });

  test('never overwrites a database already in the new location', () async {
    await file(documents, 'nks_nextcloud_talk.sqlite').writeAsString('legacy');
    await file(support, 'nks_nextcloud_talk.sqlite').writeAsString('current');

    final moved = await moveLegacyDatabaseFiles(documents, support);

    expect(moved, isEmpty);
    expect(
      await file(support, 'nks_nextcloud_talk.sqlite').readAsString(),
      'current',
    );
    expect(
      await file(documents, 'nks_nextcloud_talk.sqlite').readAsString(),
      'legacy',
    );
  });

  test('does nothing when both directories are the same', () async {
    await file(documents, 'nks_nextcloud_talk.sqlite').writeAsString('main');

    expect(await moveLegacyDatabaseFiles(documents, documents), isEmpty);
    expect(
      await file(documents, 'nks_nextcloud_talk.sqlite').readAsString(),
      'main',
    );
  });

  test('leaves a fresh install alone', () async {
    expect(await moveLegacyDatabaseFiles(documents, support), isEmpty);
    expect(await support.list().isEmpty, isTrue);
  });
}
