import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';
import 'package:nextcloudtalk/features/chat/media/chat_attachment_exporter.dart';

import 'test_support.dart';

void main() {
  test('save uses authenticated bytes, safe name, and received MIME', () async {
    late http.BaseRequest request;
    final system = _RecordingSystem();
    final exporter = ChatAttachmentExporter(
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

  test('save cancellation is not reported as a storage failure', () async {
    final system = _RecordingSystem(
      saveResult: ChatAttachmentSystemResult.cancelled,
    );
    final exporter = ChatAttachmentExporter(
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
    'save keeps download, permission, and storage failures distinct',
    () async {
      final downloadFailure = ChatAttachmentExporter(
        repository: _repository(
          (_) async => http.StreamedResponse(const Stream.empty(), 503),
        ),
        system: _RecordingSystem(),
      );
      final permissionFailure = ChatAttachmentExporter(
        repository: _successfulRepository(),
        system: _RecordingSystem(
          saveResult: ChatAttachmentSystemResult.permissionDenied,
        ),
      );
      final storageFailure = ChatAttachmentExporter(
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
    },
  );

  test('share uses safe name and actual MIME from the DAV response', () async {
    final system = _RecordingSystem();
    final exporter = ChatAttachmentExporter(
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
        repository: _successfulRepository(),
        system: _RecordingSystem(
          shareResult: ChatAttachmentSystemResult.cancelled,
        ),
      );
      final downloadFailure = ChatAttachmentExporter(
        repository: _repository(
          (_) async => http.StreamedResponse(const Stream.empty(), 404),
        ),
        system: _RecordingSystem(),
      );
      final permissionFailure = ChatAttachmentExporter(
        repository: _successfulRepository(),
        system: _RecordingSystem(
          shareResult: ChatAttachmentSystemResult.permissionDenied,
        ),
      );
      final sheetFailure = ChatAttachmentExporter(
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
  Future<http.StreamedResponse> Function(http.BaseRequest request) handler,
) {
  final vault = MemoryCredentialVault()
    ..values[_account.id] = 'fixture-app-password';
  return ChatMediaRepository(vault, client: _StreamingClient(handler));
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
