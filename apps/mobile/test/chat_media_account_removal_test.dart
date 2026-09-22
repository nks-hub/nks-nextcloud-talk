import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';
import 'package:nextcloudtalk/data/credential_vault.dart';
import 'package:nextcloudtalk/features/chat/media/chat_attachment_exporter.dart';
import 'package:nextcloudtalk/features/chat/media/chat_attachment_opener.dart';

import 'test_support.dart';

void main() {
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('media-stop-'),
  );
  tearDown(() => root.delete(recursive: true));

  test('logout during credential lookup cannot send a late request', () async {
    final vault = _DelayedVault();
    var requests = 0;
    final repository = ChatMediaRepository(
      vault,
      client: _Client((request) async {
        requests++;
        return _response(Stream.value([1]));
      }),
    );
    final target = File('${root.path}/report.txt');
    final download = _download(repository, target);
    final failed = expectLater(
      download,
      throwsA(isA<ChatMediaRepositoryException>()),
    );
    await vault.started.future;
    await repository.suspendAccount(_account.id);
    await failed;
    vault.password.complete('old-password');
    await pumpEventQueue();
    expect(requests, 0);
    expect(await target.exists(), isFalse);
  });

  test(
    'logout cancels a body and removes its partial file only for that account',
    () async {
      var cancelled = false;
      final received = Completer<void>();
      final body = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      body.add([1, 2]);
      final repository = ChatMediaRepository(
        MemoryCredentialVault()
          ..values[_account.id] = 'password-a'
          ..values['account-b'] = 'password-b',
        client: _Client(
          (request) async => _response(
            request.url.path.endsWith('first.txt')
                ? body.stream
                : Stream.value([3, 4]),
          ),
        ),
      );
      final first = File('${root.path}/first.txt');
      final failed = expectLater(
        repository.downloadOriginalToFile(
          account: _account,
          uri: _uri.resolve('first.txt'),
          expectedContentType: 'text/plain',
          target: first,
          onProgress: (bytes, _) {
            if (bytes > 0 && !received.isCompleted) received.complete();
          },
        ),
        throwsA(isA<ChatMediaRepositoryException>()),
      );
      await received.future;
      await repository.suspendAccount(_account.id);
      await failed;
      await body.close();
      expect(cancelled, isTrue);
      expect(await first.exists(), isFalse);
      final second = File('${root.path}/second.txt');
      await _download(
        repository,
        second,
        account: _account.copyWith(id: 'account-b'),
      );
      expect(await second.readAsBytes(), [3, 4]);
    },
  );

  test(
    'logout before export never opens the save dialog and clears scratch',
    () async {
      var dialogs = 0;
      final repository = ChatMediaRepository(
        MemoryCredentialVault()..values[_account.id] = 'password',
        client: _Client((request) async => _response(Stream.value([1, 2]))),
      );
      final exporter = ChatAttachmentExporter(
        repository: repository,
        temporaryDirectory: () async => root,
        system: PlatformChatAttachmentSystem(
          mobilePlatform: false,
          saveLocationPicker: ({suggestedName}) async {
            dialogs++;
            return FileSaveLocation('${root.path}/saved.txt');
          },
        ),
      );
      final result = await exporter.save(
        account: _account,
        uri: _uri,
        fileName: 'report.txt',
        expectedContentType: 'text/plain',
        onProgress: (bytes, _) {
          if (bytes > 0) unawaited(repository.suspendAccount(_account.id));
        },
      );
      expect(result, isNot(ChatAttachmentSaveResult.saved));
      expect(dialogs, 0);
      final accountDirectory = chatAttachmentCacheAccountDirectory(
        rootDirectory: root,
        accountId: _account.id,
      );
      expect(await accountDirectory.list().toList(), isEmpty);
    },
  );

  test(
    'logout while the save dialog is open prevents the later copy',
    () async {
      final source = File('${root.path}/source.txt');
      await source.writeAsString('private');
      final destination = File('${root.path}/destination.txt');
      final chosen = Completer<FileSaveLocation?>();
      final opened = Completer<void>();
      var active = true;
      final system = PlatformChatAttachmentSystem(
        mobilePlatform: false,
        saveLocationPicker: ({suggestedName}) {
          opened.complete();
          return chosen.future;
        },
      );
      final save = system.saveFile(
        source: source,
        fileName: 'source.txt',
        contentType: 'text/plain',
        canExport: () => active,
      );
      await opened.future;
      active = false;
      chosen.complete(FileSaveLocation(destination.path));
      expect(await save, ChatAttachmentSystemResult.cancelled);
      expect(await destination.exists(), isFalse);
    },
  );
}

Future<String> _download(
  ChatMediaRepository repository,
  File target, {
  StoredAccount account = _account,
}) => repository.downloadOriginalToFile(
  account: account,
  uri: _uri,
  expectedContentType: 'text/plain',
  target: target,
);

http.StreamedResponse _response(Stream<List<int>> body) =>
    http.StreamedResponse(body, 200, headers: {'content-type': 'text/plain'});

final class _Client extends http.BaseClient {
  _Client(this.sendRequest);
  final Future<http.StreamedResponse> Function(http.BaseRequest) sendRequest;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      sendRequest(request);
}

final class _DelayedVault implements CredentialVault {
  final started = Completer<void>();
  final password = Completer<String?>();
  @override
  Future<String?> readAppPassword(String accountId) {
    started.complete();
    return password.future;
  }

  @override
  Future<void> writeAppPassword(String accountId, String value) async {}
  @override
  Future<void> deleteAppPassword(String accountId) async {}
}

const _account = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: true,
  createdAtMillis: 1767225600000,
);
final _uri = Uri.parse(
  '${_account.serverUrl}/remote.php/dav/files/fixture-user/Talk/report.txt',
);
