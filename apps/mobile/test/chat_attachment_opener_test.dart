import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';
import 'package:nextcloudtalk/features/chat/media/chat_attachment_opener.dart';

import 'test_support.dart';

void main() {
  test(
    'concurrent attachments with the same name keep separate files',
    () async {
      final root = await Directory.systemTemp.createTemp('attachment-names-');
      addTearDown(() => root.delete(recursive: true));
      final launcher = _RecordingLauncher();
      final opener = ChatAttachmentOpener(
        repository: _repository(
          (request) async => http.StreamedResponse(
            Stream.value(utf8.encode(request.url.pathSegments.last)),
            200,
            headers: {'content-type': 'text/plain'},
          ),
        ),
        cacheDirectory: () async => root,
        launcher: launcher,
      );

      final results = await Future.wait([
        for (final name in ['first.txt', 'second.txt'])
          opener.open(
            account: _account,
            uri: _uri.resolve(name),
            fileName: 'report.txt',
            expectedContentType: 'text/plain',
          ),
      ]);

      expect(results, everyElement(ChatAttachmentOpenResult.opened));
      expect(launcher.paths.toSet(), hasLength(2));
      expect(
        await Future.wait(
          launcher.paths.map((path) => File(path).readAsString()),
        ),
        unorderedEquals(['first.txt', 'second.txt']),
      );
      await evictChatAttachmentFiles(
        rootDirectory: root,
        accountId: _account.id,
      );
      for (final path in launcher.paths) {
        expect(await File(path).exists(), isFalse);
      }
    },
  );

  test(
    'downloads exact authenticated bytes before opening a safe local file',
    () async {
      final root = await Directory.systemTemp.createTemp('attachment-open-');
      addTearDown(() => root.delete(recursive: true));
      final launcher = _RecordingLauncher();
      final opener = ChatAttachmentOpener(
        repository: _repository(
          (_) async => http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('exact original text')),
            200,
            headers: const {'content-type': 'text/plain'},
          ),
        ),
        cacheDirectory: () async => root,
        launcher: launcher,
      );

      final result = await opener.open(
        account: _account,
        uri: _uri,
        fileName: r'../../report final?.txt',
        expectedContentType: 'text/plain',
      );

      expect(result, ChatAttachmentOpenResult.opened);
      expect(launcher.paths, hasLength(1));
      final file = File(launcher.paths.single);
      expect(await file.readAsString(), 'exact original text');
      expect(file.path, startsWith(root.path));
      expect(file.path, endsWith('${Platform.pathSeparator}report_final_.txt'));
      expect(launcher.contentTypes.single, 'text/plain');
    },
  );

  test('a cold opener preserves unfinished and foreign cache data', () async {
    final root = await Directory.systemTemp.createTemp('attachment-prune-');
    addTearDown(() => root.delete(recursive: true));
    final leases = _ManualLeaseScheduler();
    addTearDown(leases.expireAll);
    final launcher = _RecordingLauncher();
    final repository = _repository(
      (_) async => http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode('data')),
        200,
        headers: const {'content-type': 'text/plain'},
      ),
    );
    final seed = ChatAttachmentOpener(
      repository: repository,
      cacheDirectory: () async => root,
      launcher: launcher,
      maximumCacheBytes: 1024,
      maximumCacheEntries: 10,
      leaseScheduler: leases.schedule,
      now: leases.now,
    );

    final oldNames = ['oldest.txt', 'middle.txt', 'newest.txt'];
    for (var index = 0; index < oldNames.length; index++) {
      final name = oldNames[index];
      expect(
        await seed.open(
          account: _account,
          uri: _uri.resolve(name),
          fileName: name,
          expectedContentType: 'text/plain',
        ),
        ChatAttachmentOpenResult.opened,
      );
      await _setCacheCompletionTime(
        launcher.paths.last,
        DateTime.utc(2026, 1, 1).add(Duration(minutes: index)),
      );
      await leases.expireNext();
    }

    final accountDirectory = chatAttachmentCacheAccountDirectory(
      rootDirectory: root,
      accountId: _account.id,
    );
    final unfinished = await accountDirectory.createTemp('download-');
    final unfinishedFile = File(
      '${unfinished.path}${Platform.pathSeparator}partial.bin',
    );
    await unfinishedFile.writeAsString('partial');
    final foreignDirectory = chatAttachmentCacheAccountDirectory(
      rootDirectory: root,
      accountId: 'account-b',
    );
    await foreignDirectory.create(recursive: true);
    final foreignFile = File(
      '${foreignDirectory.path}${Platform.pathSeparator}keep.bin',
    );
    await foreignFile.writeAsString('foreign');

    final restarted = ChatAttachmentOpener(
      repository: repository,
      cacheDirectory: () async => root,
      launcher: launcher,
      maximumCacheBytes: 8,
      maximumCacheEntries: 2,
      leaseScheduler: leases.schedule,
      now: leases.now,
    );
    expect(
      await restarted.open(
        account: _account,
        uri: _uri.resolve('current.txt'),
        fileName: 'current.txt',
        expectedContentType: 'text/plain',
      ),
      ChatAttachmentOpenResult.opened,
    );

    expect(await File(launcher.paths[0]).exists(), isFalse);
    expect(await File(launcher.paths[1]).exists(), isFalse);
    expect(await File(launcher.paths[2]).exists(), isTrue);
    expect(await File(launcher.paths[3]).exists(), isTrue);
    expect(
      await Future.wait([
        File(launcher.paths[2]).length(),
        File(launcher.paths[3]).length(),
      ]).then((sizes) => sizes.fold<int>(0, (sum, size) => sum + size)),
      lessThanOrEqualTo(8),
    );
    expect(await unfinishedFile.exists(), isTrue);
    expect(await foreignFile.exists(), isTrue);
  });

  test(
    'active and leased downloads survive pruning until lease expiry',
    () async {
      final root = await Directory.systemTemp.createTemp('attachment-active-');
      addTearDown(() => root.delete(recursive: true));
      final repository = _repository(
        (_) async => http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode('data')),
          200,
          headers: const {'content-type': 'text/plain'},
        ),
      );
      final blockedLeases = _ManualLeaseScheduler();
      final pruningLeases = _ManualLeaseScheduler();
      addTearDown(blockedLeases.expireAll);
      addTearDown(pruningLeases.expireAll);
      final blockedLauncher = _BlockingLauncher();
      final blockedOpener = ChatAttachmentOpener(
        repository: repository,
        cacheDirectory: () async => root,
        launcher: blockedLauncher,
        maximumCacheBytes: 4,
        maximumCacheEntries: 1,
        leaseScheduler: blockedLeases.schedule,
        now: blockedLeases.now,
      );
      final blockedOpen = blockedOpener.open(
        account: _account,
        uri: _uri.resolve('active.txt'),
        fileName: 'active.txt',
        expectedContentType: 'text/plain',
      );
      addTearDown(() async {
        blockedLauncher.release();
        await blockedOpen;
      });
      await blockedLauncher.started;
      final activePath = blockedLauncher.path!;

      final launcher = _RecordingLauncher();
      final pruningOpener = ChatAttachmentOpener(
        repository: repository,
        cacheDirectory: () async => root,
        launcher: launcher,
        maximumCacheBytes: 4,
        maximumCacheEntries: 1,
        leaseScheduler: pruningLeases.schedule,
        now: pruningLeases.now,
      );
      expect(
        await pruningOpener.open(
          account: _account,
          uri: _uri.resolve('second.txt'),
          fileName: 'second.txt',
          expectedContentType: 'text/plain',
        ),
        ChatAttachmentOpenResult.opened,
      );
      expect(
        await pruningOpener.open(
          account: _account,
          uri: _uri.resolve('third.txt'),
          fileName: 'third.txt',
          expectedContentType: 'text/plain',
        ),
        ChatAttachmentOpenResult.opened,
      );
      expect(await File(activePath).exists(), isTrue);

      blockedLauncher.release();
      expect(await blockedOpen, ChatAttachmentOpenResult.opened);
      expect(await File(activePath).exists(), isTrue);

      expect(
        await pruningOpener.open(
          account: _account,
          uri: _uri.resolve('later.txt'),
          fileName: 'later.txt',
          expectedContentType: 'text/plain',
        ),
        ChatAttachmentOpenResult.opened,
      );
      expect(await File(activePath).exists(), isTrue);

      await blockedLeases.expireNext();
      expect(await File(activePath).exists(), isFalse);
    },
  );

  test(
    'housekeeping removes an old orphan but preserves a live download',
    () async {
      final root = await Directory.systemTemp.createTemp('attachment-orphan-');
      addTearDown(() => root.delete(recursive: true));
      final stream = StreamController<List<int>>();
      addTearDown(() async {
        if (!stream.isClosed) {
          await stream.close();
        }
      });
      final firstBytes = Completer<void>();
      final clock = _ManualLeaseScheduler();
      addTearDown(clock.expireAll);
      final opener = ChatAttachmentOpener(
        repository: _repository(
          (_) async => http.StreamedResponse(
            stream.stream,
            200,
            contentLength: 4,
            headers: const {'content-type': 'text/plain'},
          ),
        ),
        cacheDirectory: () async => root,
        launcher: _RecordingLauncher(),
        incompleteGracePeriod: const Duration(hours: 48),
        leaseScheduler: clock.schedule,
        now: clock.now,
      );
      final opening = opener.open(
        account: _account,
        uri: _uri,
        fileName: 'live.txt',
        expectedContentType: 'text/plain',
        onProgress: (received, _) {
          if (received > 0 && !firstBytes.isCompleted) {
            firstBytes.complete();
          }
        },
      );
      addTearDown(() async {
        if (!stream.isClosed) {
          await stream.close();
        }
        await opening;
      });
      stream.add(const [1]);
      await firstBytes.future;

      final accountDirectory = chatAttachmentCacheAccountDirectory(
        rootDirectory: root,
        accountId: _account.id,
      );
      final liveDirectory = (await accountDirectory.list().toList())
          .whereType<Directory>()
          .single;
      final liveFile = (await liveDirectory.list().toList())
          .whereType<File>()
          .single;
      final orphan = await accountDirectory.createTemp('download-');
      final orphanFile = File(
        '${orphan.path}${Platform.pathSeparator}orphan.bin',
      );
      await orphanFile.writeAsString('old');
      await orphanFile.setLastModified(clock.now());
      clock.advance(const Duration(hours: 72));
      final housekeeper = ChatAttachmentCacheHousekeeper(
        cacheDirectory: () async => root,
        incompleteGracePeriod: const Duration(hours: 48),
        scheduler: clock.schedule,
        now: clock.now,
      );
      addTearDown(housekeeper.dispose);

      await housekeeper.run();

      expect(await liveFile.exists(), isTrue);
      expect(await orphan.exists(), isFalse);

      stream.add(const [2, 3, 4]);
      await stream.close();
      expect(await opening, ChatAttachmentOpenResult.opened);
    },
  );

  test('a persisted future lease survives process restart', () async {
    final root = await Directory.systemTemp.createTemp('attachment-restart-');
    addTearDown(() => root.delete(recursive: true));
    final clock = _ManualLeaseScheduler();
    final leaseUntil = clock.now().add(const Duration(minutes: 10));
    final path = await _seedCompletedAttachment(
      root: root,
      leaseUntil: leaseUntil,
      completedAt: clock.now(),
      bytes: 4,
    );
    final housekeeper = ChatAttachmentCacheHousekeeper(
      cacheDirectory: () async => root,
      maximumCacheBytes: 3,
      maximumCacheEntries: 1,
      scheduler: clock.schedule,
      now: clock.now,
    );
    addTearDown(housekeeper.dispose);

    await housekeeper.run();

    expect(await File(path).exists(), isTrue);
    expect(clock.durations, [const Duration(minutes: 10)]);

    await clock.expireNext();

    expect(await File(path).exists(), isFalse);
  });

  test('startup housekeeping removes an expired oversized entry', () async {
    final root = await Directory.systemTemp.createTemp('attachment-expired-');
    addTearDown(() => root.delete(recursive: true));
    final clock = _ManualLeaseScheduler();
    final path = await _seedCompletedAttachment(
      root: root,
      leaseUntil: clock.now().subtract(const Duration(minutes: 1)),
      completedAt: clock.now(),
      bytes: 4,
    );
    final housekeeper = ChatAttachmentCacheHousekeeper(
      cacheDirectory: () async => root,
      maximumCacheBytes: 3,
      maximumCacheEntries: 1,
      scheduler: clock.schedule,
      now: clock.now,
    );
    addTearDown(housekeeper.dispose);

    await housekeeper.run();

    expect(await File(path).exists(), isFalse);
    expect(clock.durations, isEmpty);
  });

  test('housekeeping keeps one timer and cancels it on dispose', () async {
    final root = await Directory.systemTemp.createTemp('attachment-timer-');
    addTearDown(() => root.delete(recursive: true));
    final clock = _ManualLeaseScheduler();
    await _seedCompletedAttachment(
      root: root,
      leaseUntil: clock.now().add(const Duration(minutes: 10)),
      completedAt: clock.now(),
      bytes: 4,
    );
    final housekeeper = ChatAttachmentCacheHousekeeper(
      cacheDirectory: () async => root,
      maximumCacheBytes: 3,
      maximumCacheEntries: 1,
      scheduler: clock.schedule,
      now: clock.now,
    );

    await housekeeper.run();
    expect(clock.activeCount, 1);

    await housekeeper.run();
    expect(clock.activeCount, 1);
    expect(clock.cancellations, 1);

    housekeeper.dispose();
    expect(clock.activeCount, 0);
    expect(clock.cancellations, 2);
  });

  test(
    'account eviction cancels its lease and releases its coordinator',
    () async {
      final root = await Directory.systemTemp.createTemp('attachment-evict-');
      addTearDown(() => root.delete(recursive: true));
      final clock = _ManualLeaseScheduler();
      addTearDown(clock.expireAll);
      final opener = ChatAttachmentOpener(
        repository: _repository(
          (_) async => http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('data')),
            200,
            headers: const {'content-type': 'text/plain'},
          ),
        ),
        cacheDirectory: () async => root,
        launcher: _RecordingLauncher(),
        leaseScheduler: clock.schedule,
        now: clock.now,
      );
      expect(await _open(opener), ChatAttachmentOpenResult.opened);
      final accountDirectory = chatAttachmentCacheAccountDirectory(
        rootDirectory: root,
        accountId: _account.id,
      );
      expect(debugHasChatAttachmentCacheCoordinator(accountDirectory), isTrue);
      expect(clock.activeCount, 1);

      await evictChatAttachmentFiles(
        rootDirectory: root,
        accountId: _account.id,
      );

      expect(debugHasChatAttachmentCacheCoordinator(accountDirectory), isFalse);
      expect(clock.activeCount, 0);
      expect(clock.cancellations, 1);
    },
  );

  test(
    'account eviction keeps a live coordinator until opening finishes',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'attachment-active-evict-',
      );
      addTearDown(() => root.delete(recursive: true));
      final launcher = _BlockingLauncher(result: false);
      addTearDown(launcher.release);
      final opener = ChatAttachmentOpener(
        repository: _repository(
          (_) async => http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('data')),
            200,
            headers: const {'content-type': 'text/plain'},
          ),
        ),
        cacheDirectory: () async => root,
        launcher: launcher,
      );
      final opening = _open(opener);
      await launcher.started;
      final accountDirectory = chatAttachmentCacheAccountDirectory(
        rootDirectory: root,
        accountId: _account.id,
      );

      await evictChatAttachmentFiles(
        rootDirectory: root,
        accountId: _account.id,
      );

      expect(debugHasChatAttachmentCacheCoordinator(accountDirectory), isTrue);
      launcher.release();
      expect(await opening, ChatAttachmentOpenResult.openFailed);
      expect(debugHasChatAttachmentCacheCoordinator(accountDirectory), isFalse);
    },
  );

  test(
    'an oversized download is pruned automatically after its lease',
    () async {
      final root = await Directory.systemTemp.createTemp('attachment-lease-');
      addTearDown(() => root.delete(recursive: true));
      final leases = _ManualLeaseScheduler();
      addTearDown(leases.expireAll);
      final launcher = _RecordingLauncher();
      final opener = ChatAttachmentOpener(
        repository: _repository(
          (_) async => http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('data')),
            200,
            headers: const {'content-type': 'text/plain'},
          ),
        ),
        cacheDirectory: () async => root,
        launcher: launcher,
        maximumCacheBytes: 3,
        maximumCacheEntries: 1,
        leaseScheduler: leases.schedule,
        now: leases.now,
      );

      expect(await _open(opener), ChatAttachmentOpenResult.opened);
      final path = launcher.paths.single;
      expect(await File(path).exists(), isTrue);
      expect(leases.durations, [const Duration(minutes: 15)]);

      await leases.expireNext();

      expect(await File(path).exists(), isFalse);
    },
  );

  test('concurrent prune requests are serialized per account', () async {
    final root = await Directory.systemTemp.createTemp('attachment-serial-');
    addTearDown(() => root.delete(recursive: true));
    http.StreamedResponse response() => http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('data')),
      200,
      headers: const {'content-type': 'text/plain'},
    );
    final seedLeases = _ManualLeaseScheduler();
    addTearDown(seedLeases.expireAll);
    final seedLauncher = _RecordingLauncher();
    final seed = ChatAttachmentOpener(
      repository: _repository((_) async => response()),
      cacheDirectory: () async => root,
      launcher: seedLauncher,
      maximumCacheBytes: 1024,
      maximumCacheEntries: 10,
      leaseScheduler: seedLeases.schedule,
      now: seedLeases.now,
    );
    for (var index = 0; index < 2; index++) {
      expect(
        await seed.open(
          account: _account,
          uri: _uri.resolve('old-$index.txt'),
          fileName: 'old-$index.txt',
          expectedContentType: 'text/plain',
        ),
        ChatAttachmentOpenResult.opened,
      );
      await _setCacheCompletionTime(
        seedLauncher.paths.last,
        DateTime.utc(2026, 1, 1).add(Duration(minutes: index)),
      );
      await seedLeases.expireNext();
    }

    final bothDownloading = Completer<void>();
    final allowDownloads = Completer<void>();
    var downloads = 0;
    final repository = _repository((_) async {
      if (++downloads == 2) {
        bothDownloading.complete();
      }
      await allowDownloads.future;
      return response();
    });
    final launcher = _RecordingLauncher();
    final first = ChatAttachmentOpener(
      repository: repository,
      cacheDirectory: () async => root,
      launcher: launcher,
      maximumCacheBytes: 1024,
      maximumCacheEntries: 1,
      leaseScheduler: seedLeases.schedule,
      now: seedLeases.now,
    );
    final second = ChatAttachmentOpener(
      repository: repository,
      cacheDirectory: () async => root,
      launcher: launcher,
      maximumCacheBytes: 1024,
      maximumCacheEntries: 1,
      leaseScheduler: seedLeases.schedule,
      now: seedLeases.now,
    );
    final firstOpen = _open(first);
    final secondOpen = _open(second);
    addTearDown(() async {
      if (!allowDownloads.isCompleted) {
        allowDownloads.complete();
      }
      await Future.wait([firstOpen, secondOpen]);
    });

    // A completed concurrent download counts towards the pruning limit.
    await bothDownloading.future;
    final oldFilesStillPresent = await Future.wait(
      seedLauncher.paths.map((path) => File(path).exists()),
    );
    expect(oldFilesStillPresent.where((exists) => exists), hasLength(1));

    allowDownloads.complete();
    expect(
      await Future.wait([firstOpen, secondOpen]),
      everyElement(ChatAttachmentOpenResult.opened),
    );
    await seedLeases.expireAll();
  });

  test(
    'does not invoke the platform when authenticated download fails',
    () async {
      final root = await Directory.systemTemp.createTemp('attachment-fail-');
      addTearDown(() => root.delete(recursive: true));
      final launcher = _RecordingLauncher();
      final opener = ChatAttachmentOpener(
        repository: _repository(
          (_) async => http.StreamedResponse(
            Stream<List<int>>.value(const [1, 2, 3]),
            503,
          ),
        ),
        cacheDirectory: () async => root,
        launcher: launcher,
      );

      final result = await opener.open(
        account: _account,
        uri: _uri,
        fileName: 'report.txt',
        expectedContentType: 'text/plain',
      );

      expect(result, ChatAttachmentOpenResult.downloadFailed);
      expect(launcher.paths, isEmpty);
      final accountDirectory = chatAttachmentCacheAccountDirectory(
        rootDirectory: root,
        accountId: _account.id,
      );
      expect(await accountDirectory.list().toList(), isEmpty);
    },
  );

  test('reports a platform refusal after the local file is complete', () async {
    final root = await Directory.systemTemp.createTemp('attachment-refused-');
    addTearDown(() => root.delete(recursive: true));
    final opener = ChatAttachmentOpener(
      repository: _repository(
        (_) async => http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode('complete')),
          200,
          headers: const {'content-type': 'text/plain'},
        ),
      ),
      cacheDirectory: () async => root,
      launcher: _RecordingLauncher(opened: false),
    );

    final result = await opener.open(
      account: _account,
      uri: _uri,
      fileName: 'report.txt',
      expectedContentType: 'text/plain',
    );

    expect(result, ChatAttachmentOpenResult.openFailed);
    final accountDirectory = chatAttachmentCacheAccountDirectory(
      rootDirectory: root,
      accountId: _account.id,
    );
    expect(await accountDirectory.list().toList(), isEmpty);
  });

  test(
    'preserves authentication, size, invalid, and storage failures',
    () async {
      // The download now writes straight into the cache directory, so every
      // opener here needs a real one; only the last case withholds it on
      // purpose.
      final root = await Directory.systemTemp.createTemp('opener-failures-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final missingCredential = ChatAttachmentOpener(
        repository: ChatMediaRepository(
          MemoryCredentialVault(),
          client: _StreamingClient(
            (_) async => throw StateError('must not request'),
          ),
        ),
        cacheDirectory: () async => root,
        launcher: _RecordingLauncher(),
      );
      final tooLarge = ChatAttachmentOpener(
        repository: _repository(
          (_) async => http.StreamedResponse(
            const Stream.empty(),
            200,
            contentLength: 2 * 1024 * 1024 * 1024 + 1,
            headers: const {'content-type': 'text/plain'},
          ),
        ),
        cacheDirectory: () async => root,
        launcher: _RecordingLauncher(),
      );
      final invalid = ChatAttachmentOpener(
        repository: _repository(
          (_) async => http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('<html>')),
            200,
            headers: const {'content-type': 'text/html'},
          ),
        ),
        cacheDirectory: () async => root,
        launcher: _RecordingLauncher(),
      );
      final storage = ChatAttachmentOpener(
        repository: _repository(
          (_) async => http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('body')),
            200,
            headers: const {'content-type': 'text/plain'},
          ),
        ),
        cacheDirectory: () async => throw const FileSystemException('denied'),
        launcher: _RecordingLauncher(),
      );

      expect(
        await _open(missingCredential),
        ChatAttachmentOpenResult.reauthenticationRequired,
      );
      expect(await _open(tooLarge), ChatAttachmentOpenResult.tooLarge);
      expect(await _open(invalid), ChatAttachmentOpenResult.invalid);
      expect(await _open(storage), ChatAttachmentOpenResult.storageFailed);
    },
  );

  test('safe names reject Windows devices and trailing dots', () {
    expect(chatAttachmentFileName('CON'), '_CON');
    expect(chatAttachmentFileName('nul.txt'), '_nul.txt');
    expect(chatAttachmentFileName('COM1.csv'), '_COM1.csv');
    expect(chatAttachmentFileName('LPT9.'), '_LPT9');
    expect(chatAttachmentFileName('report...'), 'report');
    expect(chatAttachmentFileName(r'..\AUX '), '_AUX');
  });
}

