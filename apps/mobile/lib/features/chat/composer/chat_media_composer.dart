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
import 'giphy_attachment.dart';
import 'voice_message.dart';

typedef CreateVoiceCaptureBackend = VoiceCaptureBackend Function();
typedef CreateVoicePlaybackBackend = VoicePlaybackBackend Function();

typedef LoadGiphyAttachmentPayload =
    Future<GiphyAttachmentPayload> Function(
      AttachmentCancellationSignal cancellationSignal,
    );

final class ChatMediaReplyTarget {
  const ChatMediaReplyTarget({
    required this.accountId,
    required this.roomToken,
    required this.messageId,
    required this.messageThreadId,
    required this.deleted,
    required this.systemMessage,
  });

  final AccountId accountId;
  final ConversationToken roomToken;
  final int messageId;
  final int? messageThreadId;
  final bool deleted;
  final bool systemMessage;
}

enum ChatMediaThreadKind { ordinary, named }

final class ChatMediaThreadBinding {
  ChatMediaThreadBinding.ordinary({
    required this.accountId,
    required this.roomToken,
    required this.rootMessageId,
  }) : kind = ChatMediaThreadKind.ordinary {
    _validateRootMessageId(rootMessageId);
  }

  ChatMediaThreadBinding.named({
    required this.accountId,
    required this.roomToken,
    required this.rootMessageId,
  }) : kind = ChatMediaThreadKind.named {
    _validateRootMessageId(rootMessageId);
  }

  final AccountId accountId;
  final ConversationToken roomToken;
  final int rootMessageId;
  final ChatMediaThreadKind kind;

  int? get replyTo =>
      kind == ChatMediaThreadKind.ordinary ? rootMessageId : null;
  int? get threadId => kind == ChatMediaThreadKind.named ? rootMessageId : null;

  bool matches({
    required AccountId accountId,
    required ConversationToken roomToken,
    required int rootMessageId,
  }) =>
      this.accountId == accountId &&
      this.roomToken == roomToken &&
      this.rootMessageId == rootMessageId;

  @override
  bool operator ==(Object other) =>
      other is ChatMediaThreadBinding &&
      other.accountId == accountId &&
      other.roomToken == roomToken &&
      other.rootMessageId == rootMessageId &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(accountId, roomToken, rootMessageId, kind);

  static void _validateRootMessageId(int value) {
    if (value < 1) {
      throw ArgumentError.value(value, 'rootMessageId');
    }
  }
}

final class ChatMediaComposerController {
  Object? _owner;
  Future<bool> Function(LoadGiphyAttachmentPayload loader)? _submitGiphy;
  Future<bool> Function(AttachmentPickerSource source)? _pickAttachment;

  Future<bool> submitGiphyAttachment(LoadGiphyAttachmentPayload loader) async {
    final submit = _submitGiphy;
    return submit == null ? false : submit(loader);
  }

  Future<bool> pickAttachment(AttachmentPickerSource source) async {
    final pick = _pickAttachment;
    return pick == null ? false : pick(source);
  }

  void _attach(
    Object owner,
    Future<bool> Function(LoadGiphyAttachmentPayload loader) submitGiphy,
    Future<bool> Function(AttachmentPickerSource source) pickAttachment,
  ) {
    _owner = owner;
    _submitGiphy = submitGiphy;
    _pickAttachment = pickAttachment;
  }

  void _detach(Object owner) {
    if (!identical(_owner, owner)) {
      return;
    }
    _owner = null;
    _submitGiphy = null;
    _pickAttachment = null;
  }
}

final class ChatMediaComposer extends StatefulWidget {
  const ChatMediaComposer({
    super.key,
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.threadId,
    this.threadBinding,
    required this.replyTarget,
    required this.onReplyDurablyAccepted,
    required this.sourceStore,
    required this.capabilityProfile,
    required this.submissionBridge,
    this.silent = false,
    this.captionSource,
    this.onCaptionConsumed,
    this.openAppSettings,
    this.controller,
    this.idleActions = const <Widget>[],
    this.trailingActions = const <Widget>[],
    this.showAttachmentButton = true,
    this.imageSelectionBackend = const PlatformAttachmentSelectionBackend(),
    this.createVoiceCaptureBackend,
    this.createVoicePlaybackBackend,
  });

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final int? threadId;
  final ChatMediaThreadBinding? threadBinding;
  final ChatMediaReplyTarget? replyTarget;
  final ValueChanged<int>? onReplyDurablyAccepted;
  final DurableAttachmentSourceStore sourceStore;
  final AttachmentCapabilityProfile capabilityProfile;
  final AttachmentSubmissionBridge submissionBridge;

