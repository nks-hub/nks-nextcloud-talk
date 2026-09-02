import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';

import 'test_support.dart';

void main() {
  test('loads an account-scoped preview with bounded authorization', () async {
    late http.BaseRequest captured;
    final vault = MemoryCredentialVault()
      ..values[_account.id] = 'fixture-app-password';
    final repository = ChatMediaRepository(
      vault,
      client: _StreamingClient((request) async {
        captured = request;
        return http.StreamedResponse(
          Stream<List<int>>.value(_pngSignature),
          200,
          headers: const <String, String>{'content-type': 'image/png'},
        );
      }),
    );

    final image = await repository.loadPreview(
      account: _account,
      uri: _previewUri,
    );

    expect(image, isNotNull);
    expect(image!.contentType, 'image/png');
    expect(image.body, _pngSignature);
    expect(captured.url, _previewUri);
    expect(captured.followRedirects, isFalse);
    expect(captured.maxRedirects, 0);
    expect(
      captured.headers['Authorization'],
      'Basic ${base64Encode(utf8.encode('fixture-user:fixture-app-password'))}',
    );
  });

  test('times out while a successful response body stalls', () async {
    final responseBody = StreamController<List<int>>();
    addTearDown(responseBody.close);
    final vault = MemoryCredentialVault()
      ..values[_account.id] = 'fixture-app-password';
    final repository = ChatMediaRepository(
      vault,
      requestTimeout: const Duration(milliseconds: 20),
      client: _StreamingClient(
        (_) async => http.StreamedResponse(
          responseBody.stream,
          200,
          headers: const <String, String>{'content-type': 'image/png'},
        ),
      ),
    );

    await expectLater(
      repository.loadPreview(account: _account, uri: _previewUri),
      throwsA(
        isA<ChatMediaRepositoryException>().having(
          (error) => error.code,
          'code',
          ChatMediaRepositoryError.unavailable,
        ),
      ),
    );
  });

  test('enforces a total body deadline while bytes keep arriving', () async {
    final responseBody = StreamController<List<int>>();
    final timer = Timer.periodic(
      const Duration(milliseconds: 5),
      (_) => responseBody.add(const <int>[0]),
    );
    addTearDown(() async {
      timer.cancel();
      await responseBody.close();
    });
    final vault = MemoryCredentialVault()
      ..values[_account.id] = 'fixture-app-password';
    final repository = ChatMediaRepository(
      vault,
      requestTimeout: const Duration(milliseconds: 30),
      client: _StreamingClient(
        (_) async => http.StreamedResponse(
          responseBody.stream,
          200,
          headers: const <String, String>{'content-type': 'image/png'},
        ),
      ),
    );

    await expectLater(
      repository.loadPreview(account: _account, uri: _previewUri),
      throwsA(
        isA<ChatMediaRepositoryException>().having(
          (error) => error.code,
          'code',
          ChatMediaRepositoryError.unavailable,
        ),
      ),
    );
  });

  test(
    'rejects an oversized streaming response without content length',
    () async {
      final vault = MemoryCredentialVault()
        ..values[_account.id] = 'fixture-app-password';
      final repository = ChatMediaRepository(
        vault,
        client: _StreamingClient(
          (_) async => http.StreamedResponse(
            Stream<List<int>>.value(Uint8List(8 * 1024 * 1024 + 1)),
            200,
            headers: const <String, String>{'content-type': 'image/png'},
          ),
        ),
      );

      await expectLater(
        repository.loadPreview(account: _account, uri: _previewUri),
        throwsA(
          isA<ChatMediaRepositoryException>().having(
            (error) => error.code,
            'code',
            ChatMediaRepositoryError.responseTooLarge,
          ),
        ),
      );
    },
  );

  test('rejects previews outside the account origin before dispatch', () async {
    var dispatchCount = 0;
    final vault = MemoryCredentialVault()
      ..values[_account.id] = 'fixture-app-password';
    final repository = ChatMediaRepository(
      vault,
      client: _StreamingClient((_) async {
        dispatchCount++;
        return http.StreamedResponse(const Stream<List<int>>.empty(), 200);
      }),
    );

    await expectLater(
      repository.loadPreview(
        account: _account,
        uri: Uri.parse(
          'https://other.example.invalid/index.php/core/preview'
          '?fileId=42&x=2048&y=2048&a=0',
        ),
      ),
      throwsA(
        isA<ChatMediaRepositoryException>().having(
          (error) => error.code,
          'code',
          ChatMediaRepositoryError.invalidUri,
        ),
      ),
    );
    expect(dispatchCount, 0);
  });

  group('original attachment download', () {
    test('reports cumulative progress against the declared length', () async {
      final vault = MemoryCredentialVault()
        ..values[_account.id] = 'fixture-app-password';
      final body = <int>[..._pngSignature, 1, 2, 3];
      final repository = ChatMediaRepository(
        vault,
        client: _StreamingClient((_) async {
          return http.StreamedResponse(
            Stream<List<int>>.fromIterable(<List<int>>[
              body.sublist(0, 4),
              body.sublist(4),
            ]),
            200,
            contentLength: body.length,
            headers: const <String, String>{'content-type': 'image/png'},
          );
        }),
      );

      final reported = <({int received, int? total})>[];
      await repository.loadOriginalFile(
        account: _account,
        uri: _originalUri,
        expectedContentType: 'image/png',
        onProgress: (received, total) =>
            reported.add((received: received, total: total)),
      );

      expect(reported.first, (received: 0, total: body.length));
      expect(reported.last, (received: body.length, total: body.length));
      expect(reported.map((entry) => entry.received).toList(), <int>[
        0,
        4,
        body.length,
      ]);
    });

    test('a server that declares no length reports a null total', () async {
      final vault = MemoryCredentialVault()
        ..values[_account.id] = 'fixture-app-password';
      final repository = ChatMediaRepository(
        vault,
        client: _StreamingClient((_) async {
          return http.StreamedResponse(
            Stream<List<int>>.value(<int>[..._pngSignature, 1, 2, 3]),
            200,
            headers: const <String, String>{'content-type': 'image/png'},
          );
        }),
      );

      final totals = <int?>[];
      await repository.loadOriginalFile(
        account: _account,
        uri: _originalUri,
        expectedContentType: 'image/png',
        onProgress: (_, total) => totals.add(total),
      );

      expect(totals, everyElement(isNull));
      expect(totals, isNotEmpty);
    });

    test('returns authenticated original bytes from this account DAV', () async {
      late http.BaseRequest captured;
      final vault = MemoryCredentialVault()
        ..values[_account.id] = 'fixture-app-password';
      final repository = ChatMediaRepository(
        vault,
        client: _StreamingClient((request) async {
          captured = request;
          return http.StreamedResponse(
            Stream<List<int>>.value(<int>[..._pngSignature, 1, 2, 3]),
            200,
            headers: const <String, String>{'content-type': 'image/png'},
          );
        }),
      );

      final file = await repository.loadOriginalFile(
        account: _account,
        uri: _originalUri,
        expectedContentType: 'image/png',
      );

      expect(file.body, <int>[..._pngSignature, 1, 2, 3]);
      expect(file.contentType, 'image/png');
      expect(captured.url, _originalUri);
      expect(captured.followRedirects, isFalse);
      expect(captured.maxRedirects, 0);
      expect(
        captured.headers['Authorization'],
        'Basic ${base64Encode(utf8.encode('fixture-user:fixture-app-password'))}',
      );
    });

    test(
      'rejects another origin and another account DAV user before dispatch',
      () async {
        var dispatchCount = 0;
        final vault = MemoryCredentialVault()
          ..values[_account.id] = 'fixture-app-password';
        final repository = ChatMediaRepository(
          vault,
          client: _StreamingClient((_) async {
            dispatchCount++;
            return http.StreamedResponse(const Stream<List<int>>.empty(), 200);
          }),
        );

        for (final uri in <Uri>[
          Uri.parse(
            'https://other.example.invalid/remote.php/dav/files/'
            'fixture-user/Talk/photo.png',
          ),
          Uri.parse(
            'https://cloud.example.invalid/remote.php/dav/files/'
            'other-user/Talk/photo.png',
          ),
          Uri.parse(
            'https://cloud.example.invalid/remote.php/dav/files/'
            'fixture-user/Talk/photo.png?download=1',
          ),
        ]) {
          await expectLater(
            repository.loadOriginalFile(
              account: _account,
              uri: uri,
              expectedContentType: 'image/png',
            ),
            throwsA(
              isA<ChatMediaRepositoryException>().having(
                (error) => error.code,
                'code',
                ChatMediaRepositoryError.invalidUri,
              ),
            ),
          );
        }
        expect(dispatchCount, 0);
      },
    );

    test('never borrows credentials from another account', () async {
      var dispatchCount = 0;
      final vault = MemoryCredentialVault()
        ..values[_account.id] = 'fixture-app-password';
      final repository = ChatMediaRepository(
        vault,
        client: _StreamingClient((_) async {
          dispatchCount++;
          return http.StreamedResponse(const Stream<List<int>>.empty(), 200);
        }),
      );

      await expectLater(
        repository.loadOriginalFile(
          account: _accountB,
          uri: _originalUri,
          expectedContentType: 'image/png',
        ),
        throwsA(
          isA<ChatMediaRepositoryException>().having(
            (error) => error.code,
            'code',
            ChatMediaRepositoryError.credentialMissing,
          ),
        ),
      );
      expect(dispatchCount, 0);
    });

    test(
      'rejects an HTML response instead of exporting a login page',
      () async {
        final vault = MemoryCredentialVault()
          ..values[_account.id] = 'fixture-app-password';
        final repository = ChatMediaRepository(
          vault,
          client: _StreamingClient(
            (_) async => http.StreamedResponse(
              Stream<List<int>>.value(utf8.encode('<html>login</html>')),
              200,
              headers: const <String, String>{'content-type': 'text/html'},
            ),
          ),
        );

        await expectLater(
          repository.loadOriginalFile(
            account: _account,
            uri: _originalUri,
            expectedContentType: 'image/png',
          ),
          throwsA(
            isA<ChatMediaRepositoryException>().having(
              (error) => error.code,
              'code',
              ChatMediaRepositoryError.invalidResponse,
            ),
          ),
        );
      },
    );

    test('reports a failed download without returning partial bytes', () async {
      final vault = MemoryCredentialVault()
        ..values[_account.id] = 'fixture-app-password';
      final repository = ChatMediaRepository(
        vault,
        client: _StreamingClient(
          (_) async => http.StreamedResponse(
            Stream<List<int>>.value(const <int>[1, 2, 3]),
            503,
          ),
        ),
      );

      await expectLater(
        repository.loadOriginalFile(
          account: _account,
          uri: _originalUri,
          expectedContentType: 'image/png',
        ),
        throwsA(
          isA<ChatMediaRepositoryException>().having(
            (error) => error.code,
            'code',
            ChatMediaRepositoryError.unavailable,
          ),
        ),
      );
    });

    test('rejects an oversized original from content length', () async {
      final vault = MemoryCredentialVault()
        ..values[_account.id] = 'fixture-app-password';
      final repository = ChatMediaRepository(
        vault,
        client: _StreamingClient(
          (_) async => http.StreamedResponse(
            const Stream<List<int>>.empty(),
            200,
            contentLength: 64 * 1024 * 1024 + 1,
            headers: const <String, String>{'content-type': 'image/png'},
          ),
        ),
      );

      await expectLater(
        repository.loadOriginalFile(
          account: _account,
          uri: _originalUri,
          expectedContentType: 'image/png',
        ),
        throwsA(
          isA<ChatMediaRepositoryException>().having(
            (error) => error.code,
            'code',
            ChatMediaRepositoryError.responseTooLarge,
          ),
        ),
      );
    });
  });
}

final class _StreamingClient extends http.BaseClient {
  _StreamingClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _handler(request);
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

const StoredAccount _accountB = StoredAccount(
  id: 'account-b',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: false,
  createdAtMillis: 1767225600000,
);

final Uri _previewUri = Uri.parse(
  'https://cloud.example.invalid/index.php/core/preview'
  '?fileId=42&x=2048&y=2048&a=0',
);

final Uri _originalUri = Uri.parse(
  'https://cloud.example.invalid/remote.php/dav/files/'
  'fixture-user/Talk/photo.png',
);

final Uint8List _pngSignature = Uint8List.fromList(const <int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
]);