Future<ChatAttachmentOpenResult> _open(ChatAttachmentOpener opener) {
  return opener.open(
    account: _account,
    uri: _uri,
    fileName: 'report.txt',
    expectedContentType: 'text/plain',
  );
}

Future<void> _setCacheCompletionTime(
  String attachmentPath,
  DateTime time,
) async {
  final siblings = await File(
    attachmentPath,
  ).parent.list(followLinks: false).toList();
  final markers = siblings
      .whereType<File>()
      .where((file) => file.path != attachmentPath)
      .toList();
  expect(markers, hasLength(1));
  await markers.single.setLastModified(time);
}

Future<String> _seedCompletedAttachment({
  required Directory root,
  required DateTime leaseUntil,
  required DateTime completedAt,
  required int bytes,
}) async {
  final accountDirectory = chatAttachmentCacheAccountDirectory(
    rootDirectory: root,
    accountId: _account.id,
  );
  await accountDirectory.create(recursive: true);
  final download = await accountDirectory.createTemp('download-');
  final attachment = File(
    '${download.path}${Platform.pathSeparator}fixture.bin',
  );
  await attachment.writeAsBytes(List<int>.filled(bytes, 1));
  final marker = File(
    '${download.path}${Platform.pathSeparator}.open-complete',
  );
  await marker.writeAsString(
    'leaseUntil=${leaseUntil.millisecondsSinceEpoch}\n',
    flush: true,
  );
  await marker.setLastModified(completedAt);
  return attachment.path;
}

