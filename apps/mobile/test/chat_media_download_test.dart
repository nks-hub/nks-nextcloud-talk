import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';

import 'test_support.dart';

void main() {
  late Directory directory;
  late File target;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('chat-download-');
    target = File('${directory.path}${Platform.pathSeparator}report.txt');
  });
  tearDown(() => directory.delete(recursive: true));

  test('writes complete chunks to disk and reports progress', () async {
    final progress = <int>[];
    final repository = _repository(
      Stream.fromIterable([
        [1, 2],
        [3, 4],
      ]),
      length: 4,
    );
    final type = await repository.downloadOriginalToFile(
      account: _account,
      uri: _uri,
      expectedContentType: 'text/plain',
      target: target,
      onProgress: (received, total) {
        progress.add(received);
        expect(total, 4);
      },
    );
    expect(type, 'text/plain');
    expect(await target.readAsBytes(), [1, 2, 3, 4]);
    expect(progress, [0, 2, 4]);
  });

  test('a stalled body is cancelled and its partial file is removed', () async {
    var cancelled = false;
    final body = StreamController<List<int>>(onCancel: () => cancelled = true);
    final finish = Timer(const Duration(milliseconds: 300), () => body.close());
    addTearDown(() async {
      finish.cancel();
      await body.close();
    });
    body.add([1, 2]);
    final repository = _repository(
      body.stream,
      timeout: const Duration(milliseconds: 30),
    );

    await expectLater(
      _download(repository, target),
      throwsA(_failure(ChatMediaRepositoryError.unavailable)),
    );
    expect(cancelled, isTrue);
    expect(await target.exists(), isFalse);
  });

  test('a broken response does not leave a partial attachment', () async {
    final body = StreamController<List<int>>();
    body.add([1, 2]);
    body.addError(http.ClientException('connection closed'));
    unawaited(body.close());
    await expectLater(
      _download(_repository(body.stream), target),
      throwsA(_failure(ChatMediaRepositoryError.unavailable)),
    );
    expect(await target.exists(), isFalse);
  });

  test('an undeclared oversized body is cancelled and removed', () async {
    var cancelled = false;
    final body = StreamController<List<int>>(onCancel: () => cancelled = true);
    body.add([1, 2]);
    body.add([3, 4]);
    unawaited(body.close());
    await expectLater(
      _repository(body.stream).downloadOriginalToFile(
        account: _account,
        uri: _uri,
        expectedContentType: 'text/plain',
        target: target,
        maximumBytes: 3,
      ),
      throwsA(_failure(ChatMediaRepositoryError.responseTooLarge)),
    );
    expect(cancelled, isTrue);
    expect(await target.exists(), isFalse);
  });

  test('an incomplete declared body is not accepted as a saved file', () async {
    await expectLater(
      _download(_repository(Stream.value([1, 2]), length: 4), target),
      throwsA(_failure(ChatMediaRepositoryError.invalidResponse)),
    );
    expect(await target.exists(), isFalse);
  });

  test('an unwritable destination reports a storage error', () async {
    await expectLater(
      _download(_repository(Stream.value([1, 2])), File(directory.path)),
      throwsA(isA<FileSystemException>()),
    );
    expect(await directory.exists(), isTrue);
  });
}

Future<String> _download(ChatMediaRepository repository, File target) =>
    repository.downloadOriginalToFile(
      account: _account,
      uri: _uri,
      expectedContentType: 'text/plain',
      target: target,
    );

Matcher _failure(ChatMediaRepositoryError code) =>
    isA<ChatMediaRepositoryException>().having(
      (error) => error.code,
      'code',
      code,
    );

ChatMediaRepository _repository(
  Stream<List<int>> body, {
  int? length,
  Duration timeout = const Duration(seconds: 2),
}) => ChatMediaRepository(
  MemoryCredentialVault()..values[_account.id] = 'fixture-app-password',
  requestTimeout: timeout,
  client: _StreamingClient(
    http.StreamedResponse(
      body,
      200,
      contentLength: length,
      headers: {'content-type': 'text/plain'},
    ),
  ),
);

final class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.response);

  final http.StreamedResponse response;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response;
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
