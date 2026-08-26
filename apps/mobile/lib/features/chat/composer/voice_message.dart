import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:talk_protocol/talk_protocol.dart';

enum MicrophonePermissionStatus { granted, denied, permanentlyDenied }

abstract interface class MicrophonePermissionGateway {
  Future<MicrophonePermissionStatus> request();
}

abstract interface class VoiceRecorder {
  Future<void> start();

  Future<void> pause();

  Future<void> resume();

  /// Loudness of the running recording, normalised to 0..1, for the waveform
  /// the composer draws. Silent while the session is paused.
  Stream<double> get amplitude;

  Future<VoiceRecording> stop();

  Future<void> cancel();

  Future<void> discard(PreparedAttachmentSource source);

  Future<void> close();
}

abstract interface class VoicePreviewPlayer {
  Future<void> play(PreparedAttachmentSource source);

  Future<void> stop();

  Future<void> close();
}

abstract interface class VoiceAttachmentSubmitter {
  Future<VoiceAttachmentAcceptance> submit(
    VoiceAttachmentSubmission submission,
  );
}

final class VoiceRecording {
  const VoiceRecording({required this.source, required this.duration});

  final PreparedAttachmentSource source;
  final Duration duration;
}

final class VoiceMessageDraft {
  const VoiceMessageDraft({required this.source, required this.duration});

  final PreparedAttachmentSource source;
  final Duration duration;
}

final class VoiceAttachmentContext {
  const VoiceAttachmentContext({
    this.caption,
    this.replyTo,
    this.threadId,
    this.threadTitle,
    this.silent = false,
  });

  final String? caption;
  final int? replyTo;
  final int? threadId;
  final String? threadTitle;
  final bool silent;

  AttachmentMetadata toMetadata() => AttachmentMetadata(
    kind: AttachmentMessageKind.voice,
    caption: caption,
    replyTo: replyTo,
    threadId: threadId,
    threadTitle: threadTitle,
    silent: silent,
  );
}

final class VoiceAttachmentSubmission {
  const VoiceAttachmentSubmission({
    required this.source,
    required this.duration,
    required this.metadata,
  });

  final PreparedAttachmentSource source;
  final Duration duration;
  final AttachmentMetadata metadata;
}

final class VoiceAttachmentAcceptance {
  const VoiceAttachmentAcceptance({required this.durablyAccepted});

  final bool durablyAccepted;
}

enum VoiceMessagePhase {
  idle,
  requestingPermission,
  recording,
  paused,
  preparingPreview,
  ready,
  playing,
  submitting,
  submitted,
  error,
}

enum VoiceMessageError {
  unsupported,
  permissionDenied,
  permissionPermanentlyDenied,
  permissionRequestFailed,
  recordingFailed,
  pauseFailed,
  invalidRecording,
  playbackFailed,
  submitFailed,
  cleanupFailed,
}

final class VoiceMessageState {
  const VoiceMessageState({required this.phase, this.draft, this.error});

  static const idle = VoiceMessageState(phase: VoiceMessagePhase.idle);

  final VoiceMessagePhase phase;
  final VoiceMessageDraft? draft;
  final VoiceMessageError? error;

  bool get hasRetryablePreview => draft != null;
}

final class VoiceMessageController extends ChangeNotifier {
  VoiceMessageController({
    required this.capabilityProfile,
    required this.permissionGateway,
    required this.recorder,
    required this.previewPlayer,
    required this.submitter,
    required this.submissionContext,
    this.submissionContextResolver,
    this.onReplyDurablyAccepted,
  });

  final AttachmentCapabilityProfile capabilityProfile;
  final MicrophonePermissionGateway permissionGateway;
  final VoiceRecorder recorder;
  final VoicePreviewPlayer previewPlayer;
  final VoiceAttachmentSubmitter submitter;
  final VoiceAttachmentContext submissionContext;
  final VoiceAttachmentContext? Function()? submissionContextResolver;
  final ValueChanged<int>? onReplyDurablyAccepted;

  VoiceMessageState _state = VoiceMessageState.idle;
  VoiceMessageState get state => _state;

  bool _closed = false;
  bool _ownershipTransferred = false;
  int _operationGeneration = 0;
  int _playGeneration = 0;
  Future<void>? _closeFuture;

