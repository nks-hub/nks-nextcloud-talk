import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/remote_file_share_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'test_support.dart';

const String _server = 'https://cloud.example.invalid';

const String _listingXml = '''
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/fixture-user/Documents/</d:href>
    <d:propstat>
      <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/fixture-user/Documents/report.pdf</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:getcontentlength>17</d:getcontentlength>
        <d:getcontenttype>application/pdf</d:getcontenttype>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault();
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: _server,
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    vault.values['account-a'] = 'fixture-app-password-never-use';
  });

  tearDown(() => database.close());

  RemoteFileShareService serviceWith(MockClientHandler handler) {
    final api = HttpNextcloudApi(client: MockClient(handler));
    addTearDown(api.close);
    return HttpRemoteFileShareService(
      accounts: accounts,
      credentials: vault,
      api: api,
    );
  }

  test('lists one directory of the account own storage', () async {
    final requests = <http.Request>[];
    final service = serviceWith((request) async {
      requests.add(request);
      return http.Response(_listingXml, 207);
    });

    final listing = await service.listDirectory(
      accountId: 'account-a',
      path: 'Documents',
    );

    expect(requests.single.method, 'PROPFIND');
    expect(
      requests.single.url.toString(),
      '$_server/remote.php/dav/files/fixture-user/Documents',
    );
    expect(requests.single.headers['Depth'], '1');
    expect(requests.single.headers['Authorization'], startsWith('Basic '));
    // The listed directory itself is not one of its own children.
    expect(listing.entries.map((entry) => entry.name), <String>['report.pdf']);
    expect(listing.entries.single.path, 'Documents/report.pdf');
  });

  test('shares the picked file into the room without uploading it', () async {
    final requests = <http.Request>[];
    final service = serviceWith((request) async {
      requests.add(request);
      return http.Response(
        jsonEncode({
          'ocs': {
            'meta': {'statuscode': 100},
            'data': {'id': '7'},
          },
        }),
        200,
      );
    });

    await service.shareIntoRoom(
      accountId: 'account-a',
      roomToken: 'room1234',
      path: 'Documents/report.pdf',
    );

    final request = requests.single;
    expect(request.method, 'POST');
    expect(request.url.path, '/ocs/v2.php/apps/files_sharing/api/v1/shares');
    // Share type 10 is the conversation itself: no public link is created and
    // nothing is uploaded.
    expect(
      request.body,
      'shareType=10&shareWith=room1234&path=%2FDocuments%2Freport.pdf',
    );
  });

  test('an OCS failure inside an HTTP 200 is not reported as shared', () async {
    final service = serviceWith(
      (_) async => http.Response(
        jsonEncode({
          'ocs': {
            'meta': {'statuscode': 403},
            'data': <String, Object?>{},
          },
        }),
        200,
      ),
    );

    await expectLater(
      service.shareIntoRoom(
        accountId: 'account-a',
        roomToken: 'room1234',
        path: 'report.pdf',
      ),
      throwsA(
        isA<RemoteFileException>().having(
          (failure) => failure.code,
          'code',
          RemoteFileError.forbidden,
        ),
      ),
    );
  });

  test('maps the refusals a server can answer with', () async {
    Future<void> expectCode(int status, RemoteFileError code) async {
      final service = serviceWith((_) async => http.Response('', status));
      await expectLater(
        service.listDirectory(accountId: 'account-a', path: ''),
        throwsA(
          isA<RemoteFileException>().having(
            (failure) => failure.code,
            'code',
            code,
          ),
        ),
        reason: '$status',
      );
    }

    await expectCode(401, RemoteFileError.reauthenticationRequired);
    await expectCode(404, RemoteFileError.unavailable);
    await expectCode(503, RemoteFileError.serviceUnavailable);
  });

  test('never reaches the network without a stored credential', () async {
    vault.values.remove('account-a');
    var called = false;
    final service = serviceWith((_) async {
      called = true;
      return http.Response('', 207);
    });

    await expectLater(
      service.listDirectory(accountId: 'account-a', path: ''),
      throwsA(
        isA<RemoteFileException>().having(
          (failure) => failure.code,
          'code',
          RemoteFileError.credentialMissing,
        ),
      ),
    );
    expect(called, isFalse);
  });

  test('refuses a path that would leave the account storage', () async {
    var called = false;
    final service = serviceWith((_) async {
      called = true;
      return http.Response(_listingXml, 207);
    });

    await expectLater(
      service.listDirectory(accountId: 'account-a', path: '../other-user'),
      throwsA(
        isA<RemoteFileException>().having(
          (failure) => failure.code,
          'code',
          RemoteFileError.invalidInput,
        ),
      ),
    );
    expect(called, isFalse);
  });
}
