import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/voice_message.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  group('VoiceMessageController', () {
    test('fails closed when voice attachments are not supported', () async {
      final fixture = _VoiceFixture(profile: _attachmentProfile(voice: false));
      addTearDown(fixture.close);

      expect(await fixture.controller.start(), isFalse);
      expect((fixture.permission as _FakePermission).requests, 0);
      expect(fixture.controller.state.error, VoiceMessageError.unsupported);
    });

    test('distinguishes denied and permanently denied permission', () async {
      for (final permission in <MicrophonePermissionStatus>[
        MicrophonePermissionStatus.denied,
        MicrophonePermissionStatus.permanentlyDenied,
      ]) {
        final fixture = _VoiceFixture(permissionStatus: permission);
        expect(await fixture.controller.start(), isFalse);
        expect(fixture.recorder.starts, 0);
        expect(
          fixture.controller.state.error,
          permission == MicrophonePermissionStatus.denied
              ? VoiceMessageError.permissionDenied
              : VoiceMessageError.permissionPermanentlyDenied,
        );
        await fixture.close();
      }
    });

    test(
      'records and prepares a durable preview with voice metadata',
      () async {
        final fixture = _VoiceFixture();
        addTearDown(fixture.close);

        expect(await fixture.controller.start(), isTrue);
        expect(fixture.controller.state.phase, VoiceMessagePhase.recording);
        expect(await fixture.controller.stop(), isTrue);

        expect(fixture.controller.state.phase, VoiceMessagePhase.ready);
        expect(
          fixture.controller.state.draft?.duration,
          const Duration(seconds: 3),
        );
        expect(fixture.controller.state.draft?.source.mimeType, 'audio/wav');
        expect(fixture.recorder.discarded, isEmpty);
      },
    );

    test(
      'rejects an unsupported recorded MIME and deletes the prepared copy',
      () async {
        final fixture = _VoiceFixture(
          recording: _recording(mimeType: 'audio/ogg'),
        );
        addTearDown(fixture.close);

        await fixture.controller.start();
        expect(await fixture.controller.stop(), isFalse);

        expect(fixture.controller.state.phase, VoiceMessagePhase.error);
        expect(
          fixture.controller.state.error,
          VoiceMessageError.invalidRecording,
        );
        expect(fixture.recorder.discarded, hasLength(1));
      },
    );

    test('pause and resume move between recording states', () async {
      final fixture = _VoiceFixture();
      addTearDown(fixture.close);
      await fixture.controller.start();

      expect(await fixture.controller.pauseRecording(), isTrue);
      expect(fixture.controller.state.phase, VoiceMessagePhase.paused);
      expect(fixture.recorder.pauses, 1);
      expect(await fixture.controller.pauseRecording(), isFalse);

      expect(await fixture.controller.resumeRecording(), isTrue);
      expect(fixture.controller.state.phase, VoiceMessagePhase.recording);
      expect(fixture.recorder.resumes, 1);
      expect(await fixture.controller.resumeRecording(), isFalse);
    });

    test('a paused recording can still be stopped and cancelled', () async {
      final fixture = _VoiceFixture();
      addTearDown(fixture.close);
      await fixture.controller.start();
      await fixture.controller.pauseRecording();

      expect(await fixture.controller.stop(), isTrue);
      expect(fixture.controller.state.phase, VoiceMessagePhase.ready);

      final cancelled = _VoiceFixture();
      addTearDown(cancelled.close);
      await cancelled.controller.start();
      await cancelled.controller.pauseRecording();

      expect(await cancelled.controller.cancel(), isTrue);
      expect(cancelled.recorder.cancels, 1);
      expect(cancelled.controller.state.phase, VoiceMessagePhase.idle);
    });

    test('cancel while recording invokes recorder cleanup', () async {
      final fixture = _VoiceFixture();
      addTearDown(fixture.close);
      await fixture.controller.start();

      expect(await fixture.controller.cancel(), isTrue);

      expect(fixture.recorder.cancels, 1);
      expect(fixture.controller.state.phase, VoiceMessagePhase.idle);
    });

    test('cancel preview stops playback and deletes the local draft', () async {
      final fixture = _VoiceFixture(controlledPlayback: true);
      addTearDown(fixture.close);
      await fixture.preparePreview();
      final play = fixture.controller.play();
      await Future<void>.delayed(Duration.zero);
      expect(fixture.controller.state.phase, VoiceMessagePhase.playing);

      expect(await fixture.controller.cancel(), isTrue);
      fixture.player.completePlayback();
      expect(await play, isFalse);

      expect(fixture.player.stops, 1);
      expect(fixture.recorder.discarded, hasLength(1));
      expect(fixture.controller.state.phase, VoiceMessagePhase.idle);
    });

    test('play returns to preview after natural completion', () async {
      final fixture = _VoiceFixture();
      addTearDown(fixture.close);
      await fixture.preparePreview();

      expect(await fixture.controller.play(), isTrue);
      expect(fixture.player.plays, 1);
      expect(fixture.controller.state.phase, VoiceMessagePhase.ready);
    });

    test(
      'successful submit transfers ownership without deleting the source',
      () async {
        final fixture = _VoiceFixture();
        addTearDown(fixture.close);
        await fixture.preparePreview();

        expect(await fixture.controller.submit(), isTrue);

        expect(fixture.controller.state.phase, VoiceMessagePhase.submitted);
        expect(fixture.submitter.submissions, hasLength(1));
        final submission = fixture.submitter.submissions.single;
        expect(submission.metadata.kind, AttachmentMessageKind.voice);
        expect(submission.metadata.expectedMessageType, 'voice-message');
        expect(submission.duration, const Duration(seconds: 3));
        expect(fixture.recorder.discarded, isEmpty);
      },
    );

    test('submit failure keeps a retryable preview', () async {
      final fixture = _VoiceFixture(submitError: StateError('offline'));
      addTearDown(fixture.close);
      await fixture.preparePreview();

      expect(await fixture.controller.submit(), isFalse);

      expect(fixture.controller.state.phase, VoiceMessagePhase.error);
      expect(fixture.controller.state.error, VoiceMessageError.submitFailed);
      expect(fixture.controller.state.draft, isNotNull);
      expect(fixture.recorder.discarded, isEmpty);
    });

    test(
      'refuses reentrant start and local cancellation during submit',
      () async {
        final permission = _ControlledPermission();
        final fixture = _VoiceFixture(
          permission: permission,
          controlledSubmit: true,
        );
        addTearDown(fixture.close);

        final firstStart = fixture.controller.start();
        expect(await fixture.controller.start(), isFalse);
        permission.complete(MicrophonePermissionStatus.granted);
        expect(await firstStart, isTrue);
        await fixture.controller.stop();

        final submit = fixture.controller.submit();
        await Future<void>.delayed(Duration.zero);
        expect(fixture.controller.state.phase, VoiceMessagePhase.submitting);
        expect(await fixture.controller.cancel(), isFalse);
        fixture.submitter.complete(
          const VoiceAttachmentAcceptance(durablyAccepted: true),
        );
        expect(await submit, isTrue);
      },
    );

    test('close is idempotent and cleans an unsubmitted preview', () async {
      final fixture = _VoiceFixture();
      await fixture.preparePreview();

      await fixture.controller.close();
      await fixture.controller.close();

      expect(fixture.recorder.discarded, hasLength(1));
      expect(fixture.recorder.closes, 1);
      expect(fixture.player.closes, 1);
    });
  });
}

