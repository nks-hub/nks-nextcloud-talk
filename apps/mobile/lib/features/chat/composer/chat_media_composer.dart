import 'dart:async';

import 'package:flutter/material.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../network/attachment_transport.dart';
import '../../../platform/media/durable_attachment_source_store.dart';
import '../../../platform/media/image_attachment_picker.dart';
import '../../../platform/media/voice_platform_adapters.dart';
import '../media/image_attachment_upload_controller.dart';
import '../media/image_attachment_upload_panel.dart';
import 'attachment_submission.dart';
import 'voice_message.dart';

typedef CreateVoiceCaptureBackend = VoiceCaptureBackend Function();
typedef CreateVoicePlaybackBackend = VoicePlaybackBackend Function();

final class ChatMediaComposer extends StatefulWidget {
  const ChatMediaComposer({
    super.key,
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.threadId,
    required this.sourceStore,
    required this.capabilityProfile,
    required this.submissionBridge,
    this.idleActions = const <Widget>[],
    this.imageSelectionBackend = const FileSelectorImageSelectionBackend(),
    this.createVoiceCaptureBackend,
    this.createVoicePlaybackBackend,
  });

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final int? threadId;
  final DurableAttachmentSourceStore sourceStore;
  final AttachmentCapabilityProfile capabilityProfile;
  final AttachmentSubmissionBridge submissionBridge;
  final List<Widget> idleActions;
  final ImageSelectionBackend imageSelectionBackend;
  final CreateVoiceCaptureBackend? createVoiceCaptureBackend;
  final CreateVoicePlaybackBackend? createVoicePlaybackBackend;

  @override
  State<ChatMediaComposer> createState() => _ChatMediaComposerState();
}

final class _ChatMediaComposerState extends State<ChatMediaComposer> {
  static const _submittedConfirmationDuration = Duration(milliseconds: 900);

  late final VoiceAttachmentSubmitter _voiceSubmitter;
  late DurableImageAttachmentPicker _imagePicker;
  late ImageAttachmentUploadController _imageController;
  AttachmentSubmissionBridge? _retainedImageSubmissionBridge;
  VoiceMessageController? _voiceController;
  AttachmentCancellationController? _imagePreparationCancellation;
  PreparedAttachmentSource? _preparedImageSource;
  Timer? _voiceResetTimer;
  bool _disposed = false;

  AttachmentMetadata get _imageMetadata => AttachmentMetadata(
    kind: AttachmentMessageKind.file,
    replyTo: null,
    threadId: widget.threadId,
    silent: false,
  );

  AttachmentMetadata get _voiceMetadata => AttachmentMetadata(
    kind: AttachmentMessageKind.voice,
    replyTo: null,
    threadId: widget.threadId,
    silent: false,
  );

  bool get _imageSupported => widget.capabilityProfile.supports(_imageMetadata);

  bool get _voiceSupported =>
      widget.capabilityProfile.voice &&
      widget.capabilityProfile.supports(_voiceMetadata);

  @override
  void initState() {
    super.initState();
    _voiceSubmitter = _CurrentVoiceAttachmentSubmitter(
      () => widget.submissionBridge,
    );
    _initializeControllers();
  }

