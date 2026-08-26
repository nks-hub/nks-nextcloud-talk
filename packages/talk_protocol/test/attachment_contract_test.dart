import 'dart:convert';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

import 'support/attachment_test_support.dart';

void main() {
  group('attachment capability profile', () {
    test('requires authenticated attachment and reference capabilities', () {
      final enabled = profile();
      expect(enabled.enabled, isTrue);
      expect(enabled.caption, isTrue);
      expect(enabled.voice, isTrue);
      expect(enabled.reply, isTrue);
      expect(enabled.threads, isTrue);
      expect(enabled.silent, isTrue);

      expect(profile(allowed: false).enabled, isFalse);
      expect(profile(conversationSubfolders: false).enabled, isFalse);
      expect(profile(features: const <String>[]).enabled, isFalse);
      expect(profile(federated: true).enabled, isFalse);
    });

    test('rejects anonymous capability snapshots', () {
      expect(
        () => AttachmentCapabilityProfile.fromSnapshot(
          capabilitySnapshot(context: CapabilityContext.anonymous),
          federated: false,
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidAttachmentProfile,
          ),
        ),
      );
    });

    test('gates optional metadata independently', () {
      final basic = profile(features: const <String>['chat-reference-id']);
      expect(basic.supports(metadata()), isTrue);
      expect(basic.supports(metadata(caption: 'caption')), isFalse);
      expect(
        basic.supports(metadata(kind: AttachmentMessageKind.voice)),
        isFalse,
      );
      expect(basic.supports(metadata(replyTo: 1)), isFalse);
      expect(basic.supports(metadata(threadId: 1)), isFalse);
      expect(basic.supports(metadata(silent: true)), isFalse);
    });
  });

  group('attachment OCS request wire', () {
    test('probe uses explicit immutable JSON boolean and bound context', () {
      final context = attachmentContext(1);
      final request = AttachmentProbeRequest(
        context: context,
        fileNames: const <String>['photo.jpg', 'photo.jpg'],
      );

      expect(request.method, AttachmentHttpMethod.post);
      expect(request.step, AttachmentRequestStep.probe);
      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/nextcloud/ocs/v2.php/apps/spreed/'
        'api/v1/chat/rooma123/attachment/folder?format=json',
      );
      expect(request.headers, <String, String>{
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'OCS-APIRequest': 'true',
        'User-Agent': attachmentContractUserAgent,
      });
      expect(request.body.fields, <String, Object?>{
        'fileNames': <Object?>['photo.jpg', 'photo.jpg'],
        'allowUpdate': false,
      });
      expect(
        () => request.body.fields['allowUpdate'] = true,
        throwsUnsupportedError,
      );
    });

    test('finalize fixes allowUpdate false and binds typed metadata', () {
      final prepared = source();
      final request = AttachmentFinalizeRequest(
        context: attachmentContext(2),
        remoteTemporaryPath: DavRelativePath.parse(
          'Talk/Synthetic room-rooma123/Draft/'
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.upload',
        ),
        source: prepared,
        referenceId: referenceId(),
        metadata: metadata(
          caption: 'Synthetic caption',
          threadId: 101,
          threadTitle: '  Synthetic thread  ',
          silent: true,
        ),
      );

      expect(request.body.fields['allowUpdate'], isFalse);
      expect(request.body.fields['fileName'], 'photo.jpg');
      expect(request.body.fields['referenceId'], referenceId().value);
      final metadataJson = jsonDecode(
        request.body.fields['talkMetaData']! as String,
      );
      expect(metadataJson, <String, Object?>{
        'caption': 'Synthetic caption',
        'silent': true,
        'threadId': 101,
        'threadTitle': 'Synthetic thread',
      });

      final replyRequest = AttachmentFinalizeRequest(
        context: attachmentContext(20),
        remoteTemporaryPath: DavRelativePath.parse('Talk/Draft/job.upload'),
        source: prepared,
        referenceId: referenceId(),
        metadata: metadata(replyTo: 102),
      );
      expect(
        jsonDecode(replyRequest.body.fields['talkMetaData']! as String),
        <String, Object?>{'replyTo': 102},
      );

      expect(
        () => metadata(replyTo: 101, threadId: 101),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidAttachmentModel,
          ),
        ),
      );

      expect(
        () => metadata(threadTitle: 'Synthetic thread'),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidAttachmentModel,
          ),
        ),
      );
      expect(
        () => metadata(
          threadId: 101,
          threadTitle: List<String>.filled(201, 'x').join(),
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidAttachmentModel,
          ),
        ),
      );
    });

    test('voice finalization carries voice message metadata', () {
      final request = AttachmentFinalizeRequest(
        context: attachmentContext(3),
        remoteTemporaryPath: DavRelativePath.parse('Talk/Draft/job.upload'),
        source: source(mime: 'audio/wav', name: 'voice.wav'),
        referenceId: referenceId(),
        metadata: metadata(kind: AttachmentMessageKind.voice),
      );
      expect(
        jsonDecode(request.body.fields['talkMetaData']! as String),
        <String, Object?>{'messageType': 'voice-message'},
      );
      expect(request.expectedMessageType, 'voice-message');

      expect(
        () => AttachmentFinalizeRequest(
          context: attachmentContext(30),
          remoteTemporaryPath: DavRelativePath.parse('Talk/Draft/job.upload'),
          source: source(mime: 'audio/ogg', name: 'voice.ogg'),
          referenceId: referenceId(),
          metadata: metadata(kind: AttachmentMessageKind.voice),
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidAttachmentRequest,
          ),
        ),
      );
      expect(
        () => draft(
          preparedSource: source(mime: 'audio/ogg', name: 'voice.ogg'),
          attachmentMetadata: metadata(kind: AttachmentMessageKind.voice),
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidAttachmentModel,
          ),
        ),
      );
    });

    test('typed metadata binds finalize and confirmation message types', () {
      final commentMetadata = metadata();
      final voiceMetadata = metadata(kind: AttachmentMessageKind.voice);

      expect(commentMetadata.expectedMessageType, 'comment');
      expect(voiceMetadata.expectedMessageType, 'voice-message');

      final commentRequest = AttachmentFinalizeRequest(
        context: attachmentContext(4),
        remoteTemporaryPath: DavRelativePath.parse('Talk/Draft/job.upload'),
        source: source(),
        referenceId: referenceId(),
        metadata: commentMetadata,
      );
      expect(commentRequest.expectedMessageType, 'comment');
      expect(
        jsonDecode(commentRequest.body.fields['talkMetaData']! as String),
        isNot(contains('messageType')),
      );
    });
  });

  group('attachment DAV request wire', () {
    test('normal PUT encodes each path segment exactly once', () {
      final prepared = source(name: 'příloha 1.jpg');
      final request = AttachmentDavRequest.normalPut(
        context: attachmentContext(4),
        davUserId: davUserA,
        remotePath: DavRelativePath.parse(
          'Talk/Synthetic room-rooma123/Draft/příloha 1.jpg',
        ),
        source: prepared,
      );

      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/nextcloud/remote.php/dav/files/'
        'user-a/Talk/Synthetic%20room-rooma123/Draft/'
        'p%C5%99%C3%ADloha%201.jpg',
      );
      expect(request.headers['Content-Length'], '1024');
      expect(request.headers['Content-Type'], 'image/jpeg');
      expect(request.headers['If-None-Match'], '*');
      final body = request.body! as AttachmentSourceBody;
      expect(body.offset, 0);
      expect(body.length, 1024);
    });

    test('chunk PUT puts range only in the canonical resource name', () {
      final prepared = source(size: 2500000);
      final range = DavChunkRange(
        start: 1024000,
        end: 2047999,
        fileSize: prepared.byteLength,
      );
      final request = AttachmentDavRequest.chunkPut(
        context: attachmentContext(5),
        davUserId: davUserA,
        uploadSessionId: DavUploadSessionId.parse(
          'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        ),
        source: prepared,
        range: range,
      );

      expect(
        request.uri.pathSegments.last,
        '0000000001024000-0000000002047999',
      );
      expect(request.headers, isNot(contains('Range')));
      expect(request.headers, isNot(contains('Content-Range')));
      final body = request.body! as AttachmentSourceBody;
      expect(body.offset, 1024000);
      expect(body.length, 1024000);
    });

    test('chunk MOVE carries total length and same-origin destination', () {
      final request = AttachmentDavRequest.chunkMove(
        context: attachmentContext(6),
        davUserId: davUserA,
        uploadSessionId: DavUploadSessionId.parse(
          'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        ),
        remotePath: DavRelativePath.parse('Talk/Draft/job.upload'),
        totalLength: 2500000,
      );
      expect(request.uri.pathSegments.last, '.file');
      expect(request.headers['OC-Total-Length'], '2500000');
      expect(request.headers['Overwrite'], 'F');
      expect(
        Uri.parse(request.headers['Destination']!).origin,
        request.uri.origin,
      );
    });

    test('exact chunk multiple never creates an empty final chunk', () {
      final uploadPolicy = policy(chunkSize: 1024000);
      expect(uploadPolicy.chunkCountFor(2048000), 2);
      expect(
        uploadPolicy.chunkAt(1024000, fileSize: 2048000).wireName,
        '0000000001024000-0000000002047999',
      );
      expect(
        () => uploadPolicy.chunkAt(2048000, fileSize: 2048000),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('appending a DAV segment preserves aggregate path bounds', () {
      final maximumSegments = DavRelativePath.parse(
        List<String>.filled(64, 'a').join('/'),
      );
      final maximumLength = DavRelativePath.parse(
        <String>[
          ...List<String>.filled(15, List<String>.filled(255, 'a').join()),
          List<String>.filled(255, 'b').join(),
        ].join('/'),
      );

      for (final path in <DavRelativePath>[maximumSegments, maximumLength]) {
        expect(
          () => path.append('c'),
          throwsA(
            isA<TalkProtocolException>().having(
              (error) => error.code,
              'code',
              TalkProtocolErrorCode.invalidAttachmentDavPath,
            ),
          ),
        );
      }
    });
  });

  group('attachment OCS responses', () {
    test('probe and finalize retain their exact requests', () {
      final probe = AttachmentProbeRequest(
        context: attachmentContext(7),
        fileNames: const <String>['photo.jpg'],
      );
      final probeResponse = decodeAttachmentProbeResponse(
        request: probe,
        statusCode: 200,
        body: probeSuccessBody(),
      );
      expect(identical(probeResponse.request, probe), isTrue);
      expect(
        probeResponse.classification,
        AttachmentProbeClassification.confirmed,
      );
      expect(probeResponse.folder!.value, contains('/Draft'));

      final finalize = AttachmentFinalizeRequest(
        context: attachmentContext(8),
        remoteTemporaryPath: probeResponse.folder!.append('job.upload'),
        source: source(),
        referenceId: referenceId(),
        metadata: metadata(),
      );
      final finalizeResponse = decodeAttachmentFinalizeResponse(
        request: finalize,
        statusCode: 200,
        body: finalizeSuccessBody(),
      );
      expect(identical(finalizeResponse.request, finalize), isTrue);
      expect(
        finalizeResponse.classification,
        AttachmentFinalizeClassification.accepted,
      );
    });

    test('finalize failure classes preserve ambiguity boundary', () {
      final request = AttachmentFinalizeRequest(
        context: attachmentContext(9),
        remoteTemporaryPath: DavRelativePath.parse('Talk/Draft/job.upload'),
        source: source(),
        referenceId: referenceId(),
        metadata: metadata(),
      );
      AttachmentFinalizeResponse decode(int http, int ocs) =>
          decodeAttachmentFinalizeResponse(
            request: request,
            statusCode: http,
            body: ocsBody(
              status: 'failure',
              statusCode: ocs,
              data: <String, Object?>{'error': 'Synthetic'},
            ),
          );

      expect(
        decode(422, 422).classification,
        AttachmentFinalizeClassification.deterministicFailure,
      );
      expect(
        decode(401, 401).classification,
        AttachmentFinalizeClassification.reauthenticationRequired,
      );
      expect(
        decode(500, 500).classification,
        AttachmentFinalizeClassification.ambiguous,
      );
      expect(
        decode(409, 409).classification,
        AttachmentFinalizeClassification.ambiguous,
      );
      expect(
        decode(200, 500).classification,
        AttachmentFinalizeClassification.ambiguous,
      );
      for (final mismatch in <(int, String, int)>[
        (404, 'failure', 500),
        (404, 'ok', 404),
        (404, 'ok', 200),
      ]) {
        final response = decodeAttachmentFinalizeResponse(
          request: request,
          statusCode: mismatch.$1,
          body: ocsBody(
            status: mismatch.$2,
            statusCode: mismatch.$3,
            data: <String, Object?>{'error': 'Synthetic'},
          ),
        );
        expect(
          response.classification,
          AttachmentFinalizeClassification.ambiguous,
          reason: mismatch.toString(),
        );
      }
    });

    test('probe rejects mismatched or malformed OCS failure envelopes', () {
      final request = AttachmentProbeRequest(
        context: attachmentContext(10),
        fileNames: const <String>['photo.jpg'],
      );
      for (final envelope in <(int, String, int, Object?)>[
        (404, 'failure', 500, <String, Object?>{'error': 'Synthetic'}),
        (404, 'ok', 404, <String, Object?>{'error': 'Synthetic'}),
        (404, 'failure', 404, 'not-an-object'),
      ]) {
        expect(
          () => decodeAttachmentProbeResponse(
            request: request,
            statusCode: envelope.$1,
            body: ocsBody(
              status: envelope.$2,
              statusCode: envelope.$3,
              data: envelope.$4,
            ),
          ),
          throwsA(
            isA<TalkProtocolException>().having(
              (error) => error.code,
              'code',
              TalkProtocolErrorCode.invalidAttachmentResponse,
            ),
          ),
          reason: envelope.toString(),
        );
      }
    });
  });
}
