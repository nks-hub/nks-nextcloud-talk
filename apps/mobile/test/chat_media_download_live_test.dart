import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';
import 'package:uuid/uuid.dart';

import 'test_support.dart';

void main() {
  final accessPath = Platform.environment['NCTALK_LIVE_ACCESS_FILE'];
  test(
    'a large DAV attachment reaches disk unchanged through the live transport',
    () async {
      final access = jsonDecode(await File(accessPath!).readAsString()) as Map;
      final origin = Uri.parse(access['origin'] as String);
      final user = access['user'] as String;
      final password = access['password'] as String;
      if (origin.scheme != 'https' || !user.toLowerCase().contains('test')) {
        throw StateError('HTTPS and a dedicated test account are required');
      }
      final account = StoredAccount(
        id: 'download-live',
        serverUrl: origin.toString(),
        loginName: user,
        serverProductName: 'Nextcloud',
        talkFeaturesJson: '[]',
        selected: true,
        createdAtMillis: DateTime.now().millisecondsSinceEpoch,
      );
      final uri = origin.replace(
        pathSegments: [
          ...origin.pathSegments.where((part) => part.isNotEmpty),
          'remote.php',
          'dav',
          'files',
          user,
          'download-verification-${const Uuid().v4()}.bin',
        ],
      );
      final headers = {
        'Authorization':
            'Basic ${base64Encode(utf8.encode('$user:$password'))}',
        'OCS-APIRequest': 'true',
      };
      final client = http.Client();
      final repository = ChatMediaRepository(
        MemoryCredentialVault()..values[account.id] = password,
      );
      final directory = await Directory.systemTemp.createTemp('live-download-');
      const chunks = 72;
      final chunk = Uint8List.fromList(
        List<int>.generate(1024 * 1024, (index) => index % 251),
      );
      final expected = await sha256
          .bind(Stream<List<int>>.fromIterable(List.filled(chunks, chunk)))
          .first;
      try {
        final upload = http.StreamedRequest('PUT', uri)
          ..followRedirects = false
          ..headers.addAll({
            ...headers,
            'Content-Type': 'application/octet-stream',
          })
          ..contentLength = chunks * chunk.length;
        final responseFuture = client.send(upload);
        await upload.sink.addStream(
          Stream<List<int>>.fromIterable(List.filled(chunks, chunk)),
        );
        await upload.sink.close();
        final response = await responseFuture;
        await response.stream.drain<void>();
        expect(response.statusCode, anyOf(201, 204));
        final metadata = await client.head(uri, headers: headers);
        expect(metadata.statusCode, 200);
        final contentType = metadata.headers['content-type']!.split(';').first;
        expect(contentType, isNot('text/html'));
        stdout.writeln('Live DAV content type: $contentType');

        final target = File(
          '${directory.path}${Platform.pathSeparator}file.bin',
        );
        final watch = Stopwatch()..start();
        var downloaded = 0;
        await repository.downloadOriginalToFile(
          account: account,
          uri: uri,
          expectedContentType: contentType,
          target: target,
          onProgress: (received, _) => downloaded = received,
        );
        watch.stop();
        expect(await target.length(), chunks * chunk.length);
        expect(downloaded, chunks * chunk.length);
        expect(await sha256.bind(target.openRead()).first, expected);
        stdout.writeln(
          'Live attachment: $downloaded bytes, ${watch.elapsedMilliseconds} ms, SHA-256 matched.',
        );
      } finally {
        repository.close();
        try {
          final removed = await client.delete(uri, headers: headers);
          expect(removed.statusCode, anyOf(204, 404));
        } finally {
          client.close();
          await directory.delete(recursive: true);
        }
      }
    },
    skip: accessPath == null
        ? 'Dedicated live account is not configured.'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