  Future<bool> start() async {
    if (_closed ||
        (_state.phase != VoiceMessagePhase.idle &&
            !(_state.phase == VoiceMessagePhase.error &&
                _state.draft == null))) {
      return false;
    }
    final context = _resolveSubmissionContext();
    final metadata = context?.toMetadata();
    if (!capabilityProfile.voice ||
        metadata == null ||
        !capabilityProfile.supports(metadata)) {
      _setError(VoiceMessageError.unsupported);
      return false;
    }

    final generation = ++_operationGeneration;
    _setState(
      const VoiceMessageState(phase: VoiceMessagePhase.requestingPermission),
    );
    final MicrophonePermissionStatus permission;
    try {
      permission = await permissionGateway.request();
    } on Object {
      if (_isCurrent(generation)) {
        _setError(VoiceMessageError.permissionRequestFailed);
      }
      return false;
    }
    if (!_isCurrent(generation)) {
      return false;
    }
    if (permission != MicrophonePermissionStatus.granted) {
      _setError(
        permission == MicrophonePermissionStatus.permanentlyDenied
            ? VoiceMessageError.permissionPermanentlyDenied
            : VoiceMessageError.permissionDenied,
      );
      return false;
    }

    try {
      await recorder.start();
    } on Object {
      if (_isCurrent(generation)) {
        _setError(VoiceMessageError.recordingFailed);
      }
      return false;
    }
    if (!_isCurrent(generation)) {
      await _bestEffort(recorder.cancel);
      return false;
    }
    _setState(const VoiceMessageState(phase: VoiceMessagePhase.recording));
    return true;
  }

  /// Normalised loudness of the running recording, for the waveform.
  Stream<double> get amplitude => recorder.amplitude;

  Future<bool> pauseRecording() async {
    if (_closed || _state.phase != VoiceMessagePhase.recording) {
      return false;
    }
    final generation = _operationGeneration;
    try {
      await recorder.pause();
    } on Object {
      if (_isCurrent(generation)) {
        _setError(VoiceMessageError.pauseFailed);
      }
      return false;
    }
    if (!_isCurrent(generation)) {
      return false;
    }
    _setState(const VoiceMessageState(phase: VoiceMessagePhase.paused));
    return true;
  }

  Future<bool> resumeRecording() async {
    if (_closed || _state.phase != VoiceMessagePhase.paused) {
      return false;
    }
    final generation = _operationGeneration;
    try {
      await recorder.resume();
    } on Object {
      if (_isCurrent(generation)) {
        _setError(VoiceMessageError.pauseFailed);
      }
      return false;
    }
    if (!_isCurrent(generation)) {
      return false;
    }
    _setState(const VoiceMessageState(phase: VoiceMessagePhase.recording));
    return true;
  }

  Future<bool> stop() async {
    if (_closed ||
        (_state.phase != VoiceMessagePhase.recording &&
            _state.phase != VoiceMessagePhase.paused)) {
      return false;
    }
    final generation = ++_operationGeneration;
    _setState(
      const VoiceMessageState(phase: VoiceMessagePhase.preparingPreview),
    );
    final VoiceRecording recording;
    try {
      recording = await recorder.stop();
    } on Object {
      if (_isCurrent(generation)) {
        _setError(VoiceMessageError.recordingFailed);
      }
      return false;
    }
    if (!_validRecording(recording)) {
      await _bestEffort(() => recorder.discard(recording.source));
      if (_isCurrent(generation)) {
        _setError(VoiceMessageError.invalidRecording);
      }
      return false;
    }
    if (!_isCurrent(generation)) {
      await _bestEffort(() => recorder.discard(recording.source));
      return false;
    }
    _ownershipTransferred = false;
    _setState(
      VoiceMessageState(
        phase: VoiceMessagePhase.ready,
        draft: VoiceMessageDraft(
          source: recording.source,
          duration: recording.duration,
        ),
      ),
    );
    return true;
  }

