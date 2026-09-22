import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';
import 'package:nextcloudtalk/features/chat/media/chat_attachment_exporter.dart';
import 'package:nextcloudtalk/features/chat/media/chat_attachment_mobile_saver.dart';
import 'package:nextcloudtalk/features/chat/media/chat_attachment_opener.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The exporter streams a download into a scratch directory before handing
  /// it to the platform, and `path_provider` has no implementation in a unit
  /// test, so every exporter here is given a real temporary directory.
  Future<Directory> scratch() async {
    final directory = await Directory.systemTemp.createTemp('exporter-test-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    return directory;
  }

  test('save uses authenticated bytes, safe name, and received MIME', () async {
    late http.BaseRequest request;
    final system = _RecordingSystem();
    final exporter = ChatAttachmentExporter(
      temporaryDirectory: scratch,
      repository: _repository((sent) async {
        request = sent;
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode('report body')),
          200,
          headers: const {'content-type': 'text/plain; charset=utf-8'},
        );
      }),
      system: system,
    );

    final result = await exporter.save(
      account: _account,
      uri: _uri,
      fileName: r'../../report final?.txt',
      expectedContentType: 'text/plain',
    );

    expect(result, ChatAttachmentSaveResult.saved);
    expect(request.headers['authorization'], isNotEmpty);
    expect(system.savedBytes.single, utf8.encode('report body'));
    expect(system.savedNames.single, 'report_final_.txt');
    expect(system.savedTypes.single, 'text/plain');
  });

  test(
    'account wipe removes a source waiting in the mobile picker only for that account',
    () async {
      final root = await scratch();
      final delayed = _DelayedMobileSaver();
      final other = _RecordingMobileSaver();
      final repository = ChatMediaRepository(
        MemoryCredentialVault()
          ..values[_account.id] = 'password-a'
          ..values['account-b'] = 'password-b',
        client: _StreamingClient(
          (_) async => http.StreamedResponse(
            Stream.value(utf8.encode('private attachment')),
            200,
            headers: {'content-type': 'text/plain'},
          ),
        ),
      );
      ChatAttachmentExporter exporter(ChatAttachmentMobileSaver saver) =>
          ChatAttachmentExporter(
            repository: repository,
            temporaryDirectory: () async => root,
            system: PlatformChatAttachmentSystem(
              mobilePlatform: true,
              mobileSaver: saver,
            ),
          );
      final pending = exporter(delayed).save(
        account: _account,
        uri: _uri,
        fileName: 'report.txt',
        expectedContentType: 'text/plain',
      );
      final source = await delayed.opened.future;
      expect(await File(source).exists(), isTrue);
      await repository.suspendAccount(_account.id);
      await evictChatAttachmentFiles(
        rootDirectory: root,
        accountId: _account.id,
      );
      expect(await File(source).exists(), isFalse);

      final otherResult = await exporter(other).save(
        account: _account.copyWith(id: 'account-b'),
        uri: _uri,
        fileName: 'report.txt',
        expectedContentType: 'text/plain',
      );
      expect(otherResult, ChatAttachmentSaveResult.saved);
      expect(other.bytes.single, utf8.encode('private attachment'));

      delayed.destinationChosen.complete();
      expect(await pending, ChatAttachmentSaveResult.storageFailed);
      expect(delayed.copied, isFalse);
    },
  );

  test('an attachment far past the old in-memory ceiling still saves', () async {
    // The limit used to be 64 MiB of buffered bytes, so a 117 MB build shared
    // in a conversation could not be saved at all — and said so only after the
    // download had already run. The bytes now go straight to disk.
    const chunk = 1024 * 1024;
    const chunks = 80;
    final system = _RecordingSystem();
    final exporter = ChatAttachmentExporter(
      temporaryDirectory: scratch,
      repository: _repository(
        (_) async => http.StreamedResponse(
          Stream<List<int>>.fromIterable(
            List<List<int>>.generate(chunks, (_) => Uint8List(chunk)),
          ),
          200,
          contentLength: chunk * chunks,
          headers: const {
            'content-type': 'application/vnd.android.package-archive',
          },
        ),
      ),
      system: system,
    );

    final result = await exporter.save(
      account: _account,
      uri: _uri,
      fileName: 'build.apk',
      expectedContentType: 'application/vnd.android.package-archive',
    );

    expect(result, ChatAttachmentSaveResult.saved);
    expect(system.savedBytes.single.length, chunk * chunks);
    expect(system.savedNames.single, 'build.apk');
  });

  test('save cancellation is not reported as a storage failure', () async {
    final system = _RecordingSystem(
      saveResult: ChatAttachmentSystemResult.cancelled,
    );
    final exporter = ChatAttachmentExporter(
      temporaryDirectory: scratch,
      repository: _successfulRepository(),
      system: system,
    );

    final result = await exporter.save(
      account: _account,
      uri: _uri,
      fileName: 'report.txt',
      expectedContentType: 'text/plain',
    );

    expect(result, ChatAttachmentSaveResult.cancelled);
  });

  test(
    'save keeps repository, permission, and storage failures distinct',
    () async {
      final downloadFailure = ChatAttachmentExporter(
        temporaryDirectory: scratch,
        repository: _repository(
          (_) async => http.StreamedResponse(const Stream.empty(), 503),
        ),
        system: _RecordingSystem(),
      );
      final permissionFailure = ChatAttachmentExporter(
        temporaryDirectory: scratch,
        repository: _successfulRepository(),
        system: _RecordingSystem(
          saveResult: ChatAttachmentSystemResult.permissionDenied,
        ),
      );
      final storageFailure = ChatAttachmentExporter(
        temporaryDirectory: scratch,
        repository: _successfulRepository(),
        system: _RecordingSystem(
          saveResult: ChatAttachmentSystemResult.storageFailed,
        ),
      );

      expect(
        await _save(downloadFailure),
        ChatAttachmentSaveResult.downloadFailed,
      );
      expect(
        await _save(permissionFailure),
        ChatAttachmentSaveResult.permissionDenied,
      );
      expect(
        await _save(storageFailure),
        ChatAttachmentSaveResult.storageFailed,
      );

      final missingCredential = ChatAttachmentExporter(
        temporaryDirectory: scratch,
        repository: _repository(
          (_) async => throw StateError('must not request'),
          withCredential: false,
        ),
        system: _RecordingSystem(),
      );
      final tooLarge = ChatAttachmentExporter(
        temporaryDirectory: scratch,
        repository: _repository(
          (_) async => http.StreamedResponse(
            const Stream.empty(),
            200,
            // Above the streamed-to-disk ceiling. A 117 MB build used to
            // land here, which is exactly what the limit was raised for.
            contentLength: 2 * 1024 * 1024 * 1024 + 1,
            headers: const {'content-type': 'text/plain'},
          ),
        ),
        system: _RecordingSystem(),
      );
      final invalid = ChatAttachmentExporter(
        temporaryDirectory: scratch,
        repository: _repository(
          (_) async => http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('<html>')),
            200,
            headers: const {'content-type': 'text/html'},
          ),
        ),
        system: _RecordingSystem(),
      );

      expect(
        await _save(missingCredential),
        ChatAttachmentSaveResult.reauthenticationRequired,
      );
      expect(await _save(tooLarge), ChatAttachmentSaveResult.tooLarge);
      expect(await _save(invalid), ChatAttachmentSaveResult.invalid);
    },
  );

  test('share uses safe name and actual MIME from the DAV response', () async {
    final system = _RecordingSystem();
    final exporter = ChatAttachmentExporter(
      temporaryDirectory: scratch,
      repository: _successfulRepository(contentType: 'text/csv'),
      system: system,
    );

    final result = await exporter.share(
      account: _account,
      uri: _uri,
      fileName: r'C:\incoming\monthly report?.csv',
      expectedContentType: 'text/csv',
    );

    expect(result, ChatAttachmentShareResult.shared);
    expect(system.sharedNames.single, 'monthly_report_.csv');
    expect(system.sharedTypes.single, 'text/csv');
  });

  test(
    'share keeps cancel, download, permission, and sheet failure distinct',
    () async {
      final cancelled = ChatAttachmentExporter(
        temporaryDirectory: scratch,
        repository: _successfulRepository(),
        system: _RecordingSystem(
          shareResult: ChatAttachmentSystemResult.cancelled,
        ),
      );
      final downloadFailure = ChatAttachmentExporter(
        temporaryDirectory: scratch,
        repository: _repository(
          (_) async => http.StreamedResponse(const Stream.empty(), 404),
        ),
        system: _RecordingSystem(),
      );
      final permissionFailure = ChatAttachmentExporter(
        temporaryDirectory: scratch,
        repository: _successfulRepository(),
        system: _RecordingSystem(
          shareResult: ChatAttachmentSystemResult.permissionDenied,
        ),
      );
      final sheetFailure = ChatAttachmentExporter(
        temporaryDirectory: scratch,
        repository: _successfulRepository(),
        system: _RecordingSystem(
          shareResult: ChatAttachmentSystemResult.unavailable,
        ),
      );

      expect(await _share(cancelled), ChatAttachmentShareResult.cancelled);
      expect(
        await _share(downloadFailure),
        ChatAttachmentShareResult.downloadFailed,
      );
      expect(
        await _share(permissionFailure),
        ChatAttachmentShareResult.permissionDenied,
      );
      expect(await _share(sheetFailure), ChatAttachmentShareResult.shareFailed);
    },
  );

  test('share keeps repository errors typed', () async {
    final missingCredential = ChatAttachmentExporter(
      temporaryDirectory: scratch,
      repository: _repository(
        (_) async => throw StateError('must not request'),
        withCredential: false,
      ),
      system: _RecordingSystem(),
    );
    final tooLarge = ChatAttachmentExporter(
      temporaryDirectory: scratch,
      repository: _repository(
        (_) async => http.StreamedResponse(
          const Stream.empty(),
          200,
          contentLength: 64 * 1024 * 1024 + 1,
          headers: const {'content-type': 'text/plain'},
        ),
      ),
      system: _RecordingSystem(),
    );
    final invalid = ChatAttachmentExporter(
      temporaryDirectory: scratch,
      repository: _successfulRepository(),
      system: _RecordingSystem(),
    );

    expect(
      await _share(missingCredential),
      ChatAttachmentShareResult.reauthenticationRequired,
    );
    expect(await _share(tooLarge), ChatAttachmentShareResult.tooLarge);
    expect(
      await invalid.share(
        account: _account,
        uri: Uri.parse('https://attacker.example.invalid/report.txt'),
        fileName: 'report.txt',
        expectedContentType: 'text/plain',
      ),
      ChatAttachmentShareResult.invalid,
    );
  });

  test(
    'mobile save materializes an app-private file and always removes it',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'attachment-save-test-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final saver = _RecordingMobileSaver();
      final system = PlatformChatAttachmentSystem(
        mobilePlatform: true,
        mobileSaver: saver,
        temporaryDirectory: () async => root,
      );

      final result = await system.save(
        bytes: Uint8List.fromList(utf8.encode('exact private bytes')),
        fileName: 'report.txt',
        contentType: 'text/plain',
      );

      expect(result, ChatAttachmentSystemResult.completed);
      expect(saver.fileNames, ['report.txt']);
      expect(saver.contentTypes, ['text/plain']);
      expect(saver.bytes.single, utf8.encode('exact private bytes'));
      expect(await root.list().toList(), isEmpty);
    },
  );

  test('mobile save removes its private file after a native failure', () async {
    final root = await Directory.systemTemp.createTemp(
      'attachment-save-error-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final saver = _RecordingMobileSaver(
      failure: ChatAttachmentMobileSaveFailure.permissionDenied,
    );
    final system = PlatformChatAttachmentSystem(
      mobilePlatform: true,
      mobileSaver: saver,
      temporaryDirectory: () async => root,
    );

    final result = await system.save(
      bytes: Uint8List.fromList(const [1, 2, 3]),
      fileName: 'report.bin',
      contentType: 'application/octet-stream',
    );

    expect(result, ChatAttachmentSystemResult.permissionDenied);
    expect(await root.list().toList(), isEmpty);
  });

  test(
    'mobile save removes its private file after picker cancellation',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'attachment-save-cancel-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final saver = _RecordingMobileSaver(
        result: ChatAttachmentMobileSaveResult.cancelled,
      );
      final system = PlatformChatAttachmentSystem(
        mobilePlatform: true,
        mobileSaver: saver,
        temporaryDirectory: () async => root,
      );

      final result = await system.save(
        bytes: Uint8List.fromList(const [1, 2, 3]),
        fileName: 'report.bin',
        contentType: 'application/octet-stream',
      );

      expect(result, ChatAttachmentSystemResult.cancelled);
      expect(await root.list().toList(), isEmpty);
    },
  );

  test('missing mobile cache directory is a typed storage failure', () async {
    final system = PlatformChatAttachmentSystem(
      mobilePlatform: true,
      mobileSaver: _RecordingMobileSaver(),
      temporaryDirectory: () async =>
          throw MissingPlatformDirectoryException('cache unavailable'),
    );

    final result = await system.save(
      bytes: Uint8List.fromList(const [1, 2, 3]),
      fileName: 'report.bin',
      contentType: 'application/octet-stream',
    );

    expect(result, ChatAttachmentSystemResult.storageFailed);
  });

  test('share without a reportable platform result is still offered', () async {
    final system = PlatformChatAttachmentSystem(
      mobilePlatform: false,
      shareFile: (_) async => ShareResult.unavailable,
    );

    final result = await system.share(
      bytes: Uint8List.fromList(const [1]),
      fileName: 'report.bin',
      contentType: 'application/octet-stream',
    );

    expect(result, ChatAttachmentSystemResult.offered);

    final exporter = ChatAttachmentExporter(
      temporaryDirectory: scratch,
      repository: _successfulRepository(),
      system: _RecordingSystem(shareResult: ChatAttachmentSystemResult.offered),
    );
    expect(await _share(exporter), ChatAttachmentShareResult.offered);
  });

  test('a thrown share platform failure is unavailable', () async {
    final platformFailure = PlatformChatAttachmentSystem(
      mobilePlatform: false,
      shareFile: (_) async => throw PlatformException(code: 'unavailable'),
    );
    final unsupportedDesktop = PlatformChatAttachmentSystem(
      mobilePlatform: false,
      shareFile: (_) async => throw UnimplementedError('file sharing'),
    );

    final result = await platformFailure.share(
      bytes: Uint8List.fromList(const [1]),
      fileName: 'report.bin',
      contentType: 'application/octet-stream',
    );

    expect(result, ChatAttachmentSystemResult.unavailable);
    expect(
      await unsupportedDesktop.share(
        bytes: Uint8List.fromList(const [1]),
        fileName: 'report.bin',
        contentType: 'application/octet-stream',
      ),
      ChatAttachmentSystemResult.unavailable,
    );
  });

  test('mobile saver channel sends only path, safe name, and MIME', () async {
    const channel = MethodChannel('test_attachment_mobile_saver');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return 'saved';
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final saver = MethodChannelChatAttachmentMobileSaver(
      channel: channel,
      supported: true,
    );

    final result = await saver.save(
      sourcePath: '/private/cache/export/report.pdf',
      fileName: 'report.pdf',
      contentType: 'application/pdf',
    );

    expect(result, ChatAttachmentMobileSaveResult.saved);
    expect(calls.single.method, 'save');
    expect(calls.single.arguments, {
      'sourcePath': '/private/cache/export/report.pdf',
      'fileName': 'report.pdf',
      'contentType': 'application/pdf',
    });
  });

  test(
    'mobile saver preserves native cancellation and error classes',
    () async {
      const channel = MethodChannel('test_attachment_mobile_saver_errors');
      Object? response = 'cancelled';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (response is PlatformException) throw response;
            return response;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final saver = MethodChannelChatAttachmentMobileSaver(
        channel: channel,
        supported: true,
      );

      expect(
        await saver.save(
          sourcePath: '/private/cache/report.pdf',
          fileName: 'report.pdf',
          contentType: 'application/pdf',
        ),
        ChatAttachmentMobileSaveResult.cancelled,
      );
      response = PlatformException(code: 'cancelled');
      expect(
        await saver.save(
          sourcePath: '/private/cache/report.pdf',
          fileName: 'report.pdf',
          contentType: 'application/pdf',
        ),
        ChatAttachmentMobileSaveResult.cancelled,
      );
      const failures = <String, ChatAttachmentMobileSaveFailure>{
        'permission_denied': ChatAttachmentMobileSaveFailure.permissionDenied,
        'storage_failed': ChatAttachmentMobileSaveFailure.storageFailed,
        'invalid_source': ChatAttachmentMobileSaveFailure.invalidSource,
        'too_large': ChatAttachmentMobileSaveFailure.tooLarge,
        'save_in_progress': ChatAttachmentMobileSaveFailure.inProgress,
        'unavailable': ChatAttachmentMobileSaveFailure.unavailable,
      };
      for (final entry in failures.entries) {
        response = PlatformException(code: entry.key);
        await expectLater(
          saver.save(
            sourcePath: '/private/cache/report.pdf',
            fileName: 'report.pdf',
            contentType: 'application/pdf',
          ),
          throwsA(
            isA<ChatAttachmentMobileSaveException>().having(
              (error) => error.failure,
              'failure',
              entry.value,
            ),
          ),
        );
      }
    },
  );

  test('platform errors classify permission separately from storage', () {
    expect(
      chatAttachmentStorageErrorResult(
        PlatformException(code: 'permission_denied'),
      ),
      ChatAttachmentSystemResult.permissionDenied,
    );
    expect(
      chatAttachmentStorageErrorResult(
        const FileSystemException('denied', '', OSError('', 13)),
      ),
      ChatAttachmentSystemResult.permissionDenied,
    );
    expect(
      chatAttachmentStorageErrorResult(PlatformException(code: 'disk_full')),
      ChatAttachmentSystemResult.storageFailed,
    );
  });
}

