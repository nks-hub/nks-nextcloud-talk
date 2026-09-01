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
  });

  test(
    'preserves authentication, size, invalid, and storage failures',
    () async {
      final missingCredential = ChatAttachmentOpener(
        repository: ChatMediaRepository(
          MemoryCredentialVault(),
          client: _StreamingClient(
            (_) async => throw StateError('must not request'),
          ),
        ),
        launcher: _RecordingLauncher(),
      );
      final tooLarge = ChatAttachmentOpener(
        repository: _repository(
          (_) async => http.StreamedResponse(
            const Stream.empty(),
            200,
            contentLength: 64 * 1024 * 1024 + 1,
            headers: const {'content-type': 'text/plain'},
          ),
        ),
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
