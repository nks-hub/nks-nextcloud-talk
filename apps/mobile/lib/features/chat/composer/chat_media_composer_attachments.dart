part of 'chat_media_composer.dart';

extension _ChatMediaComposerAttachments on _ChatMediaComposerState {
  Future<ImageAttachmentUploadSession> _startImageUpload(
    _ComposerAttachment image,
    ImageAttachmentUploadRequest request,
  ) async {
    try {
      await _waitForResumedLifecycle();
    } on TimeoutException {
      throw const AttachmentAdmissionException(
        AttachmentAdmissionError.lifecycleTimeout,
      );
    }
    if (_disposed || image.disposed) {
      throw const AttachmentAdmissionException(
        AttachmentAdmissionError.composerGone,
      );
    }
    final bridge = image.bridge ?? widget.submissionBridge;
    final admissionSourceStore = image.store;
    final acceptedReplyTo = request.metadata.replyTo;
    final acceptanceCallback = widget.onReplyDurablyAccepted;
    image.bridge = bridge;
    image.admissionPending = true;
    var durablyAccepted = false;
    try {
      final session = await bridge.startImageUpload(request);
      durablyAccepted = true;
      if (request.metadata.caption != null) {
        widget.onCaptionConsumed?.call();
      }
      if (_sameSource(image.source, request.source)) {
        image.source = null;
      }
      _notifyReplyDurablyAccepted(
        acceptedReplyTo,
        callback: acceptanceCallback,
      );
      return session;
    } finally {
      image.admissionPending = false;
      final discardAfterAdmission = image.discardAfterAdmission;
      image.discardAfterAdmission = false;
      if (!durablyAccepted && discardAfterAdmission) {
        if (_sameSource(image.source, request.source)) {
          image.source = null;
        }
        unawaited(admissionSourceStore.discard(request.source.handle));
      }
    }
  }

  /// iOS hands the picked file over while the app is still `inactive` and
  /// the network side must wait for the real `resumed`. A desktop window is
  /// `inactive` whenever it is not key — after a drop from Finder or Explorer
  /// it usually never becomes key again — so there the state means nothing
  /// for admission.
  Future<void> _waitForResumedLifecycle() async {
    final binding = WidgetsBinding.instance;
    final state = binding.lifecycleState;
    if (state == null ||
        state == AppLifecycleState.resumed ||
        _desktopLifecycle) {
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

  static bool get _desktopLifecycle => switch (defaultTargetPlatform) {
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => true,
    _ => false,
  };

  Future<ImageAttachmentUploadRequest?> _prepareImage(
    AttachmentPickerSource pickerSource,
  ) async {
    final image = _image;
    final admission = _captureAdmission(AttachmentMessageKind.file);
    if (admission == null) {
      throw const AttachmentSubmissionException(
        AttachmentSubmissionFailure.unsupported,
      );
    }
    final cancellation = AttachmentCancellationController();
    image.cancellation = cancellation;
    PreparedAttachmentSource? source;
    try {
      source = await _imagePicker.pick(
        source: pickerSource,
        cancellationSignal: cancellation.signal,
      );
      if (source == null) {
        return null;
      }
      if (_disposed || image.disposed || cancellation.isCancelled) {
        await image.store.discard(source.handle);
        return null;
      }
      image.source = source;
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
      if (identical(image.cancellation, cancellation)) {
        image.cancellation = null;
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

  Future<bool> _attachImageBytes(
    Uint8List bytes,
    String mimeType,
    String displayName,
  ) async {
    if (bytes.isEmpty) {
      return false;
    }
    return _submitDroppedAttachment(
      DropItemFile.fromData(
        bytes,
        name: displayName,
        path: displayName,
        mimeType: mimeType,
      ),
    );
  }

  Future<bool> _pickAttachment(AttachmentPickerSource source) async {
    if (_disposed || !_imageSupported || _imageController.state.isActive) {
      return false;
    }
    await _imageController.pickAndHold(() => _prepareImage(source));
    return true;
  }

  Future<ImageAttachmentUploadRequest?> _prepareDroppedAttachment(
    DropItem item,
    _ComposerAttachment image,
  ) async {
    final admission = _captureAdmission(AttachmentMessageKind.file);
    if (admission == null) {
      throw const AttachmentSubmissionException(
        AttachmentSubmissionFailure.unsupported,
      );
    }
    final cancellation = AttachmentCancellationController();
    image.cancellation = cancellation;
    PreparedAttachmentSource? source;
    try {
      source = await _desktopAttachmentPreparer.prepare(
        item,
        cancellationSignal: cancellation.signal,
      );
      if (_disposed || image.disposed || cancellation.isCancelled) {
        await image.store.discard(source.handle);
        return null;
      }
      image.source = source;
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
      if (identical(image.cancellation, cancellation)) {
        image.cancellation = null;
      }
    }
  }

  Future<bool> _submitDroppedAttachment(DropItem item) async {
    if (_disposed || !_imageSupported) {
      return false;
    }
    final image = _addImageAttachment();
    image.preparing = true;
    try {
      await image.controller.pickAndHold(
        () => _prepareDroppedAttachment(item, image),
      );
      return !image.disposed;
    } finally {
      image.preparing = false;
    }
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
    final image = _image;
    final admission = _captureAdmission(AttachmentMessageKind.file);
    if (admission == null) {
      throw const AttachmentSubmissionException(
        AttachmentSubmissionFailure.unsupported,
      );
    }
    final cancellation = AttachmentCancellationController();
    image.cancellation = cancellation;
    PreparedAttachmentSource? source;
    try {
      final payload = await loader(cancellation.signal);
      if (payload.mimeType != 'image/gif' ||
          !payload.displayName.toLowerCase().endsWith('.gif')) {
        throw const AttachmentSubmissionException(
          AttachmentSubmissionFailure.unsupported,
        );
      }
      if (_disposed || image.disposed || cancellation.isCancelled) {
        return null;
      }
      source = await widget.sourceStore.copyFromStream(
        stream: Stream<List<int>>.value(payload.body),
        mimeType: payload.mimeType,
        displayName: payload.displayName,
        expectedByteLength: payload.body.lengthInBytes,
        cancellationSignal: cancellation.signal,
      );
      if (_disposed || image.disposed || cancellation.isCancelled) {
        await image.store.discard(source.handle);
        return null;
      }
      image.source = source;
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
      if (identical(image.cancellation, cancellation)) {
        image.cancellation = null;
      }
    }
  }

  Future<ImageAttachmentUploadRequest?> _prepareContact() async {
    final image = _image;
    final admission = _captureAdmission(AttachmentMessageKind.file);
    if (admission == null) {
      throw const AttachmentSubmissionException(
        AttachmentSubmissionFailure.unsupported,
      );
    }
    final cancellation = AttachmentCancellationController();
    image.cancellation = cancellation;
    PreparedAttachmentSource? source;
    try {
      source = await _contactPicker.pick(
        fallbackDisplayName: AppLocalizations.of(context).contactAttachment,
        cancellationSignal: cancellation.signal,
      );
      if (source == null) {
        return null;
      }
      if (_disposed || image.disposed || cancellation.isCancelled) {
        await image.store.discard(source.handle);
        return null;
      }
      image.source = source;
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
      if (identical(image.cancellation, cancellation)) {
        image.cancellation = null;
      }
    }
  }

  Future<bool> _pickContact() async {
    if (_disposed || !_imageSupported || _imageController.state.isActive) {
      return false;
    }
    await _imageController.pickAndHold(_prepareContact);
    return true;
  }
}