ChatMediaRepository _repository(
  Future<http.StreamedResponse> Function(http.BaseRequest request) handler,
) {
  final vault = MemoryCredentialVault()
    ..values[_account.id] = 'fixture-app-password';
  return ChatMediaRepository(vault, client: _StreamingClient(handler));
}

final class _RecordingLauncher implements ChatAttachmentFileLauncher {
  _RecordingLauncher({this.opened = true});

  final bool opened;
  final List<String> paths = [];
  final List<String> contentTypes = [];

  @override
  Future<bool> open({required String path, required String contentType}) async {
    paths.add(path);
    contentTypes.add(contentType);
    return opened;
  }
}

final class _BlockingLauncher implements ChatAttachmentFileLauncher {
  _BlockingLauncher({this.result = true});

  final Completer<void> _started = Completer<void>();
  final Completer<void> _released = Completer<void>();
  final bool result;

  String? path;

  Future<void> get started => _started.future;

  void release() {
    if (!_released.isCompleted) {
      _released.complete();
    }
  }

  @override
  Future<bool> open({required String path, required String contentType}) async {
    this.path = path;
    _started.complete();
    await _released.future;
    return result;
  }
}

final class _ManualLeaseScheduler {
  final List<Duration> durations = <Duration>[];
  final List<_ManualExpiration> _expirations = <_ManualExpiration>[];
  DateTime _time = DateTime.utc(2026, 11, 21, 12);
  var cancellations = 0;

