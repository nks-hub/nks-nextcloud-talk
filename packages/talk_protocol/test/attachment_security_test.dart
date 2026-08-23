import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

import 'support/attachment_test_support.dart';

void main() {
  group('attachment filename validation', () {
    test('rejects the DEL control character in source and probe names', () {
      expect(
        () => source(name: 'photo\u007f.jpg'),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidAttachmentModel,
          ),
        ),
      );
      expect(
        () => AttachmentProbeRequest(
          context: attachmentContext(0),
          fileNames: const <String>['photo\u007f.jpg'],
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidAttachmentRequest,
          ),
        ),
      );
    });
  });

  group('attachment authority and response binding', () {
    test(
      'rejects cross-account, cross-origin, cross-room and stale authority',
      () {
        final operation = draft();
        final snapshot = emptySnapshot(includeSecondAccount: true);

        for (final invalid in <AttachmentAuthority>[
          authority(account: accountB, server: serverB),
          authority(server: serverB),
          authority(room: roomB),
          authority(generation: 8),
          authority(revision: 'stale-revision'),
        ]) {
          final result = admitAttachmentJob(
            snapshot,
            accountId: accountA,
            authority: invalid,
            davUserId: davUserA,
            draft: operation,
          );
          expect(
            result.outcome,
            AttachmentRuntimeOutcome.rejected,
            reason: invalid.toString(),
          );
          expect(result.canCommit, isFalse);
        }
      },
    );

    test('contract revision cannot change between admission and replay', () {
      final operation = draft();
      var snapshot = emptySnapshot();
      final admitted = admitAttachmentJob(
        snapshot,
        accountId: accountA,
        authority: authority(),
        davUserId: davUserA,
        draft: operation,
      );
      snapshot = commit(snapshot, admitted);

      final changed = planNextAttachmentStep(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        authority: authority(revision: 'stale-revision'),
        requestId: requestId(1),
      );
      expect(changed.outcome, AttachmentRuntimeOutcome.rejected);
      expect(changed.canCommit, isFalse);
    });

    test('response must retain the exact originating request instance', () {
      final operation = draft();
      var snapshot = emptySnapshot();
      snapshot = commit(
        snapshot,
        admitAttachmentJob(
          snapshot,
          accountId: accountA,
          authority: authority(),
          davUserId: davUserA,
          draft: operation,
        ),
      );
      final planned = planNextAttachmentStep(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        authority: authority(),
        requestId: requestId(2),
      );
      snapshot = commit(snapshot, planned);
      final original = planned.request! as AttachmentProbeRequest;
      final lookalike = AttachmentProbeRequest(
        context: AttachmentRequestContext(
          accountId: original.accountId,
          requestId: original.requestId,
          jobId: original.jobId,
          server: original.server,
          roomToken: original.roomToken,
          capabilityGeneration: original.context.capabilityGeneration,
          contractRevision: original.context.contractRevision,
        ),
        fileNames: const <String>['photo.jpg'],
      );
      final response = decodeAttachmentProbeResponse(
        request: lookalike,
        statusCode: 200,
        body: probeSuccessBody(),
      );
      final rejected = applyAttachmentResponse(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        response: response,
      );
      expect(rejected.outcome, AttachmentRuntimeOutcome.rejected);
      expect(rejected.canCommit, isFalse);
    });

    test('source observation is mandatory before every upload step', () {
      final prepared = source(size: 2048000);
      final operation = draft(preparedSource: prepared);
      var snapshot = _driveProbe(operation);

      final missingFirst = planNextAttachmentStep(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        authority: authority(),
        requestId: requestId(10),
      );
      expect(missingFirst.outcome, AttachmentRuntimeOutcome.rejected);

      final mkcol = planNextAttachmentStep(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        authority: authority(),
        requestId: requestId(11),
        sourceObservation: observation(prepared),
      );
      snapshot = commit(snapshot, mkcol);
      snapshot = _applyDav(
        snapshot,
        operation,
        mkcol.request! as AttachmentDavRequest,
        201,
      );

      final missingResume = planNextAttachmentStep(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        authority: authority(),
        requestId: requestId(12),
      );
      expect(missingResume.outcome, AttachmentRuntimeOutcome.rejected);
      expect(missingResume.request, isNull);
    });
  });

  group('attachment path and XML trust boundaries', () {
    test('relative paths reject traversal, encoded and URI forms', () {
      for (final value in <String>[
        '/Talk/Draft/file',
        r'Talk\Draft\file',
        'Talk/./Draft/file',
        'Talk/Draft/../file',
        'Talk//Draft/file',
        'Talk/Draft/file?replace=true',
        'Talk/Draft/file#fragment',
        'Talk/Draft/%2e%2e/file',
        'https://attacker.example.invalid/file',
      ]) {
        expect(
          () => DavRelativePath.parse(value),
          throwsA(
            isA<TalkProtocolException>().having(
              (error) => error.code,
              'code',
              TalkProtocolErrorCode.invalidAttachmentDavPath,
            ),
          ),
          reason: value,
        );
      }
    });

    test('rejects BOM, UTF-16 declaration, DTD and entity declarations', () {
      final request = propfindRequest();
      final valid = davManifestXml(sessionUri: request.uri);
      final payloads = <Uint8List>[
        Uint8List.fromList(<int>[0xef, 0xbb, 0xbf, ...utf8.encode(valid)]),
        Uint8List.fromList(utf8.encode(valid.replaceFirst('utf-8', 'utf-16'))),
        Uint8List.fromList(
          utf8.encode(
            '<?xml version="1.0" encoding="utf-8"?>'
            '<!DOCTYPE d:multistatus SYSTEM "https://attacker.invalid/dtd">'
            '<d:multistatus xmlns:d="DAV:"/>',
          ),
        ),
        Uint8List.fromList(
          utf8.encode(
            '<?xml version="1.0" encoding="utf-8"?>'
            '<!ENTITY leak "secret"><d:multistatus xmlns:d="DAV:"/>',
          ),
        ),
      ];
      for (final payload in payloads) {
        expectDavXmlFailure(
          () => decodeAttachmentDavResponse(
            request: request,
            statusCode: 207,
            body: payload,
            fileSize: 1024,
          ),
        );
      }
    });

    test('enforces byte, event-node and depth limits before tree use', () {
      final request = propfindRequest();
      expect(
        () => decodeAttachmentDavResponse(
          request: request,
          statusCode: 207,
          body: Uint8List(attachmentMaximumDavXmlBytes + 1),
          fileSize: 1024,
        ),
        throwsA(isA<TalkProtocolException>()),
      );

      final deep = StringBuffer(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<d:multistatus xmlns:d="DAV:">',
      );
      for (var index = 0; index <= attachmentMaximumDavXmlDepth; index++) {
        deep.write('<d:prop>');
      }
      for (var index = 0; index <= attachmentMaximumDavXmlDepth; index++) {
        deep.write('</d:prop>');
      }
      deep.write('</d:multistatus>');
      expectDavXmlFailure(
        () => decodeAttachmentDavResponse(
          request: request,
          statusCode: 207,
          body: Uint8List.fromList(utf8.encode(deep.toString())),
          fileSize: 1024,
        ),
      );

      final wide = StringBuffer(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<d:multistatus xmlns:d="DAV:">',
      );
      for (var index = 0; index <= attachmentMaximumDavXmlNodes; index++) {
        wide.write('<!--x-->');
      }
      wide.write('</d:multistatus>');
      expectDavXmlFailure(
        () => decodeAttachmentDavResponse(
          request: request,
          statusCode: 207,
          body: Uint8List.fromList(utf8.encode(wide.toString())),
          fileSize: 1024,
        ),
      );
    });

    test('rejects wrong DAV namespace and cross-origin href', () {
      final request = propfindRequest();
      final wrongNamespace =
          '<d:multistatus xmlns:d="https://attacker.invalid/dav"/>';
      expectDavXmlFailure(
        () => decodeAttachmentDavResponse(
          request: request,
          statusCode: 207,
          body: Uint8List.fromList(utf8.encode(wrongNamespace)),
          fileSize: 1024,
        ),
      );

      final crossOrigin =
          '<d:multistatus xmlns:d="DAV:"><d:response>'
          '<d:href>https://attacker.example.invalid/'
          '0000000000000000-0000000000001023</d:href>'
          '<d:propstat><d:prop><d:getcontentlength>1024</d:getcontentlength>'
          '</d:prop><d:status>HTTP/1.1 200 OK</d:status>'
          '</d:propstat></d:response></d:multistatus>';
      expectDavXmlFailure(
        () => decodeAttachmentDavResponse(
          request: request,
          statusCode: 207,
          body: Uint8List.fromList(utf8.encode(crossOrigin)),
          fileSize: 1024,
        ),
      );
    });
  });

  group('attachment immutability and redaction', () {
    test('candidate plans are source-bound and single-use', () {
      final operation = draft();
      final snapshot = emptySnapshot();
      final admitted = admitAttachmentJob(
        snapshot,
        accountId: accountA,
        authority: authority(),
        davUserId: davUserA,
        draft: operation,
      );
      final candidate = admitted.plan!;
      final committed = candidate.commit(snapshot);
      expect(
        () => candidate.commit(snapshot),
        throwsA(isA<TalkProtocolException>()),
      );

      final other = emptySnapshot();
      final second = admitAttachmentJob(
        other,
        accountId: accountA,
        authority: authority(),
        davUserId: davUserA,
        draft: operation,
      );
      expect(
        () => second.plan!.commit(committed),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('all exposed collections are immutable', () {
      final path = DavRelativePath.parse('Talk/Draft/file');
      expect(() => path.segments.add('other'), throwsUnsupportedError);

      final operation = draft();
      var snapshot = emptySnapshot();
      snapshot = commit(
        snapshot,
        admitAttachmentJob(
          snapshot,
          accountId: accountA,
          authority: authority(),
          davUserId: davUserA,
          draft: operation,
        ),
      );
      expect(
        () => snapshot.accounts[accountA]!.jobs.clear(),
        throwsUnsupportedError,
      );
    });

    test('diagnostics never contain sensitive attachment values', () {
      const secrets = <String>[
        'account-a',
        'cloud.example.invalid',
        'user-a',
        'rooma123',
        'app-owned-source-a',
        'photo.jpg',
        '11111111-1111-4111-8111-111111111111',
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'Synthetic caption',
      ];
      final prepared = source();
      final operation = draft(
        preparedSource: prepared,
        attachmentMetadata: metadata(caption: 'Synthetic caption'),
      );
      var snapshot = emptySnapshot();
      final admitted = admitAttachmentJob(
        snapshot,
        accountId: accountA,
        authority: authority(),
        davUserId: davUserA,
        draft: operation,
      );
      snapshot = commit(snapshot, admitted);
      final planned = planNextAttachmentStep(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        authority: authority(),
        requestId: requestId(30),
      );
      final texts = <String>[
        prepared.toString(),
        operation.toString(),
        authority().toString(),
        snapshot.toString(),
        snapshot.accounts[accountA]!.toString(),
        snapshot.accounts[accountA]!.jobs[operation.jobId]!.toString(),
        planned.request.toString(),
        planned.toString(),
      ];
      for (final text in texts) {
        for (final secret in secrets) {
          expect(text, isNot(contains(secret)), reason: text);
        }
      }
    });
  });
}

AttachmentRuntimeSnapshot _driveProbe(AttachmentJobDraft operation) {
  var snapshot = emptySnapshot();
  snapshot = commit(
    snapshot,
    admitAttachmentJob(
      snapshot,
      accountId: accountA,
      authority: authority(),
      davUserId: davUserA,
      draft: operation,
    ),
  );
  final plan = planNextAttachmentStep(
    snapshot,
    accountId: accountA,
    jobId: operation.jobId,
    authority: authority(),
    requestId: requestId(100),
  );
  snapshot = commit(snapshot, plan);
  final response = decodeAttachmentProbeResponse(
    request: plan.request! as AttachmentProbeRequest,
    statusCode: 200,
    body: probeSuccessBody(),
  );
  return commit(
    snapshot,
    applyAttachmentResponse(
      snapshot,
      accountId: accountA,
      jobId: operation.jobId,
      response: response,
    ),
  );
}

AttachmentRuntimeSnapshot _applyDav(
  AttachmentRuntimeSnapshot snapshot,
  AttachmentJobDraft operation,
  AttachmentDavRequest request,
  int status,
) {
  final response = decodeAttachmentDavResponse(
    request: request,
    statusCode: status,
    body: Uint8List(0),
  );
  return commit(
    snapshot,
    applyAttachmentResponse(
      snapshot,
      accountId: accountA,
      jobId: operation.jobId,
      response: response,
    ),
  );
}

AttachmentDavRequest propfindRequest() => AttachmentDavRequest.chunkPropfind(
  context: attachmentContext(200),
  davUserId: davUserA,
  uploadSessionId: DavUploadSessionId.parse(
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  ),
);

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