Future<ChatAttachmentSaveResult> _save(ChatAttachmentExporter exporter) {
  return exporter.save(
    account: _account,
    uri: _uri,
    fileName: 'report.txt',
    expectedContentType: 'text/plain',
  );
}

Future<ChatAttachmentShareResult> _share(ChatAttachmentExporter exporter) {
  return exporter.share(
    account: _account,
    uri: _uri,
    fileName: 'report.txt',
    expectedContentType: 'text/plain',
  );
}

ChatMediaRepository _successfulRepository({String contentType = 'text/plain'}) {
  return _repository(
    (_) async => http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('exact bytes')),
      200,
      headers: {'content-type': contentType},
    ),
  );
}

ChatMediaRepository _repository(
  Future<http.StreamedResponse> Function(http.BaseRequest request) handler, {
  bool withCredential = true,
}) {
  final vault = MemoryCredentialVault();
  if (withCredential) {
    vault.values[_account.id] = 'fixture-app-password';
  }
  return ChatMediaRepository(vault, client: _StreamingClient(handler));
}

final class _RecordingMobileSaver implements ChatAttachmentMobileSaver {
  _RecordingMobileSaver({
    this.failure,
    this.result = ChatAttachmentMobileSaveResult.saved,
  });

  final ChatAttachmentMobileSaveFailure? failure;
  final ChatAttachmentMobileSaveResult result;
  final List<String> fileNames = [];
  final List<String> contentTypes = [];
  final List<List<int>> bytes = [];