  /// Suppresses the recipients' notification for whatever this composer
  /// sends next. [AttachmentCapabilityProfile.supports] rejects it where the
  /// server has no `silent-send`, so this stays a preference, not a promise.
  final bool silent;

  /// Reads whatever the host's message field holds right now.
  ///
  /// Talk sends a file with a caption by putting the text on the share
  /// itself, so an attachment picked while something is typed carries that
  /// text instead of leaving it stranded in the field. Read on submit, never
  /// cached: the picker sits open long enough for the text to change.
  final String Function()? captionSource;

  /// Fires once a caption has actually gone out with an attachment, so the
  /// host can clear the field it came from.
  final VoidCallback? onCaptionConsumed;
  final Future<bool> Function()? openAppSettings;
  final ChatMediaComposerController? controller;
  final List<Widget> idleActions;
  final List<Widget> trailingActions;
  final bool showAttachmentButton;
  final ImageSelectionBackend imageSelectionBackend;
  final CreateVoiceCaptureBackend? createVoiceCaptureBackend;
  final CreateVoicePlaybackBackend? createVoicePlaybackBackend;

  @override
  State<ChatMediaComposer> createState() => _ChatMediaComposerState();
}

final class _ChatMediaComposerState extends State<ChatMediaComposer> {
  static const _submittedConfirmationDuration = Duration(milliseconds: 900);
  static const _admissionResumeTimeout = Duration(seconds: 15);

  late final VoiceAttachmentSubmitter _voiceSubmitter;
  late DurableImageAttachmentPicker _imagePicker;
  late ImageAttachmentUploadController _imageController;
  AttachmentSubmissionBridge? _retainedImageSubmissionBridge;
  bool _imageAdmissionPending = false;
  bool _discardPreparedImageAfterAdmission = false;
  VoiceMessageController? _voiceController;
  AttachmentCancellationController? _imagePreparationCancellation;
  PreparedAttachmentSource? _preparedImageSource;
  Timer? _voiceResetTimer;
  bool _disposed = false;