  Future<bool> play() async {
    final draft = _state.draft;
    if (_closed ||
        draft == null ||
        (_state.phase != VoiceMessagePhase.ready &&
            _state.phase != VoiceMessagePhase.error)) {
      return false;
    }
    final generation = ++_playGeneration;
    _setState(
      VoiceMessageState(phase: VoiceMessagePhase.playing, draft: draft),
    );
    try {
      await previewPlayer.play(draft.source);
    } on Object {
      if (_isCurrentPlay(generation)) {
        _setState(
          VoiceMessageState(
            phase: VoiceMessagePhase.error,
            draft: draft,
            error: VoiceMessageError.playbackFailed,
          ),
        );
      }
      return false;
    }
    if (!_isCurrentPlay(generation)) {
      return false;
    }
    _setState(VoiceMessageState(phase: VoiceMessagePhase.ready, draft: draft));
    return true;
  }

  Future<bool> submit() async {
    final draft = _state.draft;
    if (_closed ||
        draft == null ||
        (_state.phase != VoiceMessagePhase.ready &&
            _state.phase != VoiceMessagePhase.error)) {
      return false;
    }
    final context = _resolveSubmissionContext();
    final metadata = context?.toMetadata();
    if (metadata == null ||
        !capabilityProfile.supports(metadata) ||
        !metadata.supportsSource(draft.source)) {
      _setState(
        VoiceMessageState(
          phase: VoiceMessagePhase.error,
          draft: draft,
          error: VoiceMessageError.invalidRecording,
        ),
      );
      return false;
    }
    final generation = ++_operationGeneration;
    _setState(
      VoiceMessageState(phase: VoiceMessagePhase.submitting, draft: draft),
    );
    try {
      final acceptance = await submitter.submit(
        VoiceAttachmentSubmission(
          source: draft.source,
          duration: draft.duration,
          metadata: metadata,
        ),
      );
      if (!_isCurrent(generation)) {
        return false;
      }
      if (!acceptance.durablyAccepted) {
        _setState(
          VoiceMessageState(
            phase: VoiceMessagePhase.error,
            draft: draft,
            error: VoiceMessageError.submitFailed,
          ),
        );
        return false;
      }
      _ownershipTransferred = true;
      _setState(const VoiceMessageState(phase: VoiceMessagePhase.submitted));
      final replyTo = metadata.replyTo;
      if (replyTo != null && !_closed) {
        try {
          onReplyDurablyAccepted?.call(replyTo);
        } on Object {
          // Durable admission already succeeded; host rendering is separate.
        }
      }
      return true;
    } on Object {
      if (_isCurrent(generation)) {
        _setState(
          VoiceMessageState(
            phase: VoiceMessagePhase.error,
            draft: draft,
            error: VoiceMessageError.submitFailed,
          ),
        );
      }
      return false;
    }
  }

  Future<bool> cancel() async {
    if (_closed || _state.phase == VoiceMessagePhase.submitting) {
      return false;
    }
    if (_state.phase == VoiceMessagePhase.recording ||
        _state.phase == VoiceMessagePhase.paused) {
      ++_operationGeneration;
      try {
        await recorder.cancel();
      } on Object {
        _setError(VoiceMessageError.cleanupFailed);
        return false;
      }
      _ownershipTransferred = false;
      _setState(VoiceMessageState.idle);
      return true;
    }

    final draft = _state.draft;
    if (draft == null ||
        !const <VoiceMessagePhase>{
          VoiceMessagePhase.ready,
          VoiceMessagePhase.playing,
          VoiceMessagePhase.error,
        }.contains(_state.phase)) {
      return false;
    }
    ++_operationGeneration;
    ++_playGeneration;
    try {
      if (_state.phase == VoiceMessagePhase.playing) {
        await previewPlayer.stop();
      }
      if (!_ownershipTransferred) {
        await recorder.discard(draft.source);
      }
    } on Object {
      _setState(
        VoiceMessageState(
          phase: VoiceMessagePhase.error,
          draft: draft,
          error: VoiceMessageError.cleanupFailed,
        ),
      );
      return false;
    }
    _ownershipTransferred = false;
    _setState(VoiceMessageState.idle);
    return true;
  }

  Future<void> close() {
    return _closeFuture ??= _close();
  }

  Future<void> _close() async {
    _closed = true;
    ++_operationGeneration;
    ++_playGeneration;
    final phase = _state.phase;
    final draft = _state.draft;
    if (phase == VoiceMessagePhase.recording ||
        phase == VoiceMessagePhase.paused) {
      await _bestEffort(recorder.cancel);
    }
    if (phase == VoiceMessagePhase.playing) {
      await _bestEffort(previewPlayer.stop);
    }
    if (draft != null && !_ownershipTransferred) {
      await _bestEffort(() => recorder.discard(draft.source));
    }
    await _bestEffort(previewPlayer.close);
    await _bestEffort(recorder.close);
  }