  @override
  Future<ChatAttachmentMobileSaveResult> save({
    required String sourcePath,
    required String fileName,
    required String contentType,
  }) async {
    fileNames.add(fileName);
    contentTypes.add(contentType);
    bytes.add(await File(sourcePath).readAsBytes());
    final failure = this.failure;
    if (failure != null) {
      throw ChatAttachmentMobileSaveException(failure);
    }
    return result;
  }
}

final class _DelayedMobileSaver implements ChatAttachmentMobileSaver {
  final opened = Completer<String>();
  final destinationChosen = Completer<void>();
  bool copied = false;

  @override
  Future<ChatAttachmentMobileSaveResult> save({
    required String sourcePath,
    required String fileName,
    required String contentType,
  }) async {
    opened.complete(sourcePath);
    await destinationChosen.future;
    await File(sourcePath).readAsBytes();
    copied = true;
    return ChatAttachmentMobileSaveResult.saved;
  }
}

final class _RecordingSystem implements ChatAttachmentSystem {
  _RecordingSystem({
    this.saveResult = ChatAttachmentSystemResult.completed,
    this.shareResult = ChatAttachmentSystemResult.completed,
  });

  final ChatAttachmentSystemResult saveResult;
  final ChatAttachmentSystemResult shareResult;
  final List<List<int>> savedBytes = [];
  final List<String> savedNames = [];
  final List<String> savedTypes = [];
  final List<String> sharedNames = [];
  final List<String> sharedTypes = [];

  @override
  Future<ChatAttachmentSystemResult> save({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    savedBytes.add(List<int>.from(bytes));
    savedNames.add(fileName);
    savedTypes.add(contentType);
    return saveResult;
  }

  @override
  Future<ChatAttachmentSystemResult> saveFile({
    required File source,
    required String fileName,
    required String contentType,
    bool Function()? canExport,
  }) async {
    savedBytes.add(await source.readAsBytes());
    savedNames.add(fileName);
    savedTypes.add(contentType);
    return saveResult;
  }

  @override
  Future<ChatAttachmentSystemResult> share({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    sharedNames.add(fileName);
    sharedTypes.add(contentType);
    return shareResult;
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
