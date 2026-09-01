part of 'chat_media_composer.dart';

extension _ChatMediaComposerAttachments on _ChatMediaComposerState {
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
      await resumed.future.timeout(
        _ChatMediaComposerState._admissionResumeTimeout,
      );
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
        presentation: pickerSource == AttachmentPickerSource.file
            ? AttachmentUploadPresentation.file
            : AttachmentUploadPresentation.image,
        diagnosticSource: switch (pickerSource) {
          AttachmentPickerSource.gallery => AttachmentUploadSource.gallery,
          AttachmentPickerSource.camera => AttachmentUploadSource.camera,
          AttachmentPickerSource.file => AttachmentUploadSource.file,
        },
      );
    } on ImageAttachmentPickerException catch (error) {
      throw _pickerPreparationFailure(error);
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

  Future<ImageAttachmentUploadRequest?> _prepareDroppedAttachment(
    DropItem item,
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
      source = await _desktopAttachmentPreparer.prepare(
        item,
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
        presentation: AttachmentUploadPresentation.file,
        diagnosticSource: AttachmentUploadSource.file,
      );
    } on ImageAttachmentPickerException catch (error) {
      throw _pickerPreparationFailure(error);
    } finally {
      if (identical(_imagePreparationCancellation, cancellation)) {
        _imagePreparationCancellation = null;
      }
    }
  }

  Future<bool> _submitDroppedAttachment(DropItem item) async {
    if (_disposed || !_imageSupported || _imageController.state.isActive) {
      return false;
    }
    await _imageController.pickAndStart(() => _prepareDroppedAttachment(item));
    return true;
  }

  ImageAttachmentPreparationFailure _pickerPreparationFailure(
    ImageAttachmentPickerException error,
  ) => ImageAttachmentPreparationFailure(switch (error.code) {
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
        presentation: AttachmentUploadPresentation.image,
        diagnosticSource: AttachmentUploadSource.image,
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

  Future<ImageAttachmentUploadRequest?> _prepareContact() async {
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
      source = await _contactPicker.pick(
        fallbackDisplayName: AppLocalizations.of(context).contactAttachment,
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
        presentation: AttachmentUploadPresentation.contact,
        diagnosticSource: AttachmentUploadSource.contact,
      );
    } on ContactPickerException catch (error) {
      throw ImageAttachmentPreparationFailure(switch (error.failure) {
        ContactPickerFailure.permissionDenied => 'contact-permission-denied',
        ContactPickerFailure.unavailable => 'contact-picker-unavailable',
        ContactPickerFailure.invalidSelection => 'contact-invalid-selection',
      });
    } finally {
      if (identical(_imagePreparationCancellation, cancellation)) {
        _imagePreparationCancellation = null;
      }
    }
  }

  Future<bool> _pickContact() async {
    if (_disposed || !_imageSupported || _imageController.state.isActive) {
      return false;
    }
    await _imageController.pickAndStart(_prepareContact);
    return true;
  }
}
