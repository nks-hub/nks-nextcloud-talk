import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/attachment_service.dart';
import 'package:nextcloudtalk/features/chat/composer/attachment_submission.dart';
import 'package:nextcloudtalk/features/chat/composer/voice_message.dart';
import 'package:nextcloudtalk/features/chat/media/image_attachment_upload_controller.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  group('AttachmentSubmissionBridge image transport', () {
    test(
      'maps durable progress without completing before confirmation',
      () async {
        final durable = _FakeDurableSession();
        addTearDown(durable.close);
        var prepareCount = 0;
        var enqueueCount = 0;
        final bridge = AttachmentSubmissionBridge(
          accountId: _account,
          server: _server,
          roomToken: _room,
          prepare:
              ({
                required accountId,
                required roomToken,
                required source,
                required metadata,
              }) async {
                prepareCount++;
                return _enqueueRequest(source: source, metadata: metadata);
              },
          enqueue: (request) async {
            enqueueCount++;
            return durable;
          },
        );

        final session = await bridge.startImageUpload(_imageRequest);
        final result = session.events.toList();
        durable
          ..add(_progress(AttachmentJobPhase.localPrepared))
          ..add(_progress(AttachmentJobPhase.uploading, progress: 0.4))
          ..add(_progress(AttachmentJobPhase.awaitingConfirmation, progress: 1))
          ..add(_progress(AttachmentJobPhase.completed, progress: 1));

        final events = await result;
        expect(prepareCount, 1);
        expect(enqueueCount, 1);
        expect(events.map((event) => event.phase), <ImageAttachmentUploadPhase>[
          ImageAttachmentUploadPhase.queued,
          ImageAttachmentUploadPhase.uploading,
          ImageAttachmentUploadPhase.awaitingConfirmation,
          ImageAttachmentUploadPhase.completed,
        ]);
        expect(events[1].progress, 0.4);
        expect(durable.eventCancellationCount, 1);
      },
    );

    test(
      'retries the admitted durable job instead of enqueueing a copy',
      () async {
        final durable = _FakeDurableSession();
        addTearDown(durable.close);
        var prepareCount = 0;
        var enqueueCount = 0;
        final bridge = AttachmentSubmissionBridge(
          accountId: _account,
          server: _server,
          roomToken: _room,
          prepare:
              ({
                required accountId,
                required roomToken,
                required source,
                required metadata,
              }) async {
                prepareCount++;
                return _enqueueRequest(source: source, metadata: metadata);
              },
          enqueue: (request) async {
            enqueueCount++;
            return durable;
          },
        );

        final first = await bridge.startImageUpload(_imageRequest);
        final firstEvents = first.events.toList();
        durable.add(
          _progress(
            AttachmentJobPhase.retryable,
            errorClass: 'dav-transient',
            retryAllowed: true,
          ),
        );
        final failure = (await firstEvents).single;
        expect(failure.phase, ImageAttachmentUploadPhase.failed);
        expect(failure.failureCode, 'dav-transient');
        expect(failure.retryAllowed, isTrue);

        final retried = await bridge.startImageUpload(_imageRequest);
        expect(durable.retryCount, 1);
        expect(prepareCount, 1);
        expect(enqueueCount, 1);
        final retriedEvents = retried.events.toList();
        durable
          ..add(_progress(AttachmentJobPhase.uploading, progress: 0.75))
          ..add(_progress(AttachmentJobPhase.completed, progress: 1));
        expect(
          (await retriedEvents).map((event) => event.phase),
          <ImageAttachmentUploadPhase>[
            ImageAttachmentUploadPhase.uploading,
            ImageAttachmentUploadPhase.completed,
          ],
        );
      },
    );

    test(
      'cancels the durable job and releases its event subscription',
      () async {
        final durable = _FakeDurableSession();
        addTearDown(durable.close);
        final bridge = _bridgeFor(durable);
        final session = await bridge.startImageUpload(_imageRequest);
        final subscription = session.events.listen((_) {});

        await subscription.cancel();
        await session.cancel();

        expect(durable.cancelCount, 1);
        expect(durable.eventCancellationCount, 1);
      },
    );

    test('rejects unsupported capabilities before durable enqueue', () async {
      var enqueueCount = 0;
      final bridge = AttachmentSubmissionBridge(
        accountId: _account,
        server: _server,
        roomToken: _room,
        prepare:
            ({
              required accountId,
              required roomToken,
              required source,
              required metadata,
            }) async => _enqueueRequest(
              source: source,
              metadata: metadata,
              profile: _profile(attachmentsAllowed: false),
            ),
        enqueue: (request) async {
          enqueueCount++;
          return _FakeDurableSession();
        },
      );

      await expectLater(
        bridge.startImageUpload(_imageRequest),
        throwsA(
          isA<AttachmentSubmissionException>().having(
            (error) => error.failure,
            'failure',
            AttachmentSubmissionFailure.unsupported,
          ),
        ),
      );
      expect(enqueueCount, 0);
    });

    test('rejects a prepared server mismatch before durable enqueue', () async {
      var enqueueCount = 0;
      final bridge = AttachmentSubmissionBridge(
        accountId: _account,
        server: _server,
        roomToken: _room,
        prepare:
            ({
              required accountId,
              required roomToken,
              required source,
              required metadata,
            }) async => _enqueueRequest(
              source: source,
              metadata: metadata,
              server: _otherServer,
            ),
        enqueue: (request) async {
          enqueueCount++;
          return _FakeDurableSession();
        },
      );

      await expectLater(
        bridge.startImageUpload(_imageRequest),
        throwsA(
          isA<AttachmentSubmissionException>().having(
            (error) => error.failure,
            'failure',
            AttachmentSubmissionFailure.invalidBinding,
          ),
        ),
      );
      expect(enqueueCount, 0);
    });

    test('fails a mismatched durable progress scope without retry', () async {
      final durable = _FakeDurableSession();
      addTearDown(durable.close);
      final bridge = _bridgeFor(durable);
      final session = await bridge.startImageUpload(_imageRequest);
      final result = session.events.toList();

      durable.add(
        _progress(AttachmentJobPhase.uploading, accountId: _otherAccount),
      );

      final failure = (await result).single;
      expect(failure.phase, ImageAttachmentUploadPhase.failed);
      expect(failure.failureCode, 'durable-scope-mismatch');
      expect(failure.retryAllowed, isFalse);
      expect(durable.eventCancellationCount, 1);
    });
  });

  group('AttachmentSubmissionBridge voice transport', () {
    test('accepts ownership only after the durable enqueue succeeds', () async {
      final durable = _FakeDurableSession();
      addTearDown(durable.close);
      final enqueueResult = Completer<AttachmentSubmissionDurableSession>();
      var completed = false;
      final bridge = AttachmentSubmissionBridge(
        accountId: _account,
        server: _server,
        roomToken: _room,
        prepare:
            ({
              required accountId,
              required roomToken,
              required source,
              required metadata,
            }) async => _enqueueRequest(source: source, metadata: metadata),
        enqueue: (_) => enqueueResult.future,
      );
      final submission = bridge
          .submit(
            VoiceAttachmentSubmission(
              source: _voiceSource,
              duration: const Duration(seconds: 4),
              metadata: _voiceMetadata,
            ),
          )
          .whenComplete(() => completed = true);
      await pumpEventQueue();
      expect(completed, isFalse);

      enqueueResult.complete(durable);
      final acceptance = await submission;
      expect(acceptance.durablyAccepted, isTrue);
      expect(completed, isTrue);
    });

    test('does not report acceptance when durable enqueue fails', () async {
      final bridge = AttachmentSubmissionBridge(
        accountId: _account,
        server: _server,
        roomToken: _room,
        prepare:
            ({
              required accountId,
              required roomToken,
              required source,
              required metadata,
            }) async => _enqueueRequest(source: source, metadata: metadata),
        enqueue: (_) async => throw StateError('durable admission failed'),
      );

      await expectLater(
        bridge.submit(
          VoiceAttachmentSubmission(
            source: _voiceSource,
            duration: const Duration(seconds: 4),
            metadata: _voiceMetadata,
          ),
        ),
        throwsStateError,
      );
    });

    test('rejects a voice request resolved to another server', () async {
      var enqueueCount = 0;
      final bridge = AttachmentSubmissionBridge(
        accountId: _account,
        server: _server,
        roomToken: _room,
        prepare:
            ({
              required accountId,
              required roomToken,
              required source,
              required metadata,
            }) async => _enqueueRequest(
              source: source,
              metadata: metadata,
              server: _otherServer,
            ),
        enqueue: (_) async {
          enqueueCount++;
          return _FakeDurableSession();
        },
      );

      await expectLater(
        bridge.submit(
          VoiceAttachmentSubmission(
            source: _voiceSource,
            duration: const Duration(seconds: 4),
            metadata: _voiceMetadata,
          ),
        ),
        throwsA(
          isA<AttachmentSubmissionException>().having(
            (error) => error.failure,
            'failure',
            AttachmentSubmissionFailure.invalidBinding,
          ),
        ),
      );
      expect(enqueueCount, 0);
    });
  });
}