  bool _validRecording(VoiceRecording recording) {
    if (recording.duration <= Duration.zero ||
        recording.duration > const Duration(hours: 24)) {
      return false;
    }
    final metadata = _resolveSubmissionContext()?.toMetadata();
    return metadata != null &&
        capabilityProfile.supports(metadata) &&
        metadata.supportsSource(recording.source) &&
        const <AttachmentSourceOwnership>{
          AttachmentSourceOwnership.appOwnedCopy,
          AttachmentSourceOwnership.persistableUri,
        }.contains(recording.source.ownership);
  }

  bool _isCurrent(int generation) =>
      !_closed && generation == _operationGeneration;

  bool _isCurrentPlay(int generation) =>
      !_closed && generation == _playGeneration;

  VoiceAttachmentContext? _resolveSubmissionContext() {
    try {
      final resolver = submissionContextResolver;
      return resolver == null ? submissionContext : resolver();
    } on Object {
      return null;
    }
  }

  void _setError(VoiceMessageError error) {
    _setState(VoiceMessageState(phase: VoiceMessagePhase.error, error: error));
  }

  void _setState(VoiceMessageState value) {
    if (_closed) {
      return;
    }
    _state = value;
    notifyListeners();
  }
}

final class VoiceMessageLabels {
  const VoiceMessageLabels({
    required this.record,
    required this.pause,
    required this.resume,
    required this.level,
    required this.stop,
    required this.play,
    required this.cancel,
    required this.send,
    required this.sent,
    required this.errorLabel,
  });

  final String record;
  final String pause;
  final String resume;
  final String level;
  final String stop;
  final String play;
  final String cancel;
  final String send;
  final String sent;
  final String Function(VoiceMessageError error) errorLabel;
}

final class VoiceMessageControls extends StatelessWidget {
  const VoiceMessageControls({
    required this.controller,
    required this.labels,
    super.key,
  });