  /// The caption this submission should carry, or null when it carries none.
  ///
  /// A voice message is its own content, so it never takes the field's text,
  /// and a server without `media-caption` would only refuse the share.
  String? _captionFor(AttachmentMessageKind kind) {
    if (kind != AttachmentMessageKind.file ||
        !widget.capabilityProfile.caption) {
      return null;
    }
    final text = widget.captionSource?.call().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  AttachmentMetadata? _metadataFor(AttachmentMessageKind kind) {
    final replyTarget = widget.replyTarget;
    if (replyTarget == null) {
      final threadId = widget.threadId;
      final threadBinding = widget.threadBinding;
      if (threadId == null) {
        if (threadBinding != null) {
          return null;
        }
        return AttachmentMetadata(
          kind: kind,
          caption: _captionFor(kind),
          replyTo: null,
          threadId: null,
          silent: widget.silent,
        );
      }
      if (threadBinding == null ||
          !threadBinding.matches(
            accountId: widget.accountId,
            roomToken: widget.roomToken,
            rootMessageId: threadId,
          )) {
        return null;
      }
      return AttachmentMetadata(
        kind: kind,
        caption: _captionFor(kind),
        replyTo: threadBinding.replyTo,
        threadId: threadBinding.threadId,
        silent: widget.silent,
      );
    }
    if (widget.threadId != null ||
        widget.threadBinding != null ||
        replyTarget.messageId < 1 ||
        replyTarget.accountId != widget.accountId ||
        replyTarget.roomToken != widget.roomToken ||
        (replyTarget.messageThreadId != null &&
            replyTarget.messageThreadId != replyTarget.messageId) ||
        replyTarget.deleted ||
        replyTarget.systemMessage) {
      return null;
    }
    return AttachmentMetadata(
      kind: kind,
      caption: _captionFor(kind),
      replyTo: replyTarget.messageId,
      threadId: null,
      silent: widget.silent,
    );
  }

  _MediaAdmissionSnapshot? _captureAdmission(AttachmentMessageKind kind) {
    final metadata = _metadataFor(kind);
    if (metadata == null || !widget.capabilityProfile.supports(metadata)) {
      return null;
    }
    return _MediaAdmissionSnapshot(
      accountId: widget.accountId,
      server: widget.server,
      roomToken: widget.roomToken,
      metadata: metadata,
    );
  }

  bool get _imageSupported =>
      _captureAdmission(AttachmentMessageKind.file) != null;

  bool get _voiceAdmissionSupported =>
      _captureAdmission(AttachmentMessageKind.voice) != null;

  bool get _voiceSupported {
    final metadata = _metadataFor(AttachmentMessageKind.voice);
    return metadata != null &&
        widget.capabilityProfile.voice &&
        widget.capabilityProfile.supports(metadata);
  }

  @override
  void initState() {
    super.initState();
    _voiceSubmitter = _CurrentVoiceAttachmentSubmitter(
      () => widget.submissionBridge,
    );
    _initializeControllers();
    widget.controller?._attach(this, _submitGiphyAttachment, _pickAttachment);
  }

  @override
  void didUpdateWidget(covariant ChatMediaComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this, _submitGiphyAttachment, _pickAttachment);
    }
    if (oldWidget.accountId == widget.accountId &&
        oldWidget.server == widget.server &&
        oldWidget.roomToken == widget.roomToken &&
        oldWidget.threadId == widget.threadId &&
        oldWidget.threadBinding == widget.threadBinding &&
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
    final initialMetadata = _metadataFor(AttachmentMessageKind.voice);
    if (initialMetadata == null) {
      throw StateError('Voice controller requires a valid media binding');
    }
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
      submissionContext: VoiceAttachmentContext(
        replyTo: initialMetadata.replyTo,
        threadId: initialMetadata.threadId,
      ),
      submissionContextResolver: () {
        final metadata = _metadataFor(AttachmentMessageKind.voice);
        if (metadata == null || !widget.capabilityProfile.supports(metadata)) {
          return null;
        }
        return VoiceAttachmentContext(
          replyTo: metadata.replyTo,
          threadId: metadata.threadId,
        );
      },
      onReplyDurablyAccepted: _notifyReplyDurablyAccepted,
    );
    controller.addListener(_handleVoiceState);
    return controller;
  }

  Future<ImageAttachmentUploadSession> _startImageUpload(
    ImageAttachmentUploadRequest request,
  ) async {
    await _waitForResumedLifecycle();
    if (_disposed) {
      throw StateError('Media composer was disposed before upload admission');
    }
    final bridge = _retainedImageSubmissionBridge ?? widget.submissionBridge;
    final admissionSourceStore = widget.sourceStore;
    final acceptedReplyTo = request.metadata.replyTo;
    final acceptanceCallback = widget.onReplyDurablyAccepted;
    _retainedImageSubmissionBridge = bridge;
    _imageAdmissionPending = true;
    var durablyAccepted = false;
    try {
      final session = await bridge.startImageUpload(request);
      durablyAccepted = true;
      if (request.metadata.caption != null) {
        widget.onCaptionConsumed?.call();
      }
      if (_sameSource(_preparedImageSource, request.source)) {
        _preparedImageSource = null;
      }
      _notifyReplyDurablyAccepted(
        acceptedReplyTo,
        callback: acceptanceCallback,
      );
      return session;
    } finally {
      _imageAdmissionPending = false;
      final discardAfterAdmission = _discardPreparedImageAfterAdmission;
      _discardPreparedImageAfterAdmission = false;
      if (!durablyAccepted && discardAfterAdmission) {
        if (_sameSource(_preparedImageSource, request.source)) {
          _preparedImageSource = null;
        }
        unawaited(admissionSourceStore.discard(request.source.handle));
      }
    }
  }

  Future<void> _waitForResumedLifecycle() async {
    final binding = WidgetsBinding.instance;
    final state = binding.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) {
      return;
    }
    final resumed = Completer<void>();
    late final AppLifecycleListener listener;
    listener = AppLifecycleListener(
      onResume: () {
        if (!resumed.isCompleted) {
          resumed.complete();
        }
      },
    );
    if (binding.lifecycleState == AppLifecycleState.resumed &&
        !resumed.isCompleted) {
      resumed.complete();
    }
    try {
      await resumed.future.timeout(_admissionResumeTimeout);
    } finally {
      listener.dispose();
    }
  }

  Future<ImageAttachmentUploadRequest?> _prepareImage(
    AttachmentPickerSource pickerSource,
  ) async {
    final admission = _captureAdmission(AttachmentMessageKind.file);
    if (admission == null) {
      throw const AttachmentSubmissionException(
        AttachmentSubmissionFailure.unsupported,
      );
    }
    final cancellation = AttachmentCancellationController();
    _imagePreparationCancellation = cancellation;
    PreparedAttachmentSource? source;
    try {
      source = await _imagePicker.pick(
        source: pickerSource,
        cancellationSignal: cancellation.signal,
      );
      if (source == null) {
        return null;
      }
      if (_disposed || cancellation.isCancelled) {
        await widget.sourceStore.discard(source.handle);
        return null;
      }
      _preparedImageSource = source;
      return ImageAttachmentUploadRequest(
        accountId: admission.accountId,
        server: admission.server,
        roomToken: admission.roomToken,
        source: source,
        metadata: admission.metadata,
      );
    } on ImageAttachmentPickerException catch (error) {
      throw ImageAttachmentPreparationFailure(switch (error.code) {
        ImageAttachmentPickerError.galleryPermissionDenied =>
          'gallery-permission-denied',
        ImageAttachmentPickerError.galleryUnavailable => 'gallery-unavailable',
        ImageAttachmentPickerError.cameraPermissionDenied =>
          'camera-permission-denied',
        ImageAttachmentPickerError.cameraUnavailable => 'camera-unavailable',
        ImageAttachmentPickerError.unsupportedType ||
        ImageAttachmentPickerError.invalidSelection =>
          'unsupported-attachment-type',
      });
    } finally {
      if (identical(_imagePreparationCancellation, cancellation)) {
        _imagePreparationCancellation = null;
      }
    }
  }

  Future<bool> _submitGiphyAttachment(LoadGiphyAttachmentPayload loader) async {
    if (_disposed || !_imageSupported || _imageController.state.isActive) {
      return false;
    }
    await _imageController.pickAndStart(() => _prepareGiphyAttachment(loader));
    return true;
  }

  Future<bool> _pickAttachment(AttachmentPickerSource source) async {
    if (_disposed || !_imageSupported || _imageController.state.isActive) {
      return false;
    }
    await _imageController.pickAndStart(() => _prepareImage(source));
    return true;
  }

  Future<void> _openAppSettings() async {
    final open = widget.openAppSettings;
    if (open == null) {
      return;
    }
    final failedMessage = AppLocalizations.of(context).openAppSettingsFailed;
    try {
      final opened = await open();
      if (!opened && mounted && !_disposed) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(failedMessage)));
      }
    } on Object {
      if (mounted && !_disposed) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(failedMessage)));
      }
    }
  }

  Future<ImageAttachmentUploadRequest?> _prepareGiphyAttachment(
    LoadGiphyAttachmentPayload loader,
  ) async {
    final admission = _captureAdmission(AttachmentMessageKind.file);
    if (admission == null) {
      throw const AttachmentSubmissionException(
        AttachmentSubmissionFailure.unsupported,
      );
    }
    final cancellation = AttachmentCancellationController();
    _imagePreparationCancellation = cancellation;
    PreparedAttachmentSource? source;
    try {
      final payload = await loader(cancellation.signal);
      if (payload.mimeType != 'image/gif' ||
          !payload.displayName.toLowerCase().endsWith('.gif')) {
        throw const AttachmentSubmissionException(
          AttachmentSubmissionFailure.unsupported,
        );
      }
      if (_disposed || cancellation.isCancelled) {
        return null;
      }
      source = await widget.sourceStore.copyFromStream(
        stream: Stream<List<int>>.value(payload.body),
        mimeType: payload.mimeType,
        displayName: payload.displayName,
        expectedByteLength: payload.body.lengthInBytes,
        cancellationSignal: cancellation.signal,
      );
      if (_disposed || cancellation.isCancelled) {
        await widget.sourceStore.discard(source.handle);
        return null;
      }
      _preparedImageSource = source;
      return ImageAttachmentUploadRequest(
        accountId: admission.accountId,
        server: admission.server,
        roomToken: admission.roomToken,
        source: source,
        metadata: admission.metadata,
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

  void _notifyReplyDurablyAccepted(
    int? messageId, {
    ValueChanged<int>? callback,
  }) {
    if (messageId == null || _disposed || !mounted) {
      return;
    }
    try {
      (callback ?? widget.onReplyDurablyAccepted)?.call(messageId);
    } on Object {
      // Durable admission already succeeded; host rendering cannot undo it.
    }
  }

  void _discardPreparedImage() {
    final source = _preparedImageSource;
    if (source != null && _imageAdmissionPending) {
      _discardPreparedImageAfterAdmission = true;
      return;
    }
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
    widget.controller?._detach(this);
    _releaseControllers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final voiceController = _voiceController;
    final voiceOwnsToolbar =
        voiceController != null && !_showsIdleToolbar(voiceController.state);
    final voiceErrorUsesRemainingWidth =
        voiceController?.state.error != null &&
        voiceController?.state.draft == null;
    final showVoiceUnavailable =
        voiceController == null ||
        (!_voiceAdmissionSupported && !voiceOwnsToolbar);
    final Widget? attachmentAction = widget.showAttachmentButton
        ? ImageAttachmentPickerButton(
            controller: _imageController,
            prepare: _prepareImage,
            enabled: _imageSupported,
          )
        : null;
    final idleVoiceAction = showVoiceUnavailable
        ? SizedBox.square(
            dimension: 48,
            child: IconButton(
              key: const Key('voice-record-unavailable'),
              onPressed: null,
              tooltip: strings.voiceUnsupported,
              icon: const Icon(Icons.mic_off_outlined),
            ),
          )
        : VoiceMessageControls(
            controller: voiceController,
            labels: _voiceLabels(strings),
            onOpenSettings: widget.openAppSettings == null
                ? null
                : () => unawaited(_openAppSettings()),
          );
    return Column(
      key: const Key('chat-media-composer'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ImageAttachmentUploadPanel(
          controller: _imageController,
          onOpenSettings: widget.openAppSettings == null
              ? null
              : () => unawaited(_openAppSettings()),
        ),
        if (voiceOwnsToolbar)
          Row(
            key: const Key('chat-media-composer-actions'),
            children: <Widget>[
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: VoiceMessageControls(
                    controller: voiceController,
                    labels: _voiceLabels(strings),
                    onOpenSettings: widget.openAppSettings == null
                        ? null
                        : () => unawaited(_openAppSettings()),
                  ),
                ),
              ),
            ],
          )
        else if (voiceErrorUsesRemainingWidth)
          Column(
            key: const Key('chat-media-composer-actions'),
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              VoiceMessageControls(
                controller: voiceController!,
                labels: _voiceLabels(strings),
                onOpenSettings: widget.openAppSettings == null
                    ? null
                    : () => unawaited(_openAppSettings()),
              ),
              Wrap(
                alignment: WrapAlignment.start,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  ?attachmentAction,
                  ...widget.idleActions,
                  ...widget.trailingActions,
                ],
              ),
            ],
          )
        else
          Wrap(
            key: const Key('chat-media-composer-actions'),
            alignment: WrapAlignment.start,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              ?attachmentAction,
              ...widget.idleActions,
              idleVoiceAction,
              ...widget.trailingActions,
            ],
          ),
      ],
    );
  }
}