AttachmentSubmissionBridge _bridgeFor(_FakeDurableSession durable) =>
    AttachmentSubmissionBridge(
      accountId: _account,
      server: _server,
      roomToken: _room,
      prepare:
          ({
            required accountId,
            required roomToken,
            required source,
            required metadata,
          }) async => _enqueueRequest(source: source, metadata: metadata),
      enqueue: (_) async => durable,
    );

final class _FakeDurableSession implements AttachmentSubmissionDurableSession {
  _FakeDurableSession({AccountId? accountId, AttachmentJobId? jobId})
    : accountId = accountId ?? _account,
      jobId = jobId ?? _jobId {
    _events = StreamController<AttachmentJobProgress>.broadcast(
      sync: true,
      onCancel: () => eventCancellationCount++,
    );
  }

  late final StreamController<AttachmentJobProgress> _events;

  @override
  final AccountId accountId;

  @override
  final AttachmentJobId jobId;

  int cancelCount = 0;
  int retryCount = 0;
  int eventCancellationCount = 0;

  @override
  Stream<AttachmentJobProgress> get events => _events.stream;

  void add(AttachmentJobProgress progress) => _events.add(progress);

  @override
  Future<void> cancel() async {
    cancelCount++;
  }

  @override
  Future<void> retry() async {
    retryCount++;
  }

