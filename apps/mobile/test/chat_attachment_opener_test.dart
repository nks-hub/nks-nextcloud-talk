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
    'pruning protects a completed download while its launcher runs',
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
      final blockedLauncher = _BlockingLauncher();
      final blockedOpener = ChatAttachmentOpener(
        repository: repository,
        cacheDirectory: () async => root,
        launcher: blockedLauncher,
        maximumCacheBytes: 4,
        maximumCacheEntries: 1,
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
      expect(await File(activePath).exists(), isFalse);
    },
  );

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
  final Completer<void> _started = Completer<void>();
  final Completer<void> _released = Completer<void>();

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
    return true;
  }
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
