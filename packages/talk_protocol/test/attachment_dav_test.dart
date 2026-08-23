import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

import 'support/attachment_test_support.dart';

void main() {
  group('DAV status classification', () {
    final prepared = source(size: 2500000);
    final session = DavUploadSessionId.parse(
      'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    );

    test('accepts only the verified success matrix', () {
      final cases = <(AttachmentDavRequest, List<int>)>[
        (
          AttachmentDavRequest.chunkMkcol(
            context: attachmentContext(1),
            davUserId: davUserA,
            uploadSessionId: session,
          ),
          <int>[201, 405],
        ),
        (
          AttachmentDavRequest.normalPut(
            context: attachmentContext(2),
            davUserId: davUserA,
            remotePath: DavRelativePath.parse('Talk/Draft/job.upload'),
            source: prepared,
          ),
          <int>[201, 204],
        ),
        (
          AttachmentDavRequest.chunkPut(
            context: attachmentContext(3),
            davUserId: davUserA,
            uploadSessionId: session,
            source: prepared,
            range: DavChunkRange(
              start: 0,
              end: 1023999,
              fileSize: prepared.byteLength,
            ),
          ),
          <int>[201, 204],
        ),
        (
          AttachmentDavRequest.chunkMove(
            context: attachmentContext(4),
            davUserId: davUserA,
            uploadSessionId: session,
            remotePath: DavRelativePath.parse('Talk/Draft/job.upload'),
            totalLength: prepared.byteLength,
          ),
          <int>[201, 204],
        ),
        (
          AttachmentDavRequest.cleanupChunkSession(
            context: attachmentContext(5),
            davUserId: davUserA,
            uploadSessionId: session,
          ),
          <int>[204, 404],
        ),
        (
          AttachmentDavRequest.cleanupDraftFile(
            context: attachmentContext(6),
            davUserId: davUserA,
            remotePath: DavRelativePath.parse('Talk/Draft/job.upload'),
          ),
          <int>[204, 404],
        ),
      ];

      for (final value in cases) {
        for (final status in value.$2) {
          final response = decodeAttachmentDavResponse(
            request: value.$1,
            statusCode: status,
            body: Uint8List(0),
          );
          expect(
            response.classification,
            AttachmentDavClassification.success,
            reason: '${value.$1.step.name} $status',
          );
          expect(identical(response.request, value.$1), isTrue);
        }
      }
    });

    test('classifies MOVE length mismatch and transient errors', () {
      final request = AttachmentDavRequest.chunkMove(
        context: attachmentContext(7),
        davUserId: davUserA,
        uploadSessionId: session,
        remotePath: DavRelativePath.parse('Talk/Draft/job.upload'),
        totalLength: prepared.byteLength,
      );
      expect(
        decodeAttachmentDavResponse(
          request: request,
          statusCode: 400,
          body: Uint8List(0),
        ).classification,
        AttachmentDavClassification.deterministicFailure,
      );
      expect(
        decodeAttachmentDavResponse(
          request: request,
          statusCode: 500,
          body: Uint8List(0),
        ).classification,
        AttachmentDavClassification.transientFailure,
      );
      expect(
        decodeAttachmentDavResponse(
          request: request,
          statusCode: 401,
          body: Uint8List(0),
        ).classification,
        AttachmentDavClassification.reauthenticationRequired,
      );
    });

    test('rejects redirects instead of following untrusted locations', () {
      final request = AttachmentDavRequest.normalPut(
        context: attachmentContext(8),
        davUserId: davUserA,
        remotePath: DavRelativePath.parse('Talk/Draft/job.upload'),
        source: source(),
      );
      expect(
        () => decodeAttachmentDavResponse(
          request: request,
          statusCode: 302,
          body: Uint8List(0),
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.unsupportedHttpStatus,
          ),
        ),
      );
    });
  });

  group('bounded DAV multistatus parser', () {
    late AttachmentDavRequest request;
    late AttachmentUploadPolicy uploadPolicy;

    setUp(() {
      request = AttachmentDavRequest.chunkPropfind(
        context: attachmentContext(20),
        davUserId: davUserA,
        uploadSessionId: DavUploadSessionId.parse(
          'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        ),
      );
      uploadPolicy = policy(chunkSize: 1024000);
    });

    test('parses verified ranges and returns only missing chunks', () {
      final xml = davManifestXml(
        sessionUri: request.uri,
        chunks: const <(String, int)>[
          ('0000000000000000-0000000001023999', 1024000),
        ],
      );
      final response = decodeAttachmentDavResponse(
        request: request,
        statusCode: 207,
        body: Uint8List.fromList(utf8.encode(xml)),
        fileSize: 2048000,
      );

      expect(response.classification, AttachmentDavClassification.success);
      expect(response.manifest!.chunks, hasLength(1));
      expect(
        response.manifest!
            .missingRanges(policy: uploadPolicy, fileSize: 2048000)
            .map((range) => range.wireName),
        <String>['0000000001024000-0000000002047999'],
      );
    });

    test('accepts an absolute same-origin href', () {
      final href = '${request.uri}/0000000000000000-0000000000001023';
      final xml = _singleChunkXml(href: href, length: 1024);
      final response = decodeAttachmentDavResponse(
        request: request,
        statusCode: 207,
        body: Uint8List.fromList(utf8.encode(xml)),
        fileSize: 1024,
      );
      expect(response.manifest!.chunks.single.length, 1024);
    });

    test('rejects incorrect lengths, duplicates, and overlaps', () {
      final wrongLength = davManifestXml(
        sessionUri: request.uri,
        chunks: const <(String, int)>[
          ('0000000000000000-0000000000001023', 100),
        ],
      );
      expectDavXmlFailure(
        () => decodeAttachmentDavResponse(
          request: request,
          statusCode: 207,
          body: Uint8List.fromList(utf8.encode(wrongLength)),
          fileSize: 2048,
        ),
      );

      final duplicate = davManifestXml(
        sessionUri: request.uri,
        chunks: const <(String, int)>[
          ('0000000000000000-0000000000001023', 1024),
          ('0000000000000000-0000000000001023', 1024),
        ],
      );
      expectDavXmlFailure(
        () => decodeAttachmentDavResponse(
          request: request,
          statusCode: 207,
          body: Uint8List.fromList(utf8.encode(duplicate)),
          fileSize: 2048,
        ),
      );

      final overlap = davManifestXml(
        sessionUri: request.uri,
        chunks: const <(String, int)>[
          ('0000000000000000-0000000000001023', 1024),
          ('0000000000000512-0000000000001535', 1024),
        ],
      );
      expectDavXmlFailure(
        () => decodeAttachmentDavResponse(
          request: request,
          statusCode: 207,
          body: Uint8List.fromList(utf8.encode(overlap)),
          fileSize: 2048,
        ),
      );
    });

    test('rejects resources outside the bound upload session', () {
      final xml = _singleChunkXml(
        href:
            '/nextcloud/remote.php/dav/uploads/user-a/'
            'cccccccc-cccc-4ccc-8ccc-cccccccccccc/'
            '0000000000000000-0000000000001023',
        length: 1024,
      );
      expectDavXmlFailure(
        () => decodeAttachmentDavResponse(
          request: request,
          statusCode: 207,
          body: Uint8List.fromList(utf8.encode(xml)),
          fileSize: 1024,
        ),
      );
    });
  });
}

String _singleChunkXml({required String href, required int length}) =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:multistatus xmlns:d="DAV:"><d:response>'
    '<d:href>$href</d:href><d:propstat><d:prop>'
    '<d:getcontentlength>$length</d:getcontentlength></d:prop>'
    '<d:status>HTTP/1.1 200 OK</d:status>'
    '</d:propstat></d:response></d:multistatus>';

void expectDavXmlFailure(void Function() callback) {
  expect(
    callback,
    throwsA(
      isA<TalkProtocolException>().having(
        (error) => error.code,
        'code',
        TalkProtocolErrorCode.invalidAttachmentDavXml,
      ),
    ),
  );
}