  Future<void> close() => _events.close();
}

AttachmentJobProgress _progress(
  AttachmentJobPhase phase, {
  AccountId? accountId,
  double progress = 0,
  bool retryAllowed = false,
  String? errorClass,
}) => AttachmentJobProgress(
  accountId: accountId ?? _account,
  jobId: _jobId,
  phase: phase,
  progress: progress,
  attemptCount: 1,
  automaticRetryCount: 0,
  retryAllowed: retryAllowed,
  errorClass: errorClass,
  messageIds: phase == AttachmentJobPhase.completed
      ? const <int>[42]
      : const [],
);

AttachmentEnqueueRequest _enqueueRequest({
  required PreparedAttachmentSource source,
  required AttachmentMetadata metadata,
  ServerBase? server,
  AttachmentCapabilityProfile? profile,
}) => AttachmentEnqueueRequest(
  accountId: _account,
  server: server ?? _server,
  roomToken: _room,
  source: source,
  metadata: metadata,
  davUserId: DavUserId.parse('user-a'),
  profile: profile ?? _profile(),
  credentialGeneration: 3,
  capabilityGeneration: 7,
  roomCanWrite: true,
  policy: AttachmentUploadPolicy(
    normalUploadMaximumBytes: 1024 * 1024,
    chunkSizeBytes: 1024000,
  ),
);

AttachmentCapabilityProfile _profile({bool attachmentsAllowed = true}) =>
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
                  'media-caption',
                  'voice-message-sharing',
                  'chat-replies',
                  'threads',
                  'silent-send',
                ],
                'config': <String, Object?>{
                  'attachments': <String, Object?>{
                    'allowed': attachmentsAllowed,
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

final _account = AccountId.parse('account-a');
final _otherAccount = AccountId.parse('account-b');
final _server = ServerBase.parse('https://cloud.example.invalid/nextcloud');
final _otherServer = ServerBase.parse(
  'https://other.example.invalid/nextcloud',
);
final _room = ConversationToken.parse(
  'rooma123',
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidAttachmentModel,
);
final _jobId = AttachmentJobId.parse('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
final _imageSource = PreparedAttachmentSource(
  handle: AttachmentSourceHandle.parse('image-source-a'),
  ownership: AttachmentSourceOwnership.appOwnedCopy,
  byteLength: 4096,
  sha256: AttachmentSha256.parse(
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  ),
  mimeType: 'image/jpeg',
  displayName: 'photo.jpg',
);
final _imageMetadata = AttachmentMetadata(
  kind: AttachmentMessageKind.file,
  caption: 'Caption',
  replyTo: null,
  threadId: null,
  threadTitle: null,
  silent: false,
);
final _imageRequest = ImageAttachmentUploadRequest(
  accountId: _account,
  server: _server,
  roomToken: _room,
  source: _imageSource,
  metadata: _imageMetadata,
);
final _voiceSource = PreparedAttachmentSource(
  handle: AttachmentSourceHandle.parse('voice-source-a'),
  ownership: AttachmentSourceOwnership.appOwnedCopy,
  byteLength: 8192,
  sha256: AttachmentSha256.parse(
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  ),
  mimeType: 'audio/wav',
  displayName: 'voice.wav',
);
final _voiceMetadata = AttachmentMetadata(
  kind: AttachmentMessageKind.voice,
  caption: null,
  replyTo: null,
  threadId: null,
  threadTitle: null,
  silent: false,
);