AttachmentCapabilityProfile _attachmentProfile({bool voice = true}) {
  final payload = capabilitiesJson(
    talkFeatures: <String>[
      'chat-reference-id',
      if (voice) 'voice-message-sharing',
    ],
  );
  final ocs = payload['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  final capabilities = data['capabilities']! as Map<String, Object?>;
  final spreed = capabilities['spreed']! as Map<String, Object?>;
  spreed['config'] = <String, Object?>{
    'attachments': <String, Object?>{
      'allowed': true,
      'conversation-subfolders': true,
    },
  };
  return AttachmentCapabilityProfile.fromSnapshot(
    CapabilitySnapshot.fromJson(
      payload,
      context: CapabilityContext.authenticated,
    ),
    federated: false,
  );
}

VoiceRecording _recording({String mimeType = 'audio/wav'}) => VoiceRecording(
  source: PreparedAttachmentSource(
    handle: AttachmentSourceHandle.parse('app-private://voice-fixture.wav'),
    ownership: AttachmentSourceOwnership.appOwnedCopy,
    byteLength: 1024,
    sha256: AttachmentSha256.parse('a' * 64),
    mimeType: mimeType,
    displayName: 'voice-fixture.wav',
  ),
  duration: const Duration(seconds: 3),
);

final class _VoiceFixture {
  _VoiceFixture({
    AttachmentCapabilityProfile? profile,
    MicrophonePermissionStatus permissionStatus =
        MicrophonePermissionStatus.granted,
    MicrophonePermissionGateway? permission,
    VoiceRecording? recording,
    Object? submitError,
    bool controlledPlayback = false,
    bool controlledSubmit = false,
  }) : permission = permission ?? _FakePermission(permissionStatus),
       recorder = _FakeRecorder(recording ?? _recording()),
       player = _FakePlayer(controlled: controlledPlayback),
       submitter = _FakeSubmitter(
         error: submitError,
         controlled: controlledSubmit,
       ) {
    controller = VoiceMessageController(
      capabilityProfile: profile ?? _attachmentProfile(),
      permissionGateway: this.permission,
      recorder: recorder,
      previewPlayer: player,
      submitter: submitter,
      submissionContext: const VoiceAttachmentContext(),
    );
  }

  final MicrophonePermissionGateway permission;
  final _FakeRecorder recorder;
  final _FakePlayer player;
  final _FakeSubmitter submitter;
  late final VoiceMessageController controller;

  Future<void> preparePreview() async {
    expect(await controller.start(), isTrue);
    expect(await controller.stop(), isTrue);
  }

  Future<void> close() => controller.close();
}

class _FakePermission implements MicrophonePermissionGateway {
  _FakePermission(this.status);

  final MicrophonePermissionStatus status;
  int requests = 0;

  @override
  Future<MicrophonePermissionStatus> request() async {
    requests++;
    return status;
  }
}

final class _ControlledPermission extends _FakePermission {
  _ControlledPermission() : super(MicrophonePermissionStatus.granted);

  final Completer<MicrophonePermissionStatus> _completer = Completer();

  @override
  Future<MicrophonePermissionStatus> request() {
    requests++;
    return _completer.future;
  }

  void complete(MicrophonePermissionStatus status) =>
      _completer.complete(status);
}

final class _FakeRecorder implements VoiceRecorder {
  _FakeRecorder(this.recording);

  final VoiceRecording recording;
  final StreamController<double> _amplitude =
      StreamController<double>.broadcast();
  int starts = 0;
  int pauses = 0;
  int resumes = 0;
  int cancels = 0;
  int closes = 0;
  final List<PreparedAttachmentSource> discarded = [];

  @override
  Future<void> start() async => starts++;

  @override
  Future<void> pause() async => pauses++;

  @override
  Future<void> resume() async => resumes++;

  @override
  Stream<double> get amplitude => _amplitude.stream;

  void emitAmplitude(double value) => _amplitude.add(value);

  @override
  Future<VoiceRecording> stop() async => recording;

  @override
  Future<void> cancel() async => cancels++;

  @override
  Future<void> discard(PreparedAttachmentSource source) async {
    discarded.add(source);
  }

  @override
  Future<void> close() async {
    closes++;
    await _amplitude.close();
  }
}

final class _FakePlayer implements VoicePreviewPlayer {
  _FakePlayer({required this.controlled});

  final bool controlled;
  Completer<void>? _playback;
  int plays = 0;
  int stops = 0;
  int closes = 0;

  @override
  Future<void> play(PreparedAttachmentSource source) {
    plays++;
    if (!controlled) {
      return Future<void>.value();
    }
    return (_playback = Completer<void>()).future;
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> close() async => closes++;

  void completePlayback() => _playback?.complete();
}

final class _FakeSubmitter implements VoiceAttachmentSubmitter {
  _FakeSubmitter({required this.error, required this.controlled});

  final Object? error;
  final bool controlled;
  final List<VoiceAttachmentSubmission> submissions = [];
  Completer<VoiceAttachmentAcceptance>? _submission;

  @override
  Future<VoiceAttachmentAcceptance> submit(
    VoiceAttachmentSubmission submission,
  ) async {
    submissions.add(submission);
    if (error != null) {
      throw error!;
    }
    if (controlled) {
      return (_submission = Completer<VoiceAttachmentAcceptance>()).future;
    }
    return const VoiceAttachmentAcceptance(durablyAccepted: true);
  }

  void complete(VoiceAttachmentAcceptance result) =>
      _submission?.complete(result);
}
