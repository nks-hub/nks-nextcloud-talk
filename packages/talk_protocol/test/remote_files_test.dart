import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  final server = ServerBase.parse('https://cloud.example.invalid');
  final subdirectoryServer = ServerBase.parse(
    'https://host.example.invalid/nextcloud',
  );
  final account = AccountId.parse('account-a');
  final room = ConversationToken.parse('room1234', path: r'$.token');

  RemoteDirectoryRequest listing({String path = '', ServerBase? base}) =>
      RemoteDirectoryRequest(
        accountId: account,
        server: base ?? server,
        loginName: 'fixture-user',
        path: path,
      );

  group('directory request', () {
    test('asks one level of the account own files root', () {
      final request = listing(path: 'Documents/Notes');

      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/remote.php/dav/files/fixture-user'
        '/Documents/Notes',
      );
      expect(request.httpMethod, 'PROPFIND');
      expect(request.headers['Depth'], '1');
      expect(utf8.decode(request.bodyBytes), contains('<nc:has-preview/>'));
    });

    test('keeps a subdirectory install in the path', () {
      expect(
        listing(base: subdirectoryServer).uri.toString(),
        'https://host.example.invalid/nextcloud/remote.php/dav/files/'
        'fixture-user',
      );
    });

    test('refuses a path that could leave the account storage', () {
      for (final path in const <String>[
        '../other-user',
        'Documents/../../etc',
        'Documents/./secret',
        r'Documents\\Windows',
      ]) {
        expect(
          () => listing(path: path),
          throwsA(isA<TalkProtocolException>()),
          reason: path,
        );
      }
    });

    test('normalises the separators a picker can produce', () {
      expect(listing(path: '/Documents/Notes/').path, 'Documents/Notes');
      expect(listing(path: '//').path, '');
    });
  });

  group('directory response', () {
    RemoteDirectoryResponse decode(
      String xml, {
      int statusCode = 207,
      String path = '',
    }) => decodeRemoteDirectoryResponse(
      request: listing(path: path),
      statusCode: statusCode,
      body: Uint8List.fromList(utf8.encode(xml)),
    );

    const multistatus = '''
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/fixture-user/</d:href>
    <d:propstat>
      <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/fixture-user/photo%20one.jpg</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:getcontentlength>2048</d:getcontentlength>
        <d:getcontenttype>image/jpeg</d:getcontenttype>
        <d:getlastmodified>Tue, 01 Sep 2026 10:11:12 GMT</d:getlastmodified>
        <nc:has-preview>true</nc:has-preview>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/fixture-user/Archive/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <nc:has-preview>false</nc:has-preview>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
    <d:propstat>
      <d:prop><d:getcontenttype/></d:prop>
      <d:status>HTTP/1.1 404 Not Found</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/other-user/theirs.txt</d:href>
    <d:propstat>
      <d:prop><d:resourcetype/></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

    test('reads children, drops the directory itself and foreign roots', () {
      final response = decode(multistatus);
      final entries = response.listing!.entries;

      expect(response.outcome, RemoteDirectoryOutcome.listed);
      expect(response.truncated, isFalse);
      // Directories first, then by name; the listed directory and another
      // account's storage are both absent.
      expect(entries.map((entry) => entry.path), <String>[
        'Archive',
        'photo one.jpg',
      ]);
      expect(entries.first.isDirectory, isTrue);
      expect(entries.first.sizeBytes, isNull);

      final file = entries.last;
      expect(file.name, 'photo one.jpg');
      expect(file.isDirectory, isFalse);
      expect(file.sizeBytes, 2048);
      expect(file.mimeType, 'image/jpeg');
      expect(file.hasPreview, isTrue);
      expect(file.lastModified, DateTime.utc(2026, 9, 1, 10, 11, 12));
    });

    test('a property the server could not read is simply absent', () {
      final archive = decode(
        multistatus,
      ).listing!.entries.firstWhere((entry) => entry.name == 'Archive');

      expect(archive.mimeType, isNull);
      expect(archive.hasPreview, isFalse);
    });

    test('classifies the answers that are not a listing', () {
      expect(
        decode('', statusCode: 401).outcome,
        RemoteDirectoryOutcome.reauthenticationRequired,
      );
      expect(
        decode('', statusCode: 404).outcome,
        RemoteDirectoryOutcome.unavailable,
      );
      expect(
        decode('', statusCode: 503).outcome,
        RemoteDirectoryOutcome.transientError,
      );
      expect(
        () => decode('', statusCode: 500),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test(
      'a body that is not XML is a protocol failure, never an empty list',
      () {
        expect(
          () => decode('{"not":"xml"}'),
          throwsA(isA<TalkProtocolException>()),
        );
      },
    );

    test('stops at the entry cap and says so', () {
      final buffer = StringBuffer(
        '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">',
      );
      for (var index = 0; index < remoteFilesMaximumEntries + 10; index++) {
        buffer.write(
          '<d:response><d:href>/remote.php/dav/files/fixture-user/'
          'file$index.txt</d:href><d:propstat><d:prop><d:resourcetype/>'
          '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
          '</d:response>',
        );
      }
      buffer.write('</d:multistatus>');

      final response = decode(buffer.toString());

      expect(response.listing!.entries, hasLength(remoteFilesMaximumEntries));
      expect(response.truncated, isTrue);
    });
  });

  group('share request', () {
    test('shares into the room instead of creating a public link', () {
      final request = RemoteFileShareRequest(
        accountId: account,
        server: server,
        roomToken: room,
        path: 'Documents/report.pdf',
      );

      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/files_sharing/api/v1/'
        'shares?format=json',
      );
      expect(request.formFields['shareType'], '10');
      expect(request.formFields['shareWith'], 'room1234');
      expect(request.formFields['path'], '/Documents/report.pdf');
      expect(
        utf8.decode(request.bodyBytes),
        'shareType=10&shareWith=room1234&path=%2FDocuments%2Freport.pdf',
      );
    });

    test('refuses to share the root or an escaping path', () {
      for (final path in const <String>['', '/', '../elsewhere/file.txt']) {
        expect(
          () => RemoteFileShareRequest(
            accountId: account,
            server: server,
            roomToken: room,
            path: path,
          ),
          throwsA(isA<TalkProtocolException>()),
          reason: path,
        );
      }
    });
  });

  group('share response', () {
    RemoteFileShareResponse decode(String body, {int statusCode = 200}) =>
        decodeRemoteFileShareResponse(
          request: RemoteFileShareRequest(
            accountId: account,
            server: server,
            roomToken: room,
            path: 'report.pdf',
          ),
          statusCode: statusCode,
          body: Uint8List.fromList(utf8.encode(body)),
        );

    test('an OCS success is what counts as shared', () {
      expect(
        decode('{"ocs":{"meta":{"statuscode":100},"data":{"id":"7"}}}').outcome,
        RemoteFileShareOutcome.shared,
      );
      expect(
        decode('{"ocs":{"meta":{"statuscode":200},"data":{}}}').outcome,
        RemoteFileShareOutcome.shared,
      );
    });

    test('an HTTP 200 carrying an OCS failure is not a sent file', () {
      expect(
        decode('{"ocs":{"meta":{"statuscode":403},"data":{}}}').outcome,
        RemoteFileShareOutcome.forbidden,
      );
    });

    test('classifies the refusals the server can answer with', () {
      expect(
        decode('', statusCode: 401).outcome,
        RemoteFileShareOutcome.reauthenticationRequired,
      );
      expect(
        decode('', statusCode: 403).outcome,
        RemoteFileShareOutcome.forbidden,
      );
      expect(
        decode('', statusCode: 404).outcome,
        RemoteFileShareOutcome.notFound,
      );
      expect(
        decode('', statusCode: 429).outcome,
        RemoteFileShareOutcome.transientError,
      );
      expect(
        () => decode('', statusCode: 418),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });
}
