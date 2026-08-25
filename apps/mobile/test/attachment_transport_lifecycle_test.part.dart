part of 'attachment_transport_test.dart';

void _registerLifecycleTests() {
  test('rejects redirect without follow or credential leak', () async {
    late http.Request captured;
    final transport = _transport(
      MockClient((request) async {
        captured = request;
        return http.Response(
          'redirect body',
          302,
          headers: const <String, String>{
            'location': 'https://other.example.invalid/collect',
          },
        );
      }),
    );

    Object? caught;
    try {
      await transport.probe(
        request: AttachmentProbeRequest(
          context: _context(32),
          fileNames: const <String>['photo.jpg'],
        ),
        authorization: _authorization,
      );
    } on Object catch (error) {
      caught = error;
    }

    expect(
      caught,
      _transportError(
        AttachmentTransportError.redirectRejected,
        stage: AttachmentTransportStage.response,
        requestMayHaveReachedServer: true,
      ),
    );
    expect(captured.followRedirects, isFalse);
    expect(captured.maxRedirects, 0);
    expect(caught.toString(), isNot(contains(_loginName)));
    expect(caught.toString(), isNot(contains(_appPassword)));
    expect(caught.toString(), isNot(contains('other.example.invalid')));
  });

  test('caller cancellation completes real request abort trigger', () async {
    final entered = Completer<void>();
    final abortObserved = Completer<void>();
    final callerCancellation = AttachmentCancellationController();
    final transport = HttpAttachmentTransport(
      client: MockClient.streaming((request, _) async {
        final trigger = (request as http.Abortable).abortTrigger!;
        entered.complete();
        await trigger;
        abortObserved.complete();
        throw http.RequestAbortedException(request.url);
      }),
      sourceProvider: _MemorySourceProvider(const <String, List<int>>{}),
    );
    final future = transport.probe(
      request: AttachmentProbeRequest(
        context: _context(33),
        fileNames: const <String>['photo.jpg'],
      ),
      authorization: _authorization,
      cancellationSignal: callerCancellation.signal,
    );

    await entered.future;
    callerCancellation.cancel();
    await expectLater(
      future,
      throwsA(_transportError(AttachmentTransportError.cancelled)),
    );
    await abortObserved.future;
  });

  test('pre-cancelled controller invokes a late registration exactly once', () {
    final controller = AttachmentCancellationController();
    controller.cancel();
    var invocationCount = 0;

    final registration = controller.signal.register(() {
      invocationCount++;
    });
    registration.detach();
    controller.cancel();

    expect(invocationCount, 1);
  });

  test(
    'rejects a silent pre-cancelled custom signal before dispatch',
    () async {
      var dispatchCount = 0;
      final transport = _transport(
        MockClient((_) async {
          dispatchCount++;
          return http.Response.bytes(_probeSuccessBody(), 200);
        }),
      );

      await expectLater(
        transport.probe(
          request: AttachmentProbeRequest(
            context: _context(329),
            fileNames: const <String>['photo.jpg'],
          ),
          authorization: _authorization,
          cancellationSignal: _SilentPreCancelledSignal(),
        ),
        throwsA(_transportError(AttachmentTransportError.cancelled)),
      );
      expect(dispatchCount, 0);
    },
  );

  test(
    'detaches one job cancellation signal after every sequential chunk',
    () async {
      final cancellationController = AttachmentCancellationController();
      final cancellation = _InspectableCancellationSignal(
        cancellationController.signal,
      );
      final provider = _MemorySourceProvider(<String, List<int>>{
        _sourceHandle: _chunkBytes,
      });
      final transport = HttpAttachmentTransport(
        client: MockClient((_) async {
          expect(cancellation.activeRegistrationCount, 1);
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

      for (var index = 0; index < _chunkBytes.length; index++) {
        final response = await transport.sendDav(
          request: AttachmentDavRequest.chunkPut(
            context: _context(330 + index),
            davUserId: _davUser,
            uploadSessionId: session,
            source: prepared,
            range: DavChunkRange(
              start: index,
              end: index,
              fileSize: _chunkBytes.length,
            ),
          ),
          authorization: _authorization,
          cancellationSignal: cancellation,
          verifiedSource: verified,
        );

        expect(response.classification, AttachmentDavClassification.success);
        expect(cancellation.activeRegistrationCount, 0);
      }
      await transport.releaseSource(verified);

      expect(cancellation.registrationCount, _chunkBytes.length);
      expect(cancellation.maximumActiveRegistrationCount, 1);
      expect(cancellation.callbackInvocationCount, 0);
      cancellationController.cancel();
      expect(cancellation.callbackInvocationCount, 0);
    },
  );

  test('closes a lease returned after acquisition cancellation once', () async {
    final provider = _DelayedSourceProvider();
    final transport = HttpAttachmentTransport(
      client: MockClient((_) async => fail('HTTP must not be called')),
      sourceProvider: provider,
    );
    final callerCancellation = AttachmentCancellationController();
    final future = transport.verifySource(
      source: _source(_normalBytes, sha256: _normalSha256),
      authorization: _authorization,
      cancellationSignal: callerCancellation.signal,
    );

    await provider.openStarted.future;
    callerCancellation.cancel();
    await expectLater(
      future,
      throwsA(_transportError(AttachmentTransportError.cancelled)),
    );
    provider.completeWith(_normalBytes);
    await provider.lease!.closed.future;

    expect(provider.lease!.closeCount, 1);
  });

  test(
    'rejects and closes a lease returned after transport close once',
    () async {
      final provider = _DelayedSourceProvider();
      final transport = HttpAttachmentTransport(
        client: MockClient((_) async => fail('HTTP must not be called')),
        sourceProvider: provider,
      );
      final future = transport.verifySource(
        source: _source(_normalBytes, sha256: _normalSha256),
        authorization: _authorization,
      );

      await provider.openStarted.future;
      final failure = expectLater(
        future,
        throwsA(_transportError(AttachmentTransportError.closed)),
      );
      await transport.close();
      provider.completeWith(_normalBytes);
      await failure;
      await provider.lease!.closed.future;

      expect(provider.lease!.closeCount, 1);
    },
  );

  test('connect timeout aborts a request with no progress', () async {
    final entered = Completer<void>();
    final abortObserved = Completer<void>();
    final transport = HttpAttachmentTransport(
      client: MockClient.streaming((request, _) async {
        final trigger = (request as http.Abortable).abortTrigger!;
        entered.complete();
        await trigger;
        abortObserved.complete();
        throw http.RequestAbortedException(request.url);
      }),
      sourceProvider: _MemorySourceProvider(const <String, List<int>>{}),
      connectTimeout: const Duration(milliseconds: 80),
      idleTimeout: const Duration(seconds: 1),
    );
    final future = transport.probe(
      request: AttachmentProbeRequest(
        context: _context(34),
        fileNames: const <String>['photo.jpg'],
      ),
      authorization: _authorization,
    );

    await entered.future;
    await expectLater(
      future,
      throwsA(_transportError(AttachmentTransportError.connectTimeout)),
    );
    await abortObserved.future;
  });

  test(
    'idle timeout resets on upload progress and aborts stalled response',
    () async {
      final bodyReceived = Completer<void>();
      final abortObserved = Completer<void>();
      final provider = _MemorySourceProvider(<String, List<int>>{
        _sourceHandle: _normalBytes,
      });
      final transport = HttpAttachmentTransport(
        client: MockClient.streaming((request, bodyStream) async {
          await bodyStream.drain<void>();
          bodyReceived.complete();
          final trigger = (request as http.Abortable).abortTrigger!;
          await trigger;
          abortObserved.complete();
          throw http.RequestAbortedException(request.url);
        }),
        sourceProvider: provider,
        connectTimeout: const Duration(seconds: 1),
        idleTimeout: const Duration(milliseconds: 100),
      );
      final prepared = _source(_normalBytes, sha256: _normalSha256);
      final verified = await transport.verifySource(
        source: prepared,
        authorization: _authorization,
      );
      final future = transport.sendDav(
        request: AttachmentDavRequest.normalPut(
          context: _context(35),
          davUserId: _davUser,
          remotePath: _remotePath,
          source: prepared,
        ),
        authorization: _authorization,
        verifiedSource: verified,
      );

      await bodyReceived.future;
      await expectLater(
        future,
        throwsA(_transportError(AttachmentTransportError.idleTimeout)),
      );
      await abortObserved.future;
      await transport.releaseSource(verified);
    },
  );

  test('SHA-256 padding boundaries 55, 56, 63, 64 and 65 verify', () async {
    const hashes = <int, String>{
      55: '463eb28e72f82e0a96c0a4cc53690c571281131f672aa229e0d45ae59b598b59',
      56: 'da2ae4d6b36748f2a318f23e7ab1dfdf45acdc9d049bd80e59de82a60895f562',
      63: '29af2686fd53374a36b0846694cc342177e428d1647515f078784d69cdb9e488',
      64: 'fdeab9acf3710362bd2658cdc9a29e8f9c757fcf9811603a8c447cd1d9151108',
      65: '4bfd2c8b6f1eec7a2afeb48b934ee4b2694182027e6d0fc075074f2fabb31781',
    };
    for (final entry in hashes.entries) {
      final bytes = List<int>.generate(entry.key, (index) => index);
      final handle = 'boundary-source-${entry.key}';
      final provider = _MemorySourceProvider(<String, List<int>>{
        handle: bytes,
      });
      final transport = HttpAttachmentTransport(
        client: MockClient((_) async => fail('HTTP must not be called')),
        sourceProvider: provider,
      );
      final verified = await transport.verifySource(
        source: _source(bytes, sha256: entry.value, handle: handle),
        authorization: _authorization,
      );
      expect(verified.byteLength, entry.key);
      await transport.releaseSource(verified);
    }
  });

  test('streaming upload applies backpressure between source chunks', () async {
    final bytes = List<int>.generate(64, (index) => index);
    final provider = _BackpressureSourceProvider(
      handle: 'backpressure-source',
      bytes: bytes,
    );
    final firstWireChunk = Completer<void>();
    final resumeWire = Completer<void>();
    final transport = HttpAttachmentTransport(
      client: MockClient.streaming((_, bodyStream) async {
        final iterator = StreamIterator<List<int>>(bodyStream);
        expect(await iterator.moveNext(), isTrue);
        firstWireChunk.complete();
        await resumeWire.future;
        while (await iterator.moveNext()) {}
        await iterator.cancel();
        return http.StreamedResponse(const Stream<List<int>>.empty(), 201);
      }),
      sourceProvider: provider,
      connectTimeout: const Duration(seconds: 2),
      idleTimeout: const Duration(seconds: 2),
    );
    final prepared = _source(
      bytes,
      sha256:
          'fdeab9acf3710362bd2658cdc9a29e8f9c757fcf9811603a8c447cd1d9151108',
      handle: 'backpressure-source',
    );
    final verified = await transport.verifySource(
      source: prepared,
      authorization: _authorization,
    );
    final future = transport.sendDav(
      request: AttachmentDavRequest.normalPut(
        context: _context(36),
        davUserId: _davUser,
        remotePath: _remotePath,
        source: prepared,
      ),
      authorization: _authorization,
      verifiedSource: verified,
    );

    await firstWireChunk.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(provider.uploadChunksPulled, lessThan(bytes.length));
    resumeWire.complete();
    expect((await future).classification, AttachmentDavClassification.success);
    await transport.releaseSource(verified);
  });

  test('bounds post-dispatch lease cleanup and redacts failure', () async {
    final provider = _MemorySourceProvider(<String, List<int>>{
      _sourceHandle: _normalBytes,
    }, stallClose: true);
    final transport = HttpAttachmentTransport(
      client: MockClient((_) async => http.Response('', 201)),
      sourceProvider: provider,
      cleanupTimeout: const Duration(milliseconds: 60),
    );
    final prepared = _source(_normalBytes, sha256: _normalSha256);
    final verified = await transport.verifySource(
      source: prepared,
      authorization: _authorization,
    );
    await transport.sendDav(
      request: AttachmentDavRequest.normalPut(
        context: _context(37),
        davUserId: _davUser,
        remotePath: _remotePath,
        source: prepared,
      ),
      authorization: _authorization,
      verifiedSource: verified,
    );
    final elapsed = Stopwatch()..start();

    Object? caught;
    try {
      await transport.releaseSource(verified);
    } on Object catch (error) {
      caught = error;
    }
    elapsed.stop();

    expect(
      caught,
      _transportError(
        AttachmentTransportError.cleanupFailed,
        stage: AttachmentTransportStage.cleanup,
        requestMayHaveReachedServer: true,
      ),
    );
    expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(caught.toString(), isNot(contains(_sourceHandle)));
  });

  test(
    'closes the request sink when source cancellation cleanup fails',
    () async {
      final provider = _CancelFailingSourceProvider(_normalBytes);
      final bodyClosed = Completer<void>();
      final transport = HttpAttachmentTransport(
        client: MockClient.streaming((_, bodyStream) async {
          bodyStream.listen(
            (_) {},
            onDone: () => bodyClosed.complete(),
            onError: (_) {
              if (!bodyClosed.isCompleted) {
                bodyClosed.complete();
              }
            },
          );
          return http.StreamedResponse(const Stream<List<int>>.empty(), 201);
        }),
        sourceProvider: provider,
        cleanupTimeout: const Duration(milliseconds: 100),
      );
      final prepared = _source(_normalBytes, sha256: _normalSha256);
      final verified = await transport.verifySource(
        source: prepared,
        authorization: _authorization,
      );

      await expectLater(
        transport.sendDav(
          request: AttachmentDavRequest.normalPut(
            context: _context(38),
            davUserId: _davUser,
            remotePath: _remotePath,
            source: prepared,
          ),
          authorization: _authorization,
          verifiedSource: verified,
        ),
        throwsA(
          _transportError(
            AttachmentTransportError.cleanupFailed,
            stage: AttachmentTransportStage.cleanup,
            requestMayHaveReachedServer: true,
          ),
        ),
      );

      expect(bodyClosed.isCompleted, isTrue);
      expect(provider.lease!.uploadCancelCount, 1);
      await transport.releaseSource(verified);
    },
  );
}
