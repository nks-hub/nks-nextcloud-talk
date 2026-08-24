import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/attachment_repository.dart';
import 'package:nextcloudtalk/features/chat/attachment_service.dart';
import 'package:nextcloudtalk/network/attachment_transport.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  test(
    'normal upload is durable before enqueue returns and reconciles',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final methods = <String>[];
      final service = fixture.service(
        MockClient((request) async {
          methods.add(request.method);
          if (request.method == 'POST' &&
              request.url.path.endsWith('/folder')) {
            return http.Response.bytes(_probeSuccess(), 200);
          }
          if (request.method == 'PUT') {
            expect(request.bodyBytes, fixture.bytes);
            return http.Response('', 201);
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/attachment')) {
            return http.Response.bytes(_finalizeSuccess(), 200);
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
      );
      addTearDown(service.close);

      final session = await service.enqueue(fixture.request(normalMaximum: 32));
      final persisted = await fixture.repository.getStoredJob(
        accountId: 'account-a',
        jobId: session.jobId.value,
      );

      expect(persisted, isNotNull);
      expect(persisted!.phase, isNot(AttachmentJobPhase.completed.name));
      final awaiting = await session.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
      );
      expect(awaiting.progress, 1);
      expect(methods, ['POST', 'PUT', 'POST']);

      await fixture.cacheConfirmation(messageId: 101);
      final completed = await session.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.completed,
      );

      expect(completed.messageIds, [101]);
      await _expectFileRemoved(fixture.sourceFile);
    },
  );

  test(
    'chunk upload executes FIFO ranges and moves before finalizing',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final seen = <String>[];
      final service = fixture.service(
        MockClient((request) async {
          seen.add('${request.method} ${request.url.pathSegments.last}');
          if (request.method == 'POST' &&
              request.url.path.endsWith('/folder')) {
            return http.Response.bytes(_probeSuccess(), 200);
          }
          if (request.method == 'MKCOL') {
            return http.Response('', 201);
          }
          if (request.method == 'PROPFIND') {
            return http.Response(
              _emptyManifest(request.url),
              207,
              headers: const {'content-type': 'application/xml'},
            );
          }
          if (request.method == 'PUT') {
            return http.Response('', 201);
          }
          if (request.method == 'MOVE') {
            return http.Response('', 201);
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/attachment')) {
            return http.Response.bytes(_finalizeSuccess(), 200);
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
      );
      addTearDown(service.close);

      final session = await service.enqueue(fixture.request(normalMaximum: 4));
      await session.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
      );

      expect(seen.map((value) => value.split(' ').first), [
        'POST',
        'MKCOL',
        'PROPFIND',
        'PUT',
        'PUT',
        'MOVE',
        'POST',
      ]);
    },
  );

  test('ambiguous finalize waits for authoritative confirmation', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final service = fixture.service(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
          return http.Response.bytes(_probeSuccess(), 200);
        }
        if (request.method == 'PUT') {
          return http.Response('', 201);
        }
        throw http.ClientException('Synthetic post-dispatch failure');
      }),
    );
    addTearDown(service.close);

    final session = await service.enqueue(fixture.request(normalMaximum: 32));
    final awaiting = await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
    );

    expect(awaiting.errorClass, 'ambiguous-finalize-transport');
    expect(await fixture.sourceFile.exists(), isTrue);
    await fixture.cacheConfirmation(messageId: 102);
    await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.completed,
    );
  });

  test('cached message completes a job that is admitted later', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    await fixture.cacheConfirmation(messageId: 103);
    final service = fixture.service(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
          return http.Response.bytes(_probeSuccess(), 200);
        }
        if (request.method == 'PUT') {
          return http.Response('', 201);
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/attachment')) {
          return http.Response.bytes(_finalizeSuccess(), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(service.close);

    final session = await service.enqueue(fixture.request(normalMaximum: 32));
    final completed = await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.completed,
    );

    expect(completed.messageIds, [103]);
    await _expectFileRemoved(fixture.sourceFile);
  });

  test(
    'startup reconciles a cached message with a recovered finalize',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final jobId = await fixture.seedInFlight(AttachmentRequestStep.finalize);
      await fixture.cacheConfirmation(messageId: 104);
      final service = fixture.service(_unexpectedClient());
      addTearDown(service.close);

      await service.ready;
      final completed = await service
          .watchJob(accountId: AccountId.parse('account-a'), jobId: jobId)
          .firstWhere((event) => event.phase == AttachmentJobPhase.completed);

      expect(completed.messageIds, [104]);
      await _expectFileRemoved(fixture.sourceFile);
    },
  );

  test(
    'startup catch-up retries and reconciles only authoritative cache',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final jobId = await fixture.seedInFlight(AttachmentRequestStep.finalize);
      var catchUpCalls = 0;
      final service = fixture.service(
        _unexpectedClient(),
        watchConfirmationCandidates: () => const Stream.empty(),
        confirmationRetryDelays: const <Duration>[Duration.zero],
        catchUpConfirmation:
            ({
              required accountId,
              required roomToken,
              required threadId,
            }) async {
              expect(accountId.value, 'account-a');
              expect(roomToken.value, 'rooma123');
              expect(threadId, isNull);
              catchUpCalls++;
              if (catchUpCalls == 1) {
                throw StateError('Synthetic first catch-up failure');
              }
              await fixture.cacheConfirmation(messageId: 110);
            },
      );
      addTearDown(service.close);

      await service.ready;
      final completed = await service
          .watchJob(accountId: AccountId.parse('account-a'), jobId: jobId)
          .firstWhere((event) => event.phase == AttachmentJobPhase.completed)
          .timeout(const Duration(seconds: 2));

      expect(catchUpCalls, 2);
      expect(completed.messageIds, [110]);
      await _expectFileRemoved(fixture.sourceFile);
    },
  );

  test('pending confirmation allows a later room DAV upload', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    var uploaded = 0;
    var finalized = 0;
    final service = fixture.service(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
          return http.Response.bytes(_probeSuccess(), 200);
        }
        if (request.method == 'PUT') {
          uploaded++;
          return http.Response('', 201);
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/attachment')) {
          finalized++;
          return http.Response.bytes(_finalizeSuccess(), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
      identifierFactory: _SequentialIdentifierFactory(),
    );
    addTearDown(service.close);

    final first = await service.enqueue(fixture.request(normalMaximum: 32));
    await first.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
    );
    final second = await service.enqueue(fixture.request(normalMaximum: 32));
    final secondUploaded = await second.events
        .firstWhere((event) => event.phase == AttachmentJobPhase.uploaded)
        .timeout(const Duration(seconds: 2));

    expect(secondUploaded.phase, AttachmentJobPhase.uploaded);
    expect(uploaded, 2);
    expect(finalized, 1);
    await fixture.cacheConfirmation(messageId: 112);
    await first.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.completed,
    );
    await second.events
        .firstWhere(
          (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
        )
        .timeout(const Duration(seconds: 2));

    expect(finalized, 2);
  });

  test(
    'room scheduler reruns work enqueued while its run becomes idle',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final idleReached = Completer<void>();
      final releaseIdle = Completer<void>();
      var idleCount = 0;
      var finalized = 0;
      final service = fixture.service(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/folder')) {
            return http.Response.bytes(_probeSuccess(), 200);
          }
          if (request.method == 'PUT') {
            return http.Response('', 201);
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/attachment')) {
            finalized++;
            return http.Response.bytes(_finalizeSuccess(), 200);
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
        identifierFactory: _SequentialIdentifierFactory(),
        beforeRoomIdle: () async {
          idleCount++;
          if (idleCount == 2) {
            idleReached.complete();
            await releaseIdle.future;
          }
        },
      );
      addTearDown(() async {
        if (!releaseIdle.isCompleted) {
          releaseIdle.complete();
        }
        await service.close();
      });

      final first = await service.enqueue(fixture.request(normalMaximum: 32));
      await first.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
      );
      await fixture.cacheConfirmation(messageId: 111);
      await first.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.completed,
      );
      await idleReached.future.timeout(const Duration(seconds: 2));
      await fixture.sourceFile.writeAsBytes(fixture.bytes, flush: true);

      final second = await service.enqueue(fixture.request(normalMaximum: 32));
      releaseIdle.complete();
      await second.events
          .firstWhere(
            (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
          )
          .timeout(const Duration(seconds: 2));

      expect(finalized, 2);
    },
  );

  test('close waits for startup terminal source release', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final jobId = await fixture.seedTerminal(messageId: 108);
    final releaseStarted = Completer<void>();
    final allowRelease = Completer<void>();
    var releaseCalls = 0;
    final service = fixture.service(
      _unexpectedClient(),
      releaseSource: (source) async {
        releaseCalls++;
        if (!releaseStarted.isCompleted) {
          releaseStarted.complete();
        }
        await allowRelease.future;
        final file = File.fromUri(Uri.parse(source.handle.value));
        if (await file.exists()) {
          await file.delete();
        }
      },
    );
    addTearDown(() async {
      if (!allowRelease.isCompleted) {
        allowRelease.complete();
      }
      await service.close();
    });

    await service.ready;
    var closeCompleted = false;
    final close = service.close().whenComplete(() => closeCompleted = true);
    await releaseStarted.future.timeout(const Duration(seconds: 1));
    await pumpEventQueue(times: 10);

    expect(closeCompleted, isFalse);
    allowRelease.complete();
    await close;
    final stored = await fixture.repository.getStoredJob(
      accountId: 'account-a',
      jobId: jobId.value,
    );

    expect(releaseCalls, 1);
    expect(stored?.sourceReleased, isTrue);
  });

  test(
    'multiple cached matches stay ambiguous without an observer loop',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      var requestCount = 0;
      final service = fixture.service(
        MockClient((request) async {
          requestCount++;
          if (request.method == 'POST' &&
              request.url.path.endsWith('/folder')) {
            return http.Response.bytes(_probeSuccess(), 200);
          }
          if (request.method == 'PUT') {
            return http.Response('', 201);
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/attachment')) {
            return http.Response.bytes(_finalizeSuccess(), 200);
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
      );
      addTearDown(service.close);
      final session = await service.enqueue(fixture.request(normalMaximum: 32));
      await session.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
      );

      await fixture.database.transaction(() async {
        await fixture.cacheConfirmation(messageId: 105);
        await fixture.cacheConfirmation(messageId: 106);
      });
      final ambiguous = await session.events.firstWhere(
        (event) => event.errorClass == 'multiple-attachment-matches',
      );
      await pumpEventQueue(times: 10);
      final stable = await fixture.repository.getStoredJob(
        accountId: 'account-a',
        jobId: session.jobId.value,
      );

      expect(ambiguous.phase, AttachmentJobPhase.awaitingConfirmation);
      expect(ambiguous.messageIds, [105, 106]);
      expect(stable?.messageIdsJson, '[105,106]');
      expect(stable?.errorClass, 'multiple-attachment-matches');
      expect(requestCount, 3);
    },
  );

  test(
    'observer errors neither replay transport nor poison later snapshots',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final jobId = await fixture.seedInFlight(AttachmentRequestStep.finalize);
      final cancelled = Completer<void>();
      final controller = StreamController<AttachmentConfirmationSnapshot>(
        onCancel: () {
          if (!cancelled.isCompleted) {
            cancelled.complete();
          }
        },
      );
      addTearDown(controller.close);
      final service = fixture.service(
        _unexpectedClient(),
        watchConfirmationCandidates: () => controller.stream,
      );
      addTearDown(service.close);
      await service.ready;
      await service
          .watchJob(accountId: AccountId.parse('account-a'), jobId: jobId)
          .firstWhere(
            (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
          );

      controller.addError(
        StateError('Synthetic confirmation observation failure'),
        StackTrace.current,
      );
      await pumpEventQueue();
      expect(
        (await fixture.repository.getStoredJob(
          accountId: 'account-a',
          jobId: jobId.value,
        ))?.phase,
        AttachmentJobPhase.awaitingConfirmation.name,
      );
      controller.add(
        AttachmentConfirmationSnapshot(<AttachmentConfirmationBatch>[
          AttachmentConfirmationBatch(
            accountId: AccountId.parse('account-a'),
            jobId: jobId,
            confirmations: <AttachmentMessageConfirmation>[
              fixture.confirmation(jobId, messageId: 107),
            ],
          ),
        ]),
      );
      await service
          .watchJob(accountId: AccountId.parse('account-a'), jobId: jobId)
          .firstWhere((event) => event.phase == AttachmentJobPhase.completed);

      await service.close();
      expect(cancelled.isCompleted, isTrue);
    },
  );

  test(
    'observed confirmation retries locally after one persistence failure',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final jobId = await fixture.seedInFlight(AttachmentRequestStep.finalize);
      final controller = StreamController<AttachmentConfirmationSnapshot>();
      addTearDown(controller.close);
      var completedPersistAttempts = 0;
      final service = fixture.service(
        _unexpectedClient(),
        watchConfirmationCandidates: () => controller.stream,
        persistTransition:
            ({
              required account,
              required job,
              required metadata,
              required updatedAt,
            }) async {
              if (job.phase == AttachmentJobPhase.completed &&
                  !metadata.sourceReleased) {
                completedPersistAttempts++;
                if (completedPersistAttempts == 1) {
                  throw StateError('Synthetic one-shot persistence failure');
                }
              }
              await fixture.repository.persistTransition(
                account: account,
                job: job,
                metadata: metadata,
                updatedAt: updatedAt,
              );
            },
      );
      addTearDown(service.close);
      await service.ready;
      await service
          .watchJob(accountId: AccountId.parse('account-a'), jobId: jobId)
          .firstWhere(
            (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
          );

      controller.add(
        AttachmentConfirmationSnapshot(<AttachmentConfirmationBatch>[
          AttachmentConfirmationBatch(
            accountId: AccountId.parse('account-a'),
            jobId: jobId,
            confirmations: <AttachmentMessageConfirmation>[
              fixture.confirmation(jobId, messageId: 109),
            ],
          ),
        ]),
      );
      final completed = await service
          .watchJob(accountId: AccountId.parse('account-a'), jobId: jobId)
          .firstWhere((event) => event.phase == AttachmentJobPhase.completed)
          .timeout(const Duration(seconds: 2));

      expect(completed.messageIds, [109]);
      expect(completedPersistAttempts, 2);
      await _expectFileRemoved(fixture.sourceFile);
    },
  );

  test(
    'cancel aborts upload, cleans remote draft, and releases source',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final putStarted = Completer<void>();
      var deleteCount = 0;
      final service = fixture.service(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/folder')) {
            return http.Response.bytes(_probeSuccess(), 200);
          }
          if (request.method == 'PUT') {
            putStarted.complete();
            final abort = (request as http.Abortable).abortTrigger;
            await abort;
            throw http.RequestAbortedException(request.url);
          }
          if (request.method == 'DELETE') {
            deleteCount++;
            return http.Response('', 204);
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
      );
      addTearDown(service.close);

      final session = await service.enqueue(fixture.request(normalMaximum: 32));
      await putStarted.future;
      await session.cancel();
      final cancelled = await session.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.cancelled,
      );

      expect(cancelled.phase, AttachmentJobPhase.cancelled);
      expect(deleteCount, 1);
      expect(await fixture.sourceFile.exists(), isFalse);
    },
  );

  test('concurrent cancel releases a terminal source once', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final releaseStarted = Completer<void>();
    final allowRelease = Completer<void>();
    var releaseCalls = 0;
    final service = fixture.service(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
          return http.Response.bytes(_ocsFailure(400), 400);
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
      releaseSource: (source) async {
        final call = ++releaseCalls;
        if (!releaseStarted.isCompleted) {
          releaseStarted.complete();
        }
        await allowRelease.future;
        if (call > 1) {
          throw StateError('Synthetic duplicate release failure');
        }
        final file = File.fromUri(Uri.parse(source.handle.value));
        if (await file.exists()) {
          await file.delete();
        }
      },
    );
    addTearDown(() async {
      if (!allowRelease.isCompleted) {
        allowRelease.complete();
      }
      await service.close();
    });

    final session = await service.enqueue(fixture.request(normalMaximum: 32));
    await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.failed,
    );
    final firstCancel = session.cancel();
    await releaseStarted.future.timeout(const Duration(seconds: 1));
    final secondCancel = session.cancel();
    await pumpEventQueue(times: 20);

    expect(releaseCalls, 1);
    allowRelease.complete();
    await Future.wait<void>([firstCancel, secondCancel]);
    final stored = await fixture.repository.getStoredJob(
      accountId: session.accountId.value,
      jobId: session.jobId.value,
    );

    expect(stored?.sourceReleased, isTrue);
    expect(stored?.localCleanupError, isNull);
  });

  test(
    'bounds automatic retries without deleting the pending source',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      var probeCount = 0;
      final service = fixture.service(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/folder')) {
            probeCount++;
            if (probeCount <= 2) {
              return http.Response.bytes(_ocsFailure(503), 503);
            }
            return http.Response.bytes(_probeSuccess(), 200);
          }
          if (request.method == 'PUT') {
            return http.Response('', 201);
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/attachment')) {
            return http.Response.bytes(_finalizeSuccess(), 200);
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
        retryDelays: const [Duration.zero],
      );
      addTearDown(service.close);

      final session = await service.enqueue(fixture.request(normalMaximum: 32));
      final exhausted = await session.events.firstWhere(
        (event) =>
            event.phase == AttachmentJobPhase.retryable &&
            event.automaticRetryCount == 2,
      );

      expect(exhausted.retryAllowed, isTrue);
      expect(probeCount, 2);
      expect(await fixture.sourceFile.exists(), isTrue);

      await session.retry();
      await session.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
      );
      expect(probeCount, 3);
    },
  );

  test('voice attachment keeps its audio metadata through enqueue', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final service = fixture.service(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
          return http.Response.bytes(_probeSuccess(), 200);
        }
        if (request.method == 'PUT') {
          return http.Response('', 201);
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/attachment')) {
          return http.Response.bytes(
            _finalizeSuccess(fileName: 'recording.mp3'),
            200,
          );
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(service.close);

    final session = await service.enqueue(
      fixture.request(
        normalMaximum: 32,
        kind: AttachmentMessageKind.voice,
        mimeType: 'audio/mpeg',
        displayName: 'recording.mp3',
      ),
    );
    await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
    );
    final persisted = await fixture.repository.getStoredJob(
      accountId: 'account-a',
      jobId: session.jobId.value,
    );

    expect(persisted?.messageKind, AttachmentMessageKind.voice.name);
    expect(persisted?.sourceMimeType, 'audio/mpeg');
  });

  test('401 pauses the account and fresh credentials resume upload', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    var authenticated = false;
    var probeCount = 0;
    final service = fixture.service(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
          probeCount++;
          if (!authenticated) {
            return http.Response.bytes(_ocsFailure(401), 401);
          }
          return http.Response.bytes(_probeSuccess(), 200);
        }
        if (request.method == 'PUT') {
          return http.Response('', 201);
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/attachment')) {
          return http.Response.bytes(_finalizeSuccess(), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(service.close);

    final session = await service.enqueue(fixture.request(normalMaximum: 32));
    final paused = await session.events.firstWhere(
      (event) => event.errorClass == 'reauthentication-required',
    );
    final pausedRuntime = await fixture.repository.loadRuntime();

    expect(paused.phase, AttachmentJobPhase.retryable);
    expect(
      pausedRuntime.snapshot.accounts[AccountId.parse('account-a')]?.lane,
      AttachmentAccountLane.reauthenticationRequired,
    );
    expect(probeCount, 1);

    authenticated = true;
    await fixture.credentials.writeAppPassword(
      'account-a',
      'refreshed-fixture-password',
    );
    await service.completeReauthentication(
      accountId: AccountId.parse('account-a'),
      credentialGeneration: 2,
      capabilityGeneration: 1,
    );
    await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
    );
    final resumedRuntime = await fixture.repository.loadRuntime();

    expect(probeCount, 2);
    expect(
      resumedRuntime.snapshot.accounts[AccountId.parse('account-a')]?.lane,
      AttachmentAccountLane.ready,
    );
    expect(
      resumedRuntime
          .snapshot
          .accounts[AccountId.parse('account-a')]
          ?.credentialGeneration,
      2,
    );
  });

  test('startup recovers an in-flight upload without blind replay', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final jobId = await fixture.seedInFlight(AttachmentRequestStep.normalPut);
    await fixture.credentials.deleteAppPassword('account-a');

    final first = fixture.service(_unexpectedClient());
    await first.ready;
    final recovered = await fixture.repository.getStoredJob(
      accountId: 'account-a',
      jobId: jobId.value,
    );

    expect(recovered?.phase, AttachmentJobPhase.retryable.name);
    expect(recovered?.resumePhase, AttachmentJobPhase.draftResolved.name);
    expect(recovered?.inFlightStep, isNull);
    expect(recovered?.errorClass, 'process-interrupted');
    expect(await fixture.sourceFile.exists(), isTrue);
    await first.close();

    final reopened = fixture.service(_unexpectedClient());
    await reopened.ready;
    final stable = await fixture.repository.getStoredJob(
      accountId: 'account-a',
      jobId: jobId.value,
    );

    expect(stable?.phase, AttachmentJobPhase.retryable.name);
    expect(stable?.inFlightStep, isNull);
    expect(stable?.errorClass, 'process-interrupted');
    await reopened.close();
  });

  test('startup never replays an in-flight finalize request', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final jobId = await fixture.seedInFlight(AttachmentRequestStep.finalize);

    final first = fixture.service(_unexpectedClient());
    await first.ready;
    final recovered = await fixture.repository.getStoredJob(
      accountId: 'account-a',
      jobId: jobId.value,
    );

    expect(recovered?.phase, AttachmentJobPhase.awaitingConfirmation.name);
    expect(recovered?.inFlightStep, isNull);
    expect(recovered?.finalizationDispatched, isTrue);
    expect(recovered?.errorClass, 'restart-during-finalize');
    expect(await fixture.sourceFile.exists(), isTrue);
    await first.close();

    final reopened = fixture.service(_unexpectedClient());
    await reopened.ready;
    final stable = await fixture.repository.getStoredJob(
      accountId: 'account-a',
      jobId: jobId.value,
    );

    expect(stable?.phase, AttachmentJobPhase.awaitingConfirmation.name);
    expect(stable?.inFlightStep, isNull);
    expect(stable?.errorClass, 'restart-during-finalize');
    await reopened.close();
  });

  test('failed attachment is retained until explicit discard', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final service = fixture.service(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
          return http.Response.bytes(_ocsFailure(400), 400);
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(service.close);

    final session = await service.enqueue(fixture.request(normalMaximum: 32));
    final failed = await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.failed,
    );

    expect(failed.errorClass, 'probe-rejected');
    expect(await fixture.sourceFile.exists(), isTrue);

    await service.discardFailed(
      accountId: session.accountId,
      jobId: session.jobId,
    );
    final discarded = await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.cancelled,
    );

    expect(discarded.phase, AttachmentJobPhase.cancelled);
    expect(await fixture.sourceFile.exists(), isFalse);
  });

  test(
    'cancel interrupts source verification before upload dispatch',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final jobId = await fixture.seedInFlight(AttachmentRequestStep.normalPut);
      final sourceProvider = _BlockingSourceProvider(fixture.sourceFile);
      var deleteCount = 0;
      final service = fixture.service(
        MockClient((request) async {
          if (request.method == 'DELETE') {
            deleteCount++;
            return http.Response('', 204);
          }
          fail('Source verification cancellation dispatched: $request');
        }),
        sourceProvider: sourceProvider,
      );
      addTearDown(service.close);

      await service.ready;
      await sourceProvider.opened.future;
      await service.cancel(
        accountId: AccountId.parse('account-a'),
        jobId: jobId,
      );
      final cancelled = await service
          .watchJob(accountId: AccountId.parse('account-a'), jobId: jobId)
          .firstWhere((event) => event.phase == AttachmentJobPhase.cancelled);

      expect(cancelled.phase, AttachmentJobPhase.cancelled);
      expect(deleteCount, 1);
      expect(sourceProvider.leaseClosed.isCompleted, isTrue);
      expect(await fixture.sourceFile.exists(), isFalse);
    },
  );
}

