import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/network/attachment_transport.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  group('HttpAttachmentTransport', () {
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

    test('executes finalize JSON with the planner body', () async {
      late http.Request captured;
      final transport = _transport(
        MockClient((request) async {
          captured = request;
          return http.Response.bytes(_finalizeSuccessBody(), 200);
        }),
      );
      final request = _finalizeRequest(3, withMetadata: true);

      final response = await transport.finalize(
        request: request,
        authorization: _authorization,
      );

      expect(
        response.classification,
        AttachmentFinalizeClassification.accepted,
      );
      expect(captured.method, 'POST');
      final body = jsonDecode(captured.body) as Map<String, Object?>;
      expect(body['filePath'], 'Talk/Synthetic room/Draft/temp.bin');
      expect(body['fileName'], 'attachment.bin');
      expect(body['allowUpdate'], isFalse);
      expect(jsonDecode(body['talkMetaData']! as String), <String, Object?>{
        'caption': 'Synthetic caption',
        'silent': true,
        'replyTo': 42,
        'threadId': 42,
        'threadTitle': 'Synthetic thread',
      });
    });

    test(
      'marks malformed finalize as post-dispatch decoding failure',
      () async {
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
      },
    );

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

    test(
      'reuses one verified source snapshot across multiple chunks',
      () async {
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
      },
    );

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

    test(
      'rejects oversized streaming response without Content-Length',
      () async {
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
      },
    );

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

    test(
      'pre-cancelled controller invokes a late registration exactly once',
      () {
        final controller = AttachmentCancellationController();
        controller.cancel();
        var invocationCount = 0;

        final registration = controller.signal.register(() {
          invocationCount++;
        });
        registration.detach();
        controller.cancel();

        expect(invocationCount, 1);
      },
    );

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

    test(
      'closes a lease returned after acquisition cancellation once',
      () async {
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
      },
    );

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

    test(
      'streaming upload applies backpressure between source chunks',
      () async {
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
        expect(
          (await future).classification,
          AttachmentDavClassification.success,
        );
        await transport.releaseSource(verified);
      },
    );

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
  });
}

const String _loginName = 'fixture-user';
const String _appPassword = 'fixture-app-password';
final String _authorizationHeader =
    'Basic ${base64Encode(utf8.encode('$_loginName:$_appPassword'))}';
const String _sourceHandle = 'app-owned-synthetic-source';
const String _normalSha256 =
    '7fa36b95d5c98859ed72b4787f3c28b29eaa103970786755c9711cbb19be631c';
const String _chunkSha256 =
    '9f9f5111f7b27a781f1f1ddde5ebc2dd2b796bfc7365c9c28b548e564176929f';
final List<int> _normalBytes = utf8.encode('hello attachment');
final List<int> _chunkBytes = utf8.encode('0123456789abcdef');
final ServerBase _server = ServerBase.parse(
  'https://cloud.example.invalid/nextcloud',
);
final AccountId _account = AccountId.parse('account-a');
final ConversationToken _room = ConversationToken.parse(
  'rooma123',
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidAttachmentModel,
);
final DavUserId _davUser = DavUserId.parse('fixture-user');
final DavRelativePath _remotePath = DavRelativePath.parse(
  'Talk/Synthetic room/Draft/temp.bin',
);
final AttachmentTransportAuthorization _authorization =
    AttachmentTransportAuthorization(
      accountId: _account,
      server: _server,
      loginName: _loginName,
      appPassword: _appPassword,
    );

HttpAttachmentTransport _transport(http.Client client) =>
    HttpAttachmentTransport(
      client: client,
      sourceProvider: _MemorySourceProvider(const <String, List<int>>{}),
    );