  int get activeCount =>
      _expirations.where((expiration) => !expiration.cancelled).length;

  DateTime now() => _time;

  void advance(Duration duration) {
    _time = _time.add(duration);
  }

  ChatAttachmentLeaseCancellation schedule(
    Duration duration,
    Future<void> Function() onExpired,
  ) {
    durations.add(duration);
    final expiration = _ManualExpiration(duration, onExpired);
    _expirations.add(expiration);
    return () {
      if (!expiration.cancelled) {
        expiration.cancelled = true;
        cancellations++;
      }
    };
  }

  Future<void> expireNext() async {
    _expirations.removeWhere((expiration) => expiration.cancelled);
    expect(_expirations, isNotEmpty);
    final expiration = _expirations.removeAt(0)..cancelled = true;
    _time = _time.add(expiration.duration);
    await expiration.onExpired();
  }

  Future<void> expireAll() async {
    while (activeCount > 0) {
      await expireNext();
    }
    _expirations.clear();
  }
}

final class _ManualExpiration {
  _ManualExpiration(this.duration, this.onExpired);

  final Duration duration;
  final Future<void> Function() onExpired;
  var cancelled = false;
}

final class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

const StoredAccount _account = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: true,
  createdAtMillis: 1767225600000,
);

final Uri _uri = Uri.parse(
  'https://cloud.example.invalid/remote.php/dav/files/'
  'fixture-user/Talk/report.txt',
);