Future<void> _expectFileRemoved(File file) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (await file.exists()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for ${file.path} to be removed');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _Fixture {
  _Fixture._({
    required this.directory,
    required this.sourceFile,
    required this.bytes,
    required this.database,
    required this.credentials,
    required this.repository,
  });

  static Future<_Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'nctalk-attachment-service-',
    );
    final bytes = utf8.encode('12345678');
    final sourceFile = File(
      '${directory.path}${Platform.pathSeparator}source.bin',
    );
    await sourceFile.writeAsBytes(bytes, flush: true);
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    await database
        .into(database.accounts)
        .insert(
          AccountsCompanion.insert(
            id: 'account-a',
            serverUrl: 'https://cloud.example.invalid',
            loginName: 'fixture-user',
            serverProductName: 'Nextcloud',
            createdAtMillis: 1,
          ),
        );
    final credentials = MemoryCredentialVault();
    await credentials.writeAppPassword('account-a', 'fixture-password');
    return _Fixture._(
      directory: directory,
      sourceFile: sourceFile,
      bytes: bytes,
      database: database,
      credentials: credentials,
      repository: AttachmentRepository(database),
    );
  }

  final Directory directory;
  final File sourceFile;
  final List<int> bytes;
  final AppDatabase database;
  final MemoryCredentialVault credentials;
  final AttachmentRepository repository;

  AttachmentService service(
    http.Client client, {
    List<Duration> retryDelays = const [Duration(milliseconds: 1)],
    AttachmentSourceProvider? sourceProvider,
    WatchAttachmentConfirmationCandidates? watchConfirmationCandidates,
    PersistAttachmentTransition? persistTransition,
    ReleaseDurableAttachmentSource? releaseSource,
    CatchUpAttachmentConfirmation? catchUpConfirmation,
    BeforeAttachmentRoomIdle? beforeRoomIdle,
    List<Duration> confirmationRetryDelays = const <Duration>[],
    AttachmentIdentifierFactory? identifierFactory,
  }) {
    final sources = sourceProvider ?? _FileSourceProvider();
    return AttachmentService(
      repository: repository,
      credentials: credentials,
      releaseSource:
          releaseSource ??
          (source) async {
            if (source.ownership != AttachmentSourceOwnership.appOwnedCopy) {
              return;
            }
            final file = File.fromUri(Uri.parse(source.handle.value));
            if (await file.exists()) {
              await file.delete();
            }
          },
      transport: HttpAttachmentTransport(
        client: client,
        sourceProvider: sources,
      ),
      identifierFactory: identifierFactory ?? _IdentifierFactory(),
      retryDelays: retryDelays,
      watchConfirmationCandidates: watchConfirmationCandidates,
      persistTransition: persistTransition,
      catchUpConfirmation: catchUpConfirmation,
      beforeRoomIdle: beforeRoomIdle,
      confirmationRetryDelays: confirmationRetryDelays,
    );
  }

  AttachmentEnqueueRequest request({
    required int normalMaximum,
    AttachmentMessageKind kind = AttachmentMessageKind.file,
    String mimeType = 'image/png',
    String displayName = 'source.png',
  }) => AttachmentEnqueueRequest(
    accountId: AccountId.parse('account-a'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    roomToken: ConversationToken.parse(
      'rooma123',
      path: r'$.roomToken',
      code: TalkProtocolErrorCode.invalidAttachmentModel,
    ),
    source: PreparedAttachmentSource(
      handle: AttachmentSourceHandle.parse(sourceFile.uri.toString()),
      ownership: AttachmentSourceOwnership.appOwnedCopy,
      byteLength: bytes.length,
      sha256: AttachmentSha256.parse(
        'ef797c8118f02dfb649607dd5d3f8c7623048c9c063d532cc95c5ed7a898a64f',
      ),
      mimeType: mimeType,
      displayName: displayName,
    ),
    metadata: AttachmentMetadata(
      kind: kind,
      caption: null,
      replyTo: null,
      threadId: null,
      threadTitle: null,
      silent: false,
    ),
    davUserId: DavUserId.parse('fixture-user'),
    profile: _profile(),
    credentialGeneration: 1,
    capabilityGeneration: 1,
    roomCanWrite: true,
    policy: AttachmentUploadPolicy(
      normalUploadMaximumBytes: normalMaximum,
      chunkSizeBytes: 4,
    ),
  );

  Future<AttachmentJobId> seedInFlight(AttachmentRequestStep step) async {
    if (step != AttachmentRequestStep.normalPut &&
        step != AttachmentRequestStep.finalize) {
      throw ArgumentError.value(step, 'step');
    }
    final enqueue = request(normalMaximum: 32);
    final jobId = AttachmentJobId.parse('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    final referenceId = ChatReferenceId.parse(
      '11111111-1111-4111-8111-111111111111',
    );
    final authority = AttachmentAuthority(
      accountId: enqueue.accountId,
      server: enqueue.server,
      capabilityGeneration: enqueue.capabilityGeneration,
      profile: enqueue.profile,
      replayContractRevision: attachmentReplayContractRevision,
      roomCanWrite: enqueue.roomCanWrite,
      roomToken: enqueue.roomToken,
    );
    final account = AttachmentAccountState(
      accountId: enqueue.accountId,
      server: enqueue.server,
      lane: AttachmentAccountLane.ready,
      credentialGeneration: enqueue.credentialGeneration,
      capabilityGeneration: enqueue.capabilityGeneration,
      jobs: const {},
    );
    var snapshot = AttachmentRuntimeSnapshot(
      accounts: <AccountId, AttachmentAccountState>{enqueue.accountId: account},
    );
    final admission = admitAttachmentJob(
      snapshot,
      accountId: enqueue.accountId,
      authority: authority,
      davUserId: enqueue.davUserId,
      draft: AttachmentJobDraft(
        jobId: jobId,
        roomToken: enqueue.roomToken,
        referenceId: referenceId,
        source: enqueue.source,
        metadata: enqueue.metadata,
        enqueueSequence: 1,
        policy: enqueue.policy,
        uploadSessionId: null,
      ),
    );
    snapshot = admission.plan!.commit(snapshot);
    if (step == AttachmentRequestStep.normalPut ||
        step == AttachmentRequestStep.finalize) {
      final admitted = snapshot.accounts[enqueue.accountId]!.jobs[jobId]!;
      final folder = DavRelativePath.parse('Talk/Synthetic/Draft');
      final prepared = admitted.copyWith(
        phase: step == AttachmentRequestStep.normalPut
            ? AttachmentJobPhase.draftResolved
            : AttachmentJobPhase.uploaded,
        remoteDraftFolder: folder,
        remoteTemporaryPath: folder.append(admitted.draft.stableTemporaryName),
      );
      snapshot = snapshot.replaceAccount(
        snapshot.accounts[enqueue.accountId]!.copyWith(
          jobs: <AttachmentJobId, AttachmentJob>{jobId: prepared},
        ),
      );
    }
    final planned = planNextAttachmentStep(
      snapshot,
      accountId: enqueue.accountId,
      jobId: jobId,
      authority: authority,
      requestId: AttachmentRequestId.parse('persisted-request-1'),
      sourceObservation: step == AttachmentRequestStep.normalPut
          ? AttachmentSourceObservation(
              handle: enqueue.source.handle,
              byteLength: enqueue.source.byteLength,
              sha256: enqueue.source.sha256,
            )
          : null,
    );
    if (planned.request?.step != step) {
      throw StateError('Unexpected seeded attachment request');
    }
    snapshot = planned.plan!.commit(snapshot);
    final persistedAccount = snapshot.accounts[enqueue.accountId]!;
    final job = persistedAccount.jobs[jobId]!;
    await repository.persistAdmission(
      account: persistedAccount,
      job: job,
      metadata: AttachmentExecutionMetadata(
        profile: enqueue.profile,
        roomCanWrite: enqueue.roomCanWrite,
        automaticRetryCount: 0,
        nextAttemptAt: null,
        sourceReleased: false,
        localCleanupError: null,
        createdAt: DateTime.utc(2026, 8, 24),
      ),
      updatedAt: DateTime.utc(2026, 8, 24),
    );
    return jobId;
  }

  Future<AttachmentJobId> seedTerminal({required int messageId}) async {
    final jobId = await seedInFlight(AttachmentRequestStep.finalize);
    final accountId = AccountId.parse('account-a');
    final key = (accountId: accountId.value, jobId: jobId.value);
    final loaded = await repository.loadRuntime();
    var snapshot = loaded.snapshot;
    final metadata = loaded.metadata[key]!;
    final recovered = recoverAttachmentAfterRestart(
      snapshot,
      accountId: accountId,
      jobId: jobId,
    );
    if (!recovered.canCommit) {
      throw StateError('Synthetic terminal job recovery failed');
    }
    snapshot = recovered.plan!.commit(snapshot);
    var account = snapshot.accounts[accountId]!;
    await repository.persistTransition(
      account: account,
      job: account.jobs[jobId]!,
      metadata: metadata,
      updatedAt: DateTime.utc(2026, 8, 24),
    );
    final completed = reconcileAttachmentConfirmation(
      snapshot,
      accountId: accountId,
      jobId: jobId,
      confirmations: <AttachmentMessageConfirmation>[
        confirmation(jobId, messageId: messageId),
      ],
    );
    if (!completed.canCommit) {
      throw StateError('Synthetic terminal job confirmation failed');
    }
    snapshot = completed.plan!.commit(snapshot);
    account = snapshot.accounts[accountId]!;
    await repository.persistTransition(
      account: account,
      job: account.jobs[jobId]!,
      metadata: metadata,
      updatedAt: DateTime.utc(2026, 8, 24),
    );
    return jobId;
  }

  AttachmentMessageConfirmation confirmation(
    AttachmentJobId _, {
    required int messageId,
  }) => AttachmentMessageConfirmation(
    accountId: AccountId.parse('account-a'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    messageId: messageId,
    roomToken: ConversationToken.parse(
      'rooma123',
      path: r'$.roomToken',
      code: TalkProtocolErrorCode.invalidAttachmentModel,
    ),
    referenceId: '11111111-1111-4111-8111-111111111111',
    systemMessage: '',
    messageType: 'comment',
    hasFileRichObject: true,
  );

  Future<void> cacheConfirmation({required int messageId}) {
    final wire = <String, Object?>{
      'id': messageId,
      'token': 'rooma123',
      'actorType': 'users',
      'actorId': 'fixture-user',
      'actorDisplayName': 'Fixture User',
      'timestamp': 1770000000 + messageId,
      'systemMessage': '',
      'messageType': 'comment',
      'isReplyable': true,
      'referenceId': '11111111-1111-4111-8111-111111111111',
      'message': '{file}',
      'messageParameters': <String, Object?>{
        'file': <String, Object?>{
          'type': 'file',
          'id': 'fixture-file',
          'name': 'source.png',
          'link': '/remote.php/dav/files/fixture/source.png',
        },
      },
      'markdown': false,
      'reactions': <String, Object?>{},
      'reactionsSelf': <Object?>[],
      'deleted': null,
      'threadId': null,
      'isThread': false,
      'threadTitle': null,
      'threadReplies': 0,
    };
    return database
        .into(database.cachedChatMessages)
        .insert(
          CachedChatMessagesCompanion.insert(
            accountId: 'account-a',
            roomToken: 'rooma123',
            messageId: messageId,
            actorType: 'users',
            actorId: 'fixture-user',
            actorDisplayName: 'Fixture User',
            timestamp: 1770000000 + messageId,
            systemMessage: '',
            messageType: 'comment',
            referenceId: '11111111-1111-4111-8111-111111111111',
            displayText: 'Synthetic attachment',
            deleted: false,
            rawJson: jsonEncode(wire),
          ),
        );
  }

  Future<void> close() async {
    await database.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

final class _FileSourceProvider implements AttachmentSourceProvider {
  @override
  Future<AttachmentSourceLease> open(
    AttachmentSourceHandle handle, {
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    if (cancellationSignal?.isCancelled ?? false) {
      throw StateError('Synthetic source open cancelled');
    }
    return _FileSourceLease(File.fromUri(Uri.parse(handle.value)));
  }
}

final class _FileSourceLease implements AttachmentSourceLease {
  const _FileSourceLease(this.file);

  final File file;

  @override
  Stream<List<int>> openRead({int offset = 0, int? length}) =>
      file.openRead(offset, length == null ? null : offset + length);

  @override
  Future<void> close() async {}
}

final class _BlockingSourceProvider implements AttachmentSourceProvider {
  _BlockingSourceProvider(this.file);

  final File file;
  final Completer<void> opened = Completer<void>();
  final Completer<void> leaseClosed = Completer<void>();

  @override
  Future<AttachmentSourceLease> open(
    AttachmentSourceHandle handle, {
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    if (!opened.isCompleted) {
      opened.complete();
    }
    final signal = cancellationSignal;
    if (signal == null) {
      throw StateError('Cancellation signal is required');
    }
    final cancelled = Completer<void>();
    final registration = signal.register(() {
      if (!cancelled.isCompleted) {
        cancelled.complete();
      }
    });
    try {
      await cancelled.future;
    } finally {
      registration.detach();
    }
    return _TrackedFileSourceLease(file, leaseClosed);
  }
}

final class _TrackedFileSourceLease implements AttachmentSourceLease {
  const _TrackedFileSourceLease(this.file, this.closed);

  final File file;
  final Completer<void> closed;

  @override
  Stream<List<int>> openRead({int offset = 0, int? length}) =>
      file.openRead(offset, length == null ? null : offset + length);

  @override
  Future<void> close() async {
    if (!closed.isCompleted) {
      closed.complete();
    }
  }
}

final class _IdentifierFactory implements AttachmentIdentifierFactory {
  int _request = 0;

  @override
  AttachmentJobId newJobId() =>
      AttachmentJobId.parse('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');

  @override
  AttachmentRequestId newRequestId() =>
      AttachmentRequestId.parse('attachment-request-${++_request}');

  @override
  ChatReferenceId newReferenceId() =>
      ChatReferenceId.parse('11111111-1111-4111-8111-111111111111');

  @override
  DavUploadSessionId newUploadSessionId() =>
      DavUploadSessionId.parse('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
}

final class _SequentialIdentifierFactory
    implements AttachmentIdentifierFactory {
  int _job = 0;
  int _reference = 0;
  int _request = 0;
  int _upload = 0;

  @override
  AttachmentJobId newJobId() =>
      AttachmentJobId.parse('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa${++_job}');

  @override
  AttachmentRequestId newRequestId() =>
      AttachmentRequestId.parse('attachment-request-${++_request}');

  @override
  ChatReferenceId newReferenceId() => ChatReferenceId.parse(
    '11111111-1111-4111-8111-11111111111${++_reference}',
  );

  @override
  DavUploadSessionId newUploadSessionId() => DavUploadSessionId.parse(
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb${++_upload}',
  );
}

http.Client _unexpectedClient() => MockClient((request) async {
  fail('Restart recovery dispatched an unexpected request: $request');
});

AttachmentCapabilityProfile _profile() =>
    AttachmentCapabilityProfile.fromSnapshot(
      CapabilitySnapshot.fromJson(<String, Object?>{
        'ocs': <String, Object?>{
          'meta': <String, Object?>{
            'status': 'ok',
            'statuscode': 200,
            'message': 'OK',
          },
          'data': <String, Object?>{
            'version': <String, Object?>{
              'major': 34,
              'minor': 0,
              'micro': 0,
              'string': '34.0.0',
              'edition': '',
            },
            'capabilities': <String, Object?>{
              'spreed': <String, Object?>{
                'features': <String>[
                  'chat-reference-id',
                  'voice-message-sharing',
                ],
                'config': <String, Object?>{
                  'attachments': <String, Object?>{
                    'allowed': true,
                    'conversation-subfolders': true,
                  },
                },
              },
            },
          },
        },
      }, context: CapabilityContext.authenticated),
      federated: false,
    );

List<int> _probeSuccess() => utf8.encode(
  jsonEncode(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{
        'folder': 'Talk/Synthetic/Draft',
        'renames': <Object?>[],
      },
    },
  }),
);

List<int> _finalizeSuccess({String fileName = 'source.png'}) => utf8.encode(
  jsonEncode(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{
        'renames': <Object?>[
          <String, Object?>{fileName: fileName},
        ],
      },
    },
  }),
);

List<int> _ocsFailure(int statusCode) => utf8.encode(
  jsonEncode(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'failure',
        'statuscode': statusCode,
        'message': 'Synthetic transient failure',
      },
      'data': <String, Object?>{},
    },
  }),
);

String _emptyManifest(Uri sessionUri) =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:multistatus xmlns:d="DAV:">'
    '<d:response><d:href>${sessionUri.path}/</d:href>'
    '<d:propstat><d:prop><d:resourcetype><d:collection/>'
    '</d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status>'
    '</d:propstat></d:response></d:multistatus>';