AttachmentRequestContext _context(int requestNumber) =>
    AttachmentRequestContext(
      accountId: _account,
      requestId: AttachmentRequestId.parse('attachment-request-$requestNumber'),
      jobId: AttachmentJobId.parse('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
      server: _server,
      roomToken: _room,
      capabilityGeneration: 7,
      contractRevision: attachmentReplayContractRevision,
    );

PreparedAttachmentSource _source(
  List<int> bytes, {
  required String sha256,
  String handle = _sourceHandle,
}) => PreparedAttachmentSource(
  handle: AttachmentSourceHandle.parse(handle),
  ownership: AttachmentSourceOwnership.appOwnedCopy,
  byteLength: bytes.length,
  sha256: AttachmentSha256.parse(sha256),
  mimeType: 'application/octet-stream',
  displayName: 'attachment.bin',
);

AttachmentFinalizeRequest _finalizeRequest(
  int requestNumber, {
  bool withMetadata = false,
}) => AttachmentFinalizeRequest(
  context: _context(requestNumber),
  remoteTemporaryPath: _remotePath,
  source: _source(_normalBytes, sha256: _normalSha256),
  referenceId: ChatReferenceId.parse('11111111-1111-4111-8111-111111111111'),
  metadata: AttachmentMetadata(
    kind: AttachmentMessageKind.file,
    caption: withMetadata ? 'Synthetic caption' : null,
    replyTo: withMetadata ? 42 : null,
    threadId: withMetadata ? 42 : null,
    threadTitle: withMetadata ? 'Synthetic thread' : null,
    silent: withMetadata,
  ),
);

DavUploadSessionId _uploadSession() =>
    DavUploadSessionId.parse('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');

Uint8List _probeSuccessBody() => _ocsBody(
  status: 'ok',
  statusCode: 200,
  data: <String, Object?>{
    'folder': 'Talk/Synthetic room/Draft',
    'renames': <Object?>[
      <String, Object?>{'photo.jpg': 'photo (1).jpg'},
    ],
  },
);

Uint8List _finalizeSuccessBody() => _ocsBody(
  status: 'ok',
  statusCode: 200,
  data: <String, Object?>{
    'renames': <Object?>[
      <String, Object?>{'attachment.bin': 'attachment (1).bin'},
    ],
  },
);

Uint8List _ocsFailureBody(int statusCode) => _ocsBody(
  status: 'failure',
  statusCode: statusCode,
  data: <String, Object?>{},
);

Uint8List _ocsBody({
  required String status,
  required int statusCode,
  required Object? data,
}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': status,
          'statuscode': statusCode,
          'message': 'Synthetic response',
        },
        'data': data,
      },
    }),
  ),
);

String _emptyDavManifest(Uri sessionUri) =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:multistatus xmlns:d="DAV:">'
    '<d:response><d:href>${sessionUri.path}/</d:href>'
    '<d:propstat><d:prop><d:resourcetype><d:collection/>'
    '</d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status>'
    '</d:propstat></d:response></d:multistatus>';

Matcher _transportError(
  AttachmentTransportError code, {
  AttachmentTransportStage? stage,
  bool? requestMayHaveReachedServer,
}) {
  var matcher = isA<AttachmentTransportException>().having(
    (error) => error.code,
    'code',
    code,
  );
  if (stage != null) {
    matcher = matcher.having((error) => error.stage, 'stage', stage);
  }
  if (requestMayHaveReachedServer != null) {
    matcher = matcher.having(
      (error) => error.requestMayHaveReachedServer,
      'requestMayHaveReachedServer',
      requestMayHaveReachedServer,
    );
  }
  return matcher;
}

final class _MemorySourceProvider implements AttachmentSourceProvider {
  _MemorySourceProvider(
    Map<String, List<int>> sources, {
    this.stallClose = false,
  }) : _sources = Map<String, Uint8List>.unmodifiable(
         sources.map((key, value) => MapEntry(key, Uint8List.fromList(value))),
       );

  final Map<String, Uint8List> _sources;
  final bool stallClose;
  int openCount = 0;
  _MemorySourceLease? lastLease;

  @override
  Future<AttachmentSourceLease> open(
    AttachmentSourceHandle handle, {
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    openCount++;
    final bytes = _sources[handle.value];
    if (bytes == null) {
      throw StateError('Synthetic source missing.');
    }
    return lastLease = _MemorySourceLease(bytes, stallClose: stallClose);
  }
}

final class _MemorySourceLease implements AttachmentSourceLease {
  _MemorySourceLease(this._bytes, {required this.stallClose});

  final Uint8List _bytes;
  final bool stallClose;
  int readCount = 0;
  int physicalBytesRead = 0;
  int closeCount = 0;
  final List<(int, int?)> requestedRanges = <(int, int?)>[];
  final Completer<void> closed = Completer<void>();

  @override
  Stream<List<int>> openRead({int offset = 0, int? length}) {
    readCount++;
    requestedRanges.add((offset, length));
    final end = length == null || offset + length > _bytes.length
        ? _bytes.length
        : offset + length;
    physicalBytesRead += end - offset;
    final chunks = <List<int>>[];
    for (var chunkOffset = offset; chunkOffset < end; chunkOffset += 3) {
      final chunkEnd = chunkOffset + 3 < end ? chunkOffset + 3 : end;
      chunks.add(_bytes.sublist(chunkOffset, chunkEnd));
    }
    return Stream<List<int>>.fromIterable(chunks);
  }

  @override
  Future<void> close() async {
    closeCount++;
    if (!closed.isCompleted) {
      closed.complete();
    }
    if (stallClose) {
      await Completer<void>().future;
    }
  }
}

final class _BackpressureSourceProvider implements AttachmentSourceProvider {
  _BackpressureSourceProvider({required this.handle, required List<int> bytes})
    : _bytes = Uint8List.fromList(bytes);

  final String handle;
  final Uint8List _bytes;
  int uploadChunksPulled = 0;