  @override
  void didUpdateWidget(covariant ChatMediaComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountId == widget.accountId &&
        oldWidget.server == widget.server &&
        oldWidget.roomToken == widget.roomToken &&
        oldWidget.threadId == widget.threadId &&
        identical(oldWidget.sourceStore, widget.sourceStore) &&
        _sameProfile(oldWidget.capabilityProfile, widget.capabilityProfile)) {
      return;
    }
    _releaseControllers();
    _initializeControllers();
  }

  void _initializeControllers() {
    _imagePicker = DurableImageAttachmentPicker(
      backend: widget.imageSelectionBackend,
      store: widget.sourceStore,
      maximumImageBytes: widget.sourceStore.maximumSourceBytes,
    );
    _imageController = ImageAttachmentUploadController(
      startUpload: _startImageUpload,
    )..addListener(_handleImageState);
    _voiceController = _voiceSupported ? _createVoiceController() : null;
  }

  VoiceMessageController _createVoiceController() {
    final captureBackend =
        widget.createVoiceCaptureBackend?.call() ??
        RecordPluginVoiceCaptureBackend();
    final recorder = RecordVoiceRecorder(
      backend: captureBackend,
      store: widget.sourceStore,
    );
    final playbackBackend =
        widget.createVoicePlaybackBackend?.call() ??
        AudioplayersVoicePlaybackBackend();
    final controller = VoiceMessageController(
      capabilityProfile: widget.capabilityProfile,
      permissionGateway: RecordMicrophonePermissionGateway(captureBackend),
      recorder: recorder,
      previewPlayer: AudioplayersVoicePreviewPlayer(
        backend: playbackBackend,
        store: widget.sourceStore,
      ),
      submitter: _voiceSubmitter,
      submissionContext: VoiceAttachmentContext(threadId: widget.threadId),
    );
    controller.addListener(_handleVoiceState);
    return controller;
  }

  Future<ImageAttachmentUploadSession> _startImageUpload(
    ImageAttachmentUploadRequest request,
  ) async {
    final bridge = _retainedImageSubmissionBridge ?? widget.submissionBridge;
    _retainedImageSubmissionBridge = bridge;
    final session = await bridge.startImageUpload(request);
    if (_sameSource(_preparedImageSource, request.source)) {
      _preparedImageSource = null;
    }
    return session;
  }

  Future<ImageAttachmentUploadRequest?> _prepareImage() async {
    if (!_imageSupported) {
      throw const AttachmentSubmissionException(
        AttachmentSubmissionFailure.unsupported,
      );
    }
    final cancellation = AttachmentCancellationController();
    _imagePreparationCancellation = cancellation;
    PreparedAttachmentSource? source;
    try {
      source = await _imagePicker.pick(cancellationSignal: cancellation.signal);
      if (source == null) {
        return null;
      }
      if (_disposed || cancellation.isCancelled) {
        await widget.sourceStore.discard(source.handle);
        return null;
      }
      _preparedImageSource = source;
      return ImageAttachmentUploadRequest(
        accountId: widget.accountId,
        server: widget.server,
        roomToken: widget.roomToken,
        source: source,
        metadata: _imageMetadata,
      );
    } finally {
      if (identical(_imagePreparationCancellation, cancellation)) {
        _imagePreparationCancellation = null;
      }
    }
  }

  void _handleImageState() {
    final state = _imageController.state;
    if (!state.isActive &&
        !(state.phase == ImageAttachmentUploadPhase.failed &&
            state.retryAllowed)) {
      _retainedImageSubmissionBridge = null;
    }
    if (state.phase == ImageAttachmentUploadPhase.cancelling) {
      _imagePreparationCancellation?.cancel();
    }
    if (state.phase == ImageAttachmentUploadPhase.cancelled ||
        state.phase == ImageAttachmentUploadPhase.idle) {
      _discardPreparedImage();
    }
  }

  void _handleVoiceState() {
    final controller = _voiceController;
    if (!_disposed && mounted) {
      setState(() {});
    }
    if (controller == null ||
        controller.state.phase != VoiceMessagePhase.submitted ||
        _voiceResetTimer != null) {
      return;
    }
    _voiceResetTimer = Timer(_submittedConfirmationDuration, () {
      _voiceResetTimer = null;
      if (_disposed || !identical(_voiceController, controller)) {
        return;
      }
      controller.removeListener(_handleVoiceState);
      unawaited(controller.close());
      setState(() => _voiceController = _createVoiceController());
    });
  }

  void _discardPreparedImage() {
    final source = _preparedImageSource;
    _preparedImageSource = null;
    if (source != null) {
      unawaited(widget.sourceStore.discard(source.handle));
    }
  }

  void _releaseControllers() {
    _voiceResetTimer?.cancel();
    _voiceResetTimer = null;
    _imagePreparationCancellation?.cancel();
    _imagePreparationCancellation = null;
    _imageController
      ..removeListener(_handleImageState)
      ..dispose();
    _retainedImageSubmissionBridge = null;
    _discardPreparedImage();
    final voiceController = _voiceController;
    _voiceController = null;
    if (voiceController != null) {
      voiceController.removeListener(_handleVoiceState);
      unawaited(voiceController.close());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _releaseControllers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final voiceController = _voiceController;
    final voiceOwnsToolbar =
        voiceController != null && !_showsIdleToolbar(voiceController.state);
    return Column(
      key: const Key('chat-media-composer'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ImageAttachmentUploadPanel(controller: _imageController),
        Row(
          key: const Key('chat-media-composer-actions'),
          crossAxisAlignment: CrossAxisAlignment.center,
          children: voiceOwnsToolbar
              ? <Widget>[
                  Expanded(
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: VoiceMessageControls(
                        controller: voiceController,
                        labels: _voiceLabels(strings),
                      ),
                    ),
                  ),
                ]
              : <Widget>[
                  ImageAttachmentPickerButton(
                    controller: _imageController,
                    prepare: _prepareImage,
                    enabled: _imageSupported,
                  ),
                  if (voiceController == null)
                    SizedBox.square(
                      dimension: 48,
                      child: IconButton(
                        key: const Key('voice-record-unavailable'),
                        onPressed: null,
                        tooltip: strings.voiceUnsupported,
                        icon: const Icon(Icons.mic_off_outlined),
                      ),
                    )
                  else
                    VoiceMessageControls(
                      controller: voiceController,
                      labels: _voiceLabels(strings),
                    ),
                  const Spacer(),
                  ...widget.idleActions,
                ],
        ),
      ],
    );
  }
}

