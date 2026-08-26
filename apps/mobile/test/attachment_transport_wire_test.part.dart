part of 'attachment_transport_test.dart';

void _registerWireTests() {
  test('executes Draft probe with account-bound authorization', () async {
    late http.Request captured;
    final transport = _transport(
      MockClient((request) async {
        captured = request;
        return http.Response.bytes(_probeSuccessBody(), 200);
      }),
    );
    final request = AttachmentProbeRequest(
      context: _context(1),
      fileNames: const <String>['photo.jpg'],
    );

    final response = await transport.probe(
      request: request,
      authorization: _authorization,
    );

    expect(response.classification, AttachmentProbeClassification.confirmed);
    expect(response.folder!.value, 'Talk/Synthetic room/Draft');
    expect(captured.method, 'POST');
    expect(captured.url, request.uri);
    expect(captured.followRedirects, isFalse);
    expect(captured.maxRedirects, 0);
    expect(captured.headers['authorization'], _authorizationHeader);
    expect(captured.headers['ocs-apirequest'], 'true');
    expect(captured.headers['content-type'], 'application/json');
    expect(jsonDecode(captured.body), <String, Object?>{
      'fileNames': <Object?>['photo.jpg'],
      'allowUpdate': false,
    });
  });

  test(
    'rejects account and server authority mismatch before dispatch',
    () async {
      var requestCount = 0;
      final transport = _transport(
        MockClient((_) async {
          requestCount++;
          return http.Response.bytes(_probeSuccessBody(), 200);
        }),
      );
      final request = AttachmentProbeRequest(
        context: _context(2),
        fileNames: const <String>['photo.jpg'],
      );
      final mismatches = <AttachmentTransportAuthorization>[
        AttachmentTransportAuthorization(
          accountId: AccountId.parse('account-b'),
          server: _server,
          loginName: _loginName,
          appPassword: _appPassword,
        ),
        AttachmentTransportAuthorization(
          accountId: _account,
          server: ServerBase.parse('https://other.example.invalid/nextcloud'),
          loginName: _loginName,
          appPassword: _appPassword,
        ),
      ];

      for (final authorization in mismatches) {
        await expectLater(
          transport.probe(request: request, authorization: authorization),
          throwsA(
            _transportError(
              AttachmentTransportError.authorityMismatch,
              stage: AttachmentTransportStage.authorization,
              requestMayHaveReachedServer: false,
            ),
          ),
        );
      }
      expect(requestCount, 0);
    },
  );

  test('executes named-thread finalize JSON with the planner body', () async {
    late http.Request captured;
    final transport = _transport(
      MockClient((request) async {
        captured = request;
        return http.Response.bytes(_finalizeSuccessBody(), 200);
      }),
    );
    final request = _finalizeRequest(
      3,
      metadataScope: _FinalizeMetadataScope.namedThread,
    );

    final response = await transport.finalize(
      request: request,
      authorization: _authorization,
    );

    expect(response.classification, AttachmentFinalizeClassification.accepted);
    expect(captured.method, 'POST');
    final body = jsonDecode(captured.body) as Map<String, Object?>;
    expect(body['filePath'], 'Talk/Synthetic room/Draft/temp.bin');
    expect(body['fileName'], 'attachment.bin');
    expect(body['allowUpdate'], isFalse);
    expect(jsonDecode(body['talkMetaData']! as String), <String, Object?>{
      'caption': 'Synthetic caption',
      'silent': true,
      'threadId': 42,
      'threadTitle': 'Synthetic thread',
    });
  });

  test('executes ordinary-reply finalize JSON without thread scope', () async {
    late http.Request captured;
    final transport = _transport(
      MockClient((request) async {
        captured = request;
        return http.Response.bytes(_finalizeSuccessBody(), 200);
      }),
    );

    await transport.finalize(
      request: _finalizeRequest(
        30,
        metadataScope: _FinalizeMetadataScope.reply,
      ),
      authorization: _authorization,
    );

    final body = jsonDecode(captured.body) as Map<String, Object?>;
    expect(jsonDecode(body['talkMetaData']! as String), <String, Object?>{
      'caption': 'Synthetic caption',
      'silent': true,
      'replyTo': 42,
    });
  });

  test('marks malformed finalize as post-dispatch decoding failure', () async {
    final transport = _transport(
      MockClient((_) async => http.Response('not-json', 200)),
    );

    Object? caught;
    try {
      await transport.finalize(
        request: _finalizeRequest(4),
        authorization: _authorization,
      );
    } on Object catch (error) {
      caught = error;
    }

    expect(
      caught,
      _transportError(
        AttachmentTransportError.invalidResponse,
        stage: AttachmentTransportStage.decoding,
        requestMayHaveReachedServer: true,
      ),
    );
    final exception = caught! as AttachmentTransportException;
    expect(
      exception.protocolCode,
      TalkProtocolErrorCode.invalidAttachmentResponse,
    );
    expect(exception.toString(), isNot(contains('not-json')));
    expect(exception.toString(), isNot(contains(_appPassword)));
  });

  test('verifies immutable source once and streams normal PUT', () async {
    late http.Request captured;
    final provider = _MemorySourceProvider(<String, List<int>>{
      _sourceHandle: _normalBytes,
    });
    final transport = HttpAttachmentTransport(
      client: MockClient((request) async {
        captured = request;
        return http.Response('', 201);
      }),
      sourceProvider: provider,
    );
    final prepared = _source(_normalBytes, sha256: _normalSha256);
    final verified = await transport.verifySource(
      source: prepared,
      authorization: _authorization,
    );
    final request = AttachmentDavRequest.normalPut(
      context: _context(5),
      davUserId: _davUser,
      remotePath: _remotePath,
      source: prepared,
    );

    final response = await transport.sendDav(
      request: request,
      authorization: _authorization,
      verifiedSource: verified,
    );
    await transport.releaseSource(verified);

    expect(response.classification, AttachmentDavClassification.success);
    expect(captured.method, 'PUT');
    expect(captured.bodyBytes, _normalBytes);
    expect(captured.contentLength, _normalBytes.length);
    expect(captured.headers['content-type'], 'application/octet-stream');
    expect(provider.openCount, 1);
    expect(provider.lastLease!.readCount, 2);
    expect(provider.lastLease!.closeCount, 1);
  });

  test('reuses one verified source snapshot across multiple chunks', () async {
    final uploaded = <List<int>>[];
    final provider = _MemorySourceProvider(<String, List<int>>{
      _sourceHandle: _chunkBytes,
    });
    final transport = HttpAttachmentTransport(
      client: MockClient((request) async {
        uploaded.add(request.bodyBytes);
        return http.Response('', 201);
      }),
      sourceProvider: provider,
    );
    final prepared = _source(_chunkBytes, sha256: _chunkSha256);
    final verified = await transport.verifySource(
      source: prepared,
      authorization: _authorization,
    );
    final session = _uploadSession();
    final ranges = <DavChunkRange>[
      DavChunkRange(start: 0, end: 3, fileSize: _chunkBytes.length),
      DavChunkRange(start: 4, end: 7, fileSize: _chunkBytes.length),
    ];

    for (var index = 0; index < ranges.length; index++) {
      final response = await transport.sendDav(
        request: AttachmentDavRequest.chunkPut(
          context: _context(10 + index),
          davUserId: _davUser,
          uploadSessionId: session,
          source: prepared,
          range: ranges[index],
        ),
        authorization: _authorization,
        verifiedSource: verified,
      );
      expect(response.classification, AttachmentDavClassification.success);
    }
    await transport.releaseSource(verified);

    expect(uploaded, <List<int>>[utf8.encode('0123'), utf8.encode('4567')]);
    expect(provider.openCount, 1);
    expect(provider.lastLease!.readCount, 3);
  });

  test('reads a chunked source in linear physical bytes', () async {
    final provider = _MemorySourceProvider(<String, List<int>>{
      _sourceHandle: _chunkBytes,
    });
    final transport = HttpAttachmentTransport(
      client: MockClient((_) async => http.Response('', 201)),
      sourceProvider: provider,
    );
    final prepared = _source(_chunkBytes, sha256: _chunkSha256);
    final verified = await transport.verifySource(
      source: prepared,
      authorization: _authorization,
    );
    final session = _uploadSession();

    for (var start = 0; start < _chunkBytes.length; start += 4) {
      await transport.sendDav(
        request: AttachmentDavRequest.chunkPut(
          context: _context(20 + start),
          davUserId: _davUser,
          uploadSessionId: session,
          source: prepared,
          range: DavChunkRange(
            start: start,
            end: start + 3,
            fileSize: _chunkBytes.length,
          ),
        ),
        authorization: _authorization,
        verifiedSource: verified,
      );
    }
    await transport.releaseSource(verified);

    expect(provider.lastLease!.physicalBytesRead, _chunkBytes.length * 2);
    expect(provider.lastLease!.requestedRanges, <(int, int?)>[
      (0, null),
      (0, 4),
      (4, 4),
      (8, 4),
      (12, 4),
    ]);
  });

  test('executes MKCOL, PROPFIND, MOVE and cleanup DELETE wire', () async {
    final methods = <String>[];
    late AttachmentDavRequest propfindRequest;
    final transport = _transport(
      MockClient((request) async {
        methods.add(request.method);
        expect(request.followRedirects, isFalse);
        expect(request.maxRedirects, 0);
        expect(request.headers['authorization'], _authorizationHeader);
        switch (request.method) {
          case 'MKCOL':
            expect(request.bodyBytes, isEmpty);
            return http.Response('', 201);
          case 'PROPFIND':
            expect(request.headers['depth'], '1');
            expect(
              request.headers['content-type'],
              'application/xml; charset=utf-8',
            );
            expect(request.body, contains('getcontentlength'));
            return http.Response(_emptyDavManifest(propfindRequest.uri), 207);
          case 'MOVE':
            final destination = Uri.parse(request.headers['destination']!);
            expect(_server.hasSameOrigin(destination), isTrue);
            expect(destination.query, isEmpty);
            expect(destination.fragment, isEmpty);
            expect(request.headers['oc-total-length'], '16');
            expect(request.headers['overwrite'], 'T');
            return http.Response('', 201);
          case 'DELETE':
            expect(request.bodyBytes, isEmpty);
            return http.Response('', 204);
          default:
            fail('Unexpected method ${request.method}');
        }
      }),
    );
    final session = _uploadSession();
    final mkcol = AttachmentDavRequest.chunkMkcol(
      context: _context(20),
      davUserId: _davUser,
      uploadSessionId: session,
    );
    propfindRequest = AttachmentDavRequest.chunkPropfind(
      context: _context(21),
      davUserId: _davUser,
      uploadSessionId: session,
    );
    final move = AttachmentDavRequest.chunkMove(
      context: _context(22),
      davUserId: _davUser,
      uploadSessionId: session,
      remotePath: _remotePath,
      totalLength: _chunkBytes.length,
    );
    final cleanup = AttachmentDavRequest.cleanupChunkSession(
      context: _context(23),
      davUserId: _davUser,
      uploadSessionId: session,
    );

    expect(
      (await transport.sendDav(
        request: mkcol,
        authorization: _authorization,
      )).classification,
      AttachmentDavClassification.success,
    );
    final propfind = await transport.sendDav(
      request: propfindRequest,
      authorization: _authorization,
      fileSize: _chunkBytes.length,
    );
    expect(propfind.classification, AttachmentDavClassification.success);
    expect(propfind.manifest!.chunks, isEmpty);
    expect(
      (await transport.sendDav(
        request: move,
        authorization: _authorization,
      )).classification,
      AttachmentDavClassification.success,
    );
    expect(
      (await transport.sendDav(
        request: cleanup,
        authorization: _authorization,
      )).classification,
      AttachmentDavClassification.success,
    );
    expect(methods, <String>['MKCOL', 'PROPFIND', 'MOVE', 'DELETE']);
  });

  test('preserves OCS 401, 429 and 5xx classifications', () async {
    for (final testCase in <(int, AttachmentProbeClassification)>[
      (401, AttachmentProbeClassification.reauthenticationRequired),
      (429, AttachmentProbeClassification.transientFailure),
      (503, AttachmentProbeClassification.transientFailure),
    ]) {
      final transport = _transport(
        MockClient(
          (_) async =>
              http.Response.bytes(_ocsFailureBody(testCase.$1), testCase.$1),
        ),
      );
      final response = await transport.probe(
        request: AttachmentProbeRequest(
          context: _context(100 + testCase.$1),
          fileNames: const <String>['photo.jpg'],
        ),
        authorization: _authorization,
      );
      expect(response.classification, testCase.$2);
    }

    for (final testCase in <(int, AttachmentFinalizeClassification)>[
      (401, AttachmentFinalizeClassification.reauthenticationRequired),
      (429, AttachmentFinalizeClassification.ambiguous),
      (500, AttachmentFinalizeClassification.ambiguous),
    ]) {
      final transport = _transport(
        MockClient(
          (_) async =>
              http.Response.bytes(_ocsFailureBody(testCase.$1), testCase.$1),
        ),
      );
      final response = await transport.finalize(
        request: _finalizeRequest(200 + testCase.$1),
        authorization: _authorization,
      );
      expect(response.classification, testCase.$2);
    }
  });

  test(
    'preserves DAV 401, 429, 5xx, quota and permission classifications',
    () async {
      for (final testCase in <(int, AttachmentDavClassification)>[
        (401, AttachmentDavClassification.reauthenticationRequired),
        (429, AttachmentDavClassification.transientFailure),
        (503, AttachmentDavClassification.transientFailure),
        (507, AttachmentDavClassification.quotaExceeded),
        (403, AttachmentDavClassification.permissionDenied),
      ]) {
        final transport = _transport(
          MockClient((_) async => http.Response('', testCase.$1)),
        );
        final response = await transport.sendDav(
          request: AttachmentDavRequest.chunkMkcol(
            context: _context(300 + testCase.$1),
            davUserId: _davUser,
            uploadSessionId: _uploadSession(),
          ),
          authorization: _authorization,
        );
        expect(response.classification, testCase.$2);
      }
    },
  );

  test('wraps malformed DAV XML as stage-aware response error', () async {
    final request = AttachmentDavRequest.chunkPropfind(
      context: _context(30),
      davUserId: _davUser,
      uploadSessionId: _uploadSession(),
    );
    final transport = _transport(
      MockClient((_) async => http.Response('not-xml', 207)),
    );

    await expectLater(
      transport.sendDav(
        request: request,
        authorization: _authorization,
        fileSize: _chunkBytes.length,
      ),
      throwsA(
        _transportError(
          AttachmentTransportError.invalidResponse,
          stage: AttachmentTransportStage.decoding,
          requestMayHaveReachedServer: true,
        ),
      ),
    );
  });

  test('rejects oversized streaming response without Content-Length', () async {
    final transport = HttpAttachmentTransport(
      client: MockClient.streaming((_, bodyStream) async {
        await bodyStream.drain<void>();
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable(<List<int>>[
            Uint8List(attachmentMaximumResponseBytes ~/ 2 + 1),
            Uint8List(attachmentMaximumResponseBytes ~/ 2 + 1),
          ]),
          200,
        );
      }),
      sourceProvider: _MemorySourceProvider(const <String, List<int>>{}),
    );

    await expectLater(
      transport.probe(
        request: AttachmentProbeRequest(
          context: _context(31),
          fileNames: const <String>['photo.jpg'],
        ),
        authorization: _authorization,
      ),
      throwsA(
        _transportError(
          AttachmentTransportError.responseTooLarge,
          stage: AttachmentTransportStage.response,
          requestMayHaveReachedServer: true,
        ),
      ),
    );
  });
}