  @override
  Future<AttachmentSourceLease> open(
    AttachmentSourceHandle sourceHandle, {
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    if (sourceHandle.value != handle) {
      throw StateError('Synthetic source missing.');
    }
    return _BackpressureSourceLease(
      _bytes,
      onUploadChunk: () => uploadChunksPulled++,
    );
  }
}

final class _BackpressureSourceLease implements AttachmentSourceLease {
  _BackpressureSourceLease(this._bytes, {required this.onUploadChunk});

  final Uint8List _bytes;
  final void Function() onUploadChunk;
  int _readCount = 0;

  @override
  Stream<List<int>> openRead({int offset = 0, int? length}) {
    _readCount++;
    final end = length == null || offset + length > _bytes.length
        ? _bytes.length
        : offset + length;
    final range = _bytes.sublist(offset, end);
    if (_readCount == 1) {
      return Stream<List<int>>.value(range);
    }
    return _uploadStream(range);
  }

  Stream<List<int>> _uploadStream(List<int> range) async* {
    for (final byte in range) {
      onUploadChunk();
      yield <int>[byte];
    }
  }

  @override
  Future<void> close() async {}
}

final class _DelayedSourceProvider implements AttachmentSourceProvider {
  final Completer<void> openStarted = Completer<void>();
  final Completer<AttachmentSourceLease> _opened =
      Completer<AttachmentSourceLease>();
  _MemorySourceLease? lease;

  @override
  Future<AttachmentSourceLease> open(
    AttachmentSourceHandle handle, {
    AttachmentCancellationSignal? cancellationSignal,
  }) {
    openStarted.complete();
    return _opened.future;
  }

  void completeWith(List<int> bytes) {
    final openedLease = _MemorySourceLease(
      Uint8List.fromList(bytes),
      stallClose: false,
    );
    lease = openedLease;
    _opened.complete(openedLease);
  }
}

final class _CancelFailingSourceProvider implements AttachmentSourceProvider {
  _CancelFailingSourceProvider(List<int> bytes)
    : _bytes = Uint8List.fromList(bytes);

  final Uint8List _bytes;
  _CancelFailingSourceLease? lease;

  @override
  Future<AttachmentSourceLease> open(
    AttachmentSourceHandle handle, {
    AttachmentCancellationSignal? cancellationSignal,
  }) async => lease = _CancelFailingSourceLease(_bytes);
}

final class _CancelFailingSourceLease implements AttachmentSourceLease {
  _CancelFailingSourceLease(this._bytes);

  final Uint8List _bytes;
  int _readCount = 0;
  int uploadCancelCount = 0;

  @override
  Stream<List<int>> openRead({int offset = 0, int? length}) {
    _readCount++;
    final end = length == null || offset + length > _bytes.length
        ? _bytes.length
        : offset + length;
    final range = _bytes.sublist(offset, end);
    if (_readCount == 1) {
      return Stream<List<int>>.value(range);
    }
    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () => controller.add(range),
      onCancel: () {
        uploadCancelCount++;
        return Future<void>.error(StateError('Synthetic cancel failure.'));
      },
    );
    return controller.stream;
  }

  @override
  Future<void> close() async {}
}

final class _InspectableCancellationSignal
    implements AttachmentCancellationSignal {
  _InspectableCancellationSignal(this._delegate);

  final AttachmentCancellationSignal _delegate;
  int _activeRegistrationCount = 0;
  int registrationCount = 0;
  int maximumActiveRegistrationCount = 0;
  int callbackInvocationCount = 0;

  int get activeRegistrationCount => _activeRegistrationCount;

  @override
  bool get isCancelled => _delegate.isCancelled;

  @override
  AttachmentCancellationRegistration register(
    FutureOr<void> Function() action,
  ) {
    registrationCount++;
    _activeRegistrationCount++;
    if (_activeRegistrationCount > maximumActiveRegistrationCount) {
      maximumActiveRegistrationCount = _activeRegistrationCount;
    }
    final registration = _delegate.register(() {
      callbackInvocationCount++;
      return action();
    });
    return _InspectableCancellationRegistration(
      registration,
      onDetach: () => _activeRegistrationCount--,
    );
  }
}

final class _InspectableCancellationRegistration
    implements AttachmentCancellationRegistration {
  _InspectableCancellationRegistration(
    this._delegate, {
    required this.onDetach,
  });

  final AttachmentCancellationRegistration _delegate;
  final void Function() onDetach;
  bool _detached = false;

  @override
  void detach() {
    if (_detached) {
      return;
    }
    _detached = true;
    _delegate.detach();
    onDetach();
  }
}

final class _SilentPreCancelledSignal implements AttachmentCancellationSignal {
  final AttachmentCancellationController _delegate =
      AttachmentCancellationController();

  @override
  bool get isCancelled => true;

  @override
  AttachmentCancellationRegistration register(
    FutureOr<void> Function() action,
  ) => _delegate.signal.register(() {});
}