  final VoiceMessageController controller;
  final VoiceMessageLabels labels;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final state = controller.state;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state.error case final error?)
              Flexible(
                child: Semantics(
                  liveRegion: true,
                  child: Text(labels.errorLabel(error)),
                ),
              ),
            ..._actions(state),
          ],
        );
      },
    );
  }

  List<Widget> _actions(VoiceMessageState state) => switch (state.phase) {
    VoiceMessagePhase.idle ||
    VoiceMessagePhase.error when state.draft == null => <Widget>[
      _button(
        key: const Key('voice-record'),
        tooltip: labels.record,
        icon: Icons.mic_rounded,
        action: controller.start,
      ),
    ],
    VoiceMessagePhase.recording || VoiceMessagePhase.paused => <Widget>[
      _button(
        key: const Key('voice-cancel-recording'),
        tooltip: labels.cancel,
        icon: Icons.delete_outline_rounded,
        action: controller.cancel,
      ),
      VoiceRecordingWaveform(
        key: const Key('voice-waveform'),
        amplitude: controller.amplitude,
        label: labels.level,
        live: state.phase == VoiceMessagePhase.recording,
      ),
      if (state.phase == VoiceMessagePhase.recording)
        _button(
          key: const Key('voice-pause'),
          tooltip: labels.pause,
          icon: Icons.pause_rounded,
          action: controller.pauseRecording,
        )
      else
        _button(
          key: const Key('voice-resume'),
          tooltip: labels.resume,
          icon: Icons.fiber_manual_record_rounded,
          action: controller.resumeRecording,
        ),
      _button(
        key: const Key('voice-stop'),
        tooltip: labels.stop,
        icon: Icons.stop_rounded,
        action: controller.stop,
      ),
    ],
    VoiceMessagePhase.ready ||
    VoiceMessagePhase.error when state.draft != null => <Widget>[
      _button(
        key: const Key('voice-cancel-preview'),
        tooltip: labels.cancel,
        icon: Icons.delete_outline_rounded,
        action: controller.cancel,
      ),
      _button(
        key: const Key('voice-play'),
        tooltip: labels.play,
        icon: Icons.play_arrow_rounded,
        action: controller.play,
      ),
      _button(
        key: const Key('voice-send'),
        tooltip: labels.send,
        icon: Icons.send_rounded,
        action: controller.submit,
      ),
    ],
    VoiceMessagePhase.playing => <Widget>[
      _button(
        key: const Key('voice-cancel-preview'),
        tooltip: labels.cancel,
        icon: Icons.stop_rounded,
        action: controller.cancel,
      ),
    ],
    VoiceMessagePhase.requestingPermission ||
    VoiceMessagePhase.preparingPreview ||
    VoiceMessagePhase.submitting => const <Widget>[
      SizedBox.square(
        dimension: 48,
        child: Padding(
          padding: EdgeInsets.all(12),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    ],
    VoiceMessagePhase.submitted => <Widget>[
      Semantics(
        liveRegion: true,
        label: labels.sent,
        child: const SizedBox.square(
          dimension: 48,
          child: Icon(Icons.check_rounded),
        ),
      ),
    ],
    _ => const <Widget>[],
  };

  Widget _button({
    required Key key,
    required String tooltip,
    required IconData icon,
    required Future<bool> Function() action,
  }) {
    return SizedBox.square(
      dimension: 48,
      child: IconButton(
        key: key,
        tooltip: tooltip,
        onPressed: () => unawaited(action()),
        icon: Icon(icon),
      ),
    );
  }
}

/// Live loudness bars for a running recording.
///
/// Every bar comes from a real amplitude sample, so the widget repaints only
/// when the recorder reports one and never schedules an animation of its own.
/// That keeps it out of the way of `pumpAndSettle`.
final class VoiceRecordingWaveform extends StatefulWidget {
  const VoiceRecordingWaveform({
    required this.amplitude,
    required this.label,
    required this.live,
    super.key,
  });

  static const int barCount = 24;

  final Stream<double> amplitude;
  final String label;

  /// Paused recordings keep the bars they already collected but stop
  /// listening, so the platform can shut its amplitude polling down.
  final bool live;

  @override
  State<VoiceRecordingWaveform> createState() => _VoiceRecordingWaveformState();
}

final class _VoiceRecordingWaveformState extends State<VoiceRecordingWaveform> {
  final List<double> _samples = <double>[];
  StreamSubscription<double>? _subscription;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(covariant VoiceRecordingWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.live == widget.live &&
        identical(oldWidget.amplitude, widget.amplitude)) {
      return;
    }
    unawaited(_subscription?.cancel());
    _subscription = null;
    _listen();
  }

  void _listen() {
    if (!widget.live) {
      return;
    }
    _subscription = widget.amplitude.listen((value) {
      if (!mounted) {
        return;
      }
      setState(() {
        _samples.add(value.clamp(0.0, 1.0));
        if (_samples.length > VoiceRecordingWaveform.barCount) {
          _samples.removeAt(0);
        }
      });
    }, onError: (Object _) {});
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.label,
      value: '${((_samples.isEmpty ? 0.0 : _samples.last) * 100).round()}%',
      child: SizedBox(
        width: 96,
        height: 32,
        child: CustomPaint(
          painter: _WaveformPainter(
            samples: List<double>.unmodifiable(_samples),
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

final class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({required this.samples, required this.color});

  final List<double> samples;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const count = VoiceRecordingWaveform.barCount;
    final slot = size.width / count;
    final barWidth = slot * 0.6;
    final paint = Paint()
      ..color = color
      ..strokeWidth = barWidth
      ..strokeCap = StrokeCap.round;
    final centre = size.height / 2;
    // Newest sample sits on the right, so the bars scroll the way the ear
    // expects while speaking.
    final offset = count - samples.length;
    for (var index = 0; index < samples.length; index++) {
      final height = (samples[index] * size.height).clamp(2.0, size.height);
      final x = (offset + index) * slot + slot / 2;
      canvas.drawLine(
        Offset(x, centre - height / 2),
        Offset(x, centre + height / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) =>
      oldDelegate.color != color || !listEquals(oldDelegate.samples, samples);
}

Future<void> _bestEffort(Future<void> Function() action) async {
  try {
    await action();
  } on Object {
    // Cleanup continues so every owned resource receives its close operation.
  }
}