final class _CurrentVoiceAttachmentSubmitter
    implements VoiceAttachmentSubmitter {
  const _CurrentVoiceAttachmentSubmitter(this._current);

  final VoiceAttachmentSubmitter Function() _current;

  @override
  Future<VoiceAttachmentAcceptance> submit(
    VoiceAttachmentSubmission submission,
  ) => _current().submit(submission);
}

final class ChatMediaComposerStatus extends StatelessWidget {
  const ChatMediaComposerStatus.loading({
    super.key,
    this.idleActions = const <Widget>[],
  }) : unavailable = false,
       onRetry = null;

  const ChatMediaComposerStatus.unavailable({
    super.key,
    required this.onRetry,
    this.idleActions = const <Widget>[],
  }) : unavailable = true;

  final bool unavailable;
  final VoidCallback? onRetry;
  final List<Widget> idleActions;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Column(
      key: Key(
        unavailable
            ? 'chat-media-composer-unavailable'
            : 'chat-media-composer-loading',
      ),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                unavailable
                    ? strings.mediaCapabilityUnavailable
                    : strings.mediaCapabilityChecking,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (unavailable)
              IconButton(
                key: const Key('retry-media-capabilities'),
                onPressed: onRetry,
                tooltip: strings.retryMediaCapabilities,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: const Icon(Icons.refresh_rounded),
              ),
          ],
        ),
        Row(
          key: const Key('chat-media-composer-actions'),
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox.square(
              dimension: 48,
              child: IconButton(
                key: const Key('pick-image-attachment-unavailable'),
                onPressed: null,
                tooltip: strings.mediaCapabilityUnavailable,
                icon: const Icon(Icons.add_photo_alternate_outlined),
              ),
            ),
            SizedBox.square(
              dimension: 48,
              child: IconButton(
                key: const Key('voice-record-unavailable'),
                onPressed: null,
                tooltip: strings.voiceUnsupported,
                icon: const Icon(Icons.mic_none_rounded),
              ),
            ),
            const Spacer(),
            ...idleActions,
          ],
        ),
      ],
    );
  }
}

bool _showsIdleToolbar(VoiceMessageState state) =>
    state.phase == VoiceMessagePhase.idle ||
    (state.phase == VoiceMessagePhase.error && state.draft == null);

VoiceMessageLabels _voiceLabels(AppLocalizations strings) => VoiceMessageLabels(
  record: strings.recordVoiceMessage,
  stop: strings.stopVoiceRecording,
  play: strings.playVoicePreview,
  cancel: strings.cancelVoiceMessage,
  send: strings.sendVoiceMessage,
  sent: strings.voiceMessageQueued,
  errorLabel: (error) => switch (error) {
    VoiceMessageError.unsupported => strings.voiceUnsupported,
    VoiceMessageError.permissionDenied => strings.voicePermissionDenied,
    VoiceMessageError.permissionPermanentlyDenied =>
      strings.voicePermissionPermanentlyDenied,
    VoiceMessageError.permissionRequestFailed =>
      strings.voicePermissionRequestFailed,
    VoiceMessageError.recordingFailed => strings.voiceRecordingFailed,
    VoiceMessageError.invalidRecording => strings.voiceInvalidRecording,
    VoiceMessageError.playbackFailed => strings.voicePlaybackFailed,
    VoiceMessageError.submitFailed => strings.voiceSendFailed,
    VoiceMessageError.cleanupFailed => strings.voiceCleanupFailed,
  },
);

bool _sameSource(
  PreparedAttachmentSource? left,
  PreparedAttachmentSource right,
) =>
    left?.handle == right.handle &&
    left?.sha256 == right.sha256 &&
    left?.byteLength == right.byteLength;

bool _sameProfile(
  AttachmentCapabilityProfile left,
  AttachmentCapabilityProfile right,
) =>
    left.federated == right.federated &&
    left.enabled == right.enabled &&
    left.caption == right.caption &&
    left.voice == right.voice &&
    left.reply == right.reply &&
    left.threads == right.threads &&
    left.silent == right.silent;