final class _MediaAdmissionSnapshot {
  const _MediaAdmissionSnapshot({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.metadata,
  });

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final AttachmentMetadata metadata;
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
    this.trailingActions = const <Widget>[],
  }) : unavailable = false,
       onRetry = null;

  const ChatMediaComposerStatus.unavailable({
    super.key,
    required this.onRetry,
    this.idleActions = const <Widget>[],
    this.trailingActions = const <Widget>[],
  }) : unavailable = true;

  final bool unavailable;
  final VoidCallback? onRetry;
  final List<Widget> idleActions;
  final List<Widget> trailingActions;

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
        Wrap(
          key: const Key('chat-media-composer-actions'),
          alignment: WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ...idleActions,
            SizedBox.square(
              dimension: 48,
              child: IconButton(
                key: const Key('voice-record-unavailable'),
                onPressed: null,
                tooltip: strings.voiceUnsupported,
                icon: const Icon(Icons.mic_none_rounded),
              ),
            ),
            ...trailingActions,
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
  pause: strings.pauseVoiceRecording,
  resume: strings.resumeVoiceRecording,
  level: strings.voiceRecordingLevel,
  stop: strings.stopVoiceRecording,
  play: strings.playVoicePreview,
  cancel: strings.cancelVoiceMessage,
  send: strings.sendVoiceMessage,
  sent: strings.voiceMessageQueued,
  openSettings: strings.openAppSettings,
  errorLabel: (error) => switch (error) {
    VoiceMessageError.unsupported => strings.voiceUnsupported,
    VoiceMessageError.permissionDenied => strings.voicePermissionDenied,
    VoiceMessageError.permissionPermanentlyDenied =>
      strings.voicePermissionPermanentlyDenied,
    VoiceMessageError.permissionRequestFailed =>
      strings.voicePermissionRequestFailed,
    VoiceMessageError.recordingFailed => strings.voiceRecordingFailed,
    VoiceMessageError.pauseFailed => strings.voicePauseFailed,
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
