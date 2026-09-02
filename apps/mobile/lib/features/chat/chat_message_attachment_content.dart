part of 'chat_message_content.dart';

final class _VoiceAttachment extends ConsumerStatefulWidget {
  const _VoiceAttachment({
    required this.account,
    required this.uri,
    required this.messageId,
    required this.name,
  });

  final StoredAccount account;
  final Uri uri;
  final int messageId;
  final String name;

  @override
  ConsumerState<_VoiceAttachment> createState() => _VoiceAttachmentState();
}

final class _VoiceAttachmentState extends ConsumerState<_VoiceAttachment> {
  VoicePlaybackBackend? _backend;
  StreamSubscription<void>? _completion;
  StreamSubscription<Duration>? _positionUpdates;
  StreamSubscription<Duration>? _durationUpdates;
  bool _playing = false;
  bool _loading = false;
  bool _failed = false;
  Duration _position = Duration.zero;
  Duration? _total;

  /// Set while the listener drags the slider, so incoming position ticks do
  /// not fight the thumb under their finger.
  Duration? _scrubbing;

  VoiceTranscriber? _transcriber;
  bool _transcribing = false;
  String? _transcript;
  String? _transcriptionError;
  bool _transcriptCopied = false;

  /// Bumped by every cancel, account switch and dispose. A transcription that
  /// resolves against an older generation belongs to a request the listener
  /// already walked away from, so its text never reaches the bubble.
  int _transcriptionGeneration = 0;

  @override
  void didUpdateWidget(_VoiceAttachment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.id != widget.account.id ||
        oldWidget.messageId != widget.messageId) {
      _discardTranscription();
    }
  }

  @override
  void dispose() {
    unawaited(_completion?.cancel());
    unawaited(_positionUpdates?.cancel());
    unawaited(_durationUpdates?.cancel());
    unawaited(_backend?.dispose());
    _transcriptionGeneration++;
    unawaited(_transcriber?.dispose());
    super.dispose();
  }

  /// Drops whatever the current request would produce and tells the platform
  /// recogniser to stop. Shared by the cancel button and the account switch.
  void _discardTranscription() {
    _transcriptionGeneration++;
    final transcriber = _transcriber;
    if (transcriber != null) {
      unawaited(transcriber.cancel());
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _transcribing = false;
      _transcript = null;
      _transcriptionError = null;
      _transcriptCopied = false;
    });
  }

  Future<void> _transcribe(ChatVoiceTranscriberFactory factory) async {
    final generation = ++_transcriptionGeneration;
    final locale = Localizations.localeOf(context).toLanguageTag();
    setState(() {
      _transcribing = true;
      _transcript = null;
      _transcriptionError = null;
      _transcriptCopied = false;
    });
    final transcriber = _transcriber ??= factory();
    try {
      final file = await ref.read(
        chatVoiceFileProvider((
          account: widget.account,
          uri: widget.uri,
          messageId: widget.messageId,
        )).future,
      );
      final text = await transcriber.transcribe(
        filePath: file.path,
        localeIdentifier: locale,
      );
      if (!mounted || generation != _transcriptionGeneration) {
        return;
      }
      setState(() {
        _transcribing = false;
        _transcript = text;
      });
    } on Object catch (error) {
      if (!mounted || generation != _transcriptionGeneration) {
        return;
      }
      if (error is VoiceTranscriptionException &&
          error.failure == VoiceTranscriptionFailure.cancelled) {
        setState(() => _transcribing = false);
        return;
      }
      setState(() {
        _transcribing = false;
        _transcriptionError = _transcriptionErrorText(error);
      });
    }
  }

  String _transcriptionErrorText(Object error) {
    final strings = AppLocalizations.of(context);
    if (error is VoiceTranscriptionException) {
      return switch (error.failure) {
        VoiceTranscriptionFailure.denied => strings.voiceTranscriptionDenied,
        VoiceTranscriptionFailure.restricted =>
          strings.voiceTranscriptionRestricted,
        VoiceTranscriptionFailure.unavailable =>
          strings.voiceTranscriptionUnavailable,
        VoiceTranscriptionFailure.invalidFile =>
          strings.voiceTranscriptionInvalidFile,
        VoiceTranscriptionFailure.failed ||
        VoiceTranscriptionFailure.cancelled ||
        VoiceTranscriptionFailure.unsupported =>
          strings.voiceTranscriptionFailed,
      };
    }
    return strings.voiceTranscriptionFailed;
  }

  Future<void> _copyTranscript(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      setState(() => _transcriptCopied = true);
    }
  }

  Future<void> _toggle() async {
    if (_loading) {
      return;
    }
    final backend = _backend;
    if (backend != null && _playing) {
      await backend.pause();
      if (mounted) {
        setState(() => _playing = false);
      }
      return;
    }
    if (backend != null && _total != null) {
      await backend.resume();
      if (mounted) {
        setState(() => _playing = true);
      }
      return;
    }
    await _start();
  }

  Future<void> _start() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final file = await ref.read(
        chatVoiceFileProvider((
          account: widget.account,
          uri: widget.uri,
          messageId: widget.messageId,
        )).future,
      );
      if (!mounted) {
        return;
      }
      final backend = _backend ??= ref.read(chatVoicePlaybackBackendProvider)();
      _completion ??= backend.completed.listen((_) {
        if (mounted) {
          setState(() {
            _playing = false;
            _position = Duration.zero;
          });
        }
      });
      _positionUpdates ??= backend.positionChanged.listen((value) {
        if (mounted && _scrubbing == null) {
          setState(() => _position = value);
        }
      });
      _durationUpdates ??= backend.durationChanged.listen((value) {
        if (mounted && value > Duration.zero) {
          setState(() => _total = value);
        }
      });
      await backend.playFile(file.path, mimeType: file.contentType);
      if (mounted) {
        setState(() {
          _loading = false;
          _playing = true;
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _loading = false;
          _playing = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _seek(Duration position) async {
    final backend = _backend;
    setState(() {
      _scrubbing = null;
      _position = position;
    });
    if (backend == null) {
      return;
    }
    try {
      await backend.seek(position);
    } on Object {
      if (mounted) {
        setState(() => _failed = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final label = _playing
        ? strings.pauseVoiceMessage
        : strings.playVoiceMessage;
    final total = _total;
    final transcriberFactory = ref.watch(chatVoiceTranscriberFactoryProvider);
    return Container(
      key: Key('chat-voice-${widget.messageId}'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _player(context, strings, scheme, label, total),
          if (transcriberFactory != null)
            _transcription(context, strings, scheme, transcriberFactory),
        ],
      ),
    );
  }

  Widget _player(
    BuildContext context,
    AppLocalizations strings,
    ColorScheme scheme,
    String label,
    Duration? total,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: Key('chat-voice-toggle-${widget.messageId}'),
          tooltip: label,
          onPressed: _loading ? null : () => unawaited(_toggle()),
          icon: _loading
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  semanticLabel: label,
                ),
        ),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _failed ? strings.voicePlaybackFailed : widget.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: _failed ? scheme.error : scheme.onSurface,
                ),
              ),
              if (total != null) _timeline(context, strings, total),
            ],
          ),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  /// On-device speech recognition, so the audio never leaves the phone. The
  /// action only exists where a recogniser is actually wired up.
  Widget _transcription(
    BuildContext context,
    AppLocalizations strings,
    ColorScheme scheme,
    ChatVoiceTranscriberFactory factory,
  ) {
    final transcript = _transcript;
    final error = _transcriptionError;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_transcribing)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                key: Key('chat-voice-transcribing-${widget.messageId}'),
                dimension: 48,
                child: const Center(
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
              Flexible(
                child: Text(
                  strings.voiceTranscriptionRunning,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              SizedBox.square(
                dimension: 48,
                child: IconButton(
                  key: Key(
                    'chat-voice-transcription-cancel-${widget.messageId}',
                  ),
                  tooltip: strings.cancelVoiceTranscription,
                  onPressed: _discardTranscription,
                  icon: Icon(
                    Icons.close_rounded,
                    semanticLabel: strings.cancelVoiceTranscription,
                  ),
                ),
              ),
            ],
          )
        else
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                key: Key('chat-voice-transcribe-${widget.messageId}'),
                dimension: 48,
                child: IconButton(
                  tooltip: strings.transcribeVoiceMessage,
                  onPressed: () => unawaited(_transcribe(factory)),
                  icon: Icon(
                    Icons.subtitles_rounded,
                    semanticLabel: strings.transcribeVoiceMessage,
                  ),
                ),
              ),
              Flexible(
                child: Text(
                  strings.transcribeVoiceMessage,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        if (transcript != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    transcript,
                    key: Key('chat-voice-transcript-${widget.messageId}'),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
              SizedBox.square(
                key: Key('chat-voice-transcript-copy-${widget.messageId}'),
                dimension: 48,
                child: IconButton(
                  tooltip: strings.copyVoiceTranscript,
                  onPressed: () => unawaited(_copyTranscript(transcript)),
                  icon: Icon(
                    Icons.copy_rounded,
                    semanticLabel: strings.copyVoiceTranscript,
                  ),
                ),
              ),
            ],
          ),
        if (_transcriptCopied)
          Text(
            strings.voiceTranscriptCopied,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              error,
              key: Key('chat-voice-transcription-error-${widget.messageId}'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
      ],
    );
  }

  Widget _timeline(
    BuildContext context,
    AppLocalizations strings,
    Duration total,
  ) {
    final shown = _scrubbing ?? _position;
    final clamped = shown < Duration.zero
        ? Duration.zero
        : (shown > total ? total : shown);
    final progress = strings.voiceMessageProgress(
      _formatPlaybackTime(clamped),
      _formatPlaybackTime(total),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Slider(
            key: Key('chat-voice-position-${widget.messageId}'),
            value: clamped.inMilliseconds.toDouble(),
            max: total.inMilliseconds.toDouble(),
            label: _formatPlaybackTime(clamped),
            semanticFormatterCallback: (_) => progress,
            onChanged: (value) => setState(
              () => _scrubbing = Duration(milliseconds: value.round()),
            ),
            onChangeEnd: (value) =>
                unawaited(_seek(Duration(milliseconds: value.round()))),
          ),
        ),
        Text(
          progress,
          key: Key('chat-voice-progress-${widget.messageId}'),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// `m:ss` for anything under an hour, `h:mm:ss` beyond it. Voice messages are
/// short, so the hour part is only there to keep a stray long file readable.
String _formatPlaybackTime(Duration value) {
  final total = value.isNegative ? Duration.zero : value;
  final seconds = (total.inSeconds % 60).toString().padLeft(2, '0');
  final minutes = total.inMinutes % 60;
  if (total.inHours == 0) {
    return '$minutes:$seconds';
  }
  return '${total.inHours}:${minutes.toString().padLeft(2, '0')}:$seconds';
}

final class _ChatAttachment extends ConsumerWidget {
  const _ChatAttachment({
    super.key,
    required this.account,
    required this.parameter,
    required this.messageId,
    required this.index,
  });

  final StoredAccount account;
  final ChatRichObjectParameter parameter;
  final int messageId;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final name = (parameter.name ?? '').trim().isEmpty
        ? strings.attachment
        : parameter.name!.trim();
    final mimeType = _mimeType(parameter);
    final attachment = _davAttachment(account, parameter);
    final contact = _isContactAttachment(
      attachment?.vCardPath ?? false,
      mimeType,
    );
    final originalUri = attachment?.uri;
    final voiceUri = mimeType?.startsWith('audio/') == true
        ? originalUri
        : null;
    final previewUri = _previewUri(account, parameter, mimeType);
    final previewProvider = previewUri == null
        ? null
        : chatMediaProvider(
            ChatMediaProviderKey(account: account, uri: previewUri),
          );
    final image = previewProvider == null ? null : ref.watch(previewProvider);
    final loadedImage = image?.asData?.value;
    final imageFailed =
        image != null && !image.isLoading && loadedImage == null;
    final fullScreenPreviewUri = previewUri == null
        ? null
        : _fullScreenPreviewUri(previewUri);
    final VoidCallback? openImage =
        fullScreenPreviewUri == null || originalUri == null || mimeType == null
        ? null
        : () => unawaited(
            showAuthenticatedImageViewer(
              context,
              account: account,
              previewUri: fullScreenPreviewUri,
              originalUri: originalUri,
              originalContentType: mimeType,
              imageName: name,
              repository: ref.read(chatMediaRepositoryProvider),
              openAppSettings: () => ref.read(appSettingsOpenerProvider).open(),
            ),
          );
    final VoidCallback? openFile =
        originalUri == null || mimeType == null || voiceUri != null
        ? null
        : () => unawaited(
            _openDownloadedAttachment(
              context,
              ref,
              account: account,
              uri: originalUri,
              fileName: name,
              contentType: mimeType,
            ),
          );
    final openAttachment = openImage ?? openFile;
    Widget loadingImage() => Container(
      key: Key('chat-image-loading-$messageId-$index'),
      width: 240,
      height: 120,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const CircularProgressIndicator(strokeWidth: 2),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (voiceUri != null)
          _VoiceAttachment(
            account: account,
            uri: voiceUri,
            messageId: messageId,
            name: name,
          ),
        if (loadedImage != null) ...[
          Semantics(
            key: Key('chat-open-image-$messageId-$index'),
            image: true,
            button: true,
            label: '${strings.openImage}: $name',
            onTap: openImage,
            child: ExcludeSemantics(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: openImage,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                        maxWidth: 420,
                        maxHeight: 320,
                      ),
                      child: Image.memory(
                        loadedImage.body,
                        key: Key('chat-image-$messageId-$index'),
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        frameBuilder:
                            (_, image, frame, wasSynchronouslyLoaded) =>
                                _showAfterFirstImageFrame(
                                  image: image,
                                  frame: frame,
                                  wasSynchronouslyLoaded:
                                      wasSynchronouslyLoaded,
                                  placeholder: loadingImage(),
                                ),
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ] else if (image?.isLoading ?? false) ...[
          loadingImage(),
        ] else if (imageFailed) ...[
          Container(
            key: Key('chat-image-error-$messageId-$index'),
            width: 240,
            constraints: const BoxConstraints(minHeight: 72),
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.broken_image_outlined, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    strings.imageLoadFailed,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  key: Key('chat-image-retry-$messageId-$index'),
                  onPressed: previewProvider == null
                      ? null
                      : () => ref.invalidate(previewProvider),
                  tooltip: strings.retry,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
        ],
        if (previewProvider == null &&
            voiceUri == null &&
            openAttachment != null)
          Material(
            color: scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        contact
                            ? Icons.contact_page_outlined
                            : mimeType?.startsWith('image/') == true
                            ? Icons.image_rounded
                            : Icons.insert_drive_file_rounded,
                        color: scheme.primary,
                      ),
                      if (contact) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            strings.contactAttachment,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: scheme.primary),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _attachmentAction(
                        key: Key(
                          'chat-attachment-open-action-$messageId-$index',
                        ),
                        semanticsKey: Key(
                          contact
                              ? 'chat-open-contact-$messageId-$index'
                              : 'chat-open-attachment-$messageId-$index',
                        ),
                        icon: Icons.open_in_new_rounded,
                        label: strings.openAttachment,
                        semanticsLabel: contact
                            ? strings.openContact(name)
                            : '${strings.openAttachment}: $name',
                        onTap: openAttachment,
                      ),
                      _attachmentAction(
                        key: Key(
                          'chat-attachment-save-action-$messageId-$index',
                        ),
                        icon: Icons.save_alt_rounded,
                        label: strings.saveAttachment,
                        semanticsLabel: '${strings.saveAttachment}: $name',
                        onTap: () => unawaited(
                          _exportDownloadedAttachment(
                            context,
                            ref,
                            action: _ChatAttachmentMenuAction.save,
                            account: account,
                            uri: originalUri!,
                            fileName: name,
                            contentType: mimeType!,
                          ),
                        ),
                      ),
                      _attachmentAction(
                        key: Key(
                          'chat-attachment-share-action-$messageId-$index',
                        ),
                        icon: Icons.share_rounded,
                        label: strings.shareAttachment,
                        semanticsLabel: '${strings.shareAttachment}: $name',
                        onTap: () => unawaited(
                          _exportDownloadedAttachment(
                            context,
                            ref,
                            action: _ChatAttachmentMenuAction.share,
                            account: account,
                            uri: originalUri!,
                            fileName: name,
                            contentType: mimeType!,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

enum _ChatAttachmentMenuAction { save, share }

Widget _attachmentAction({
  required Key key,
  Key? semanticsKey,
  required IconData icon,
  required String label,
  required String semanticsLabel,
  required VoidCallback onTap,
}) {
  return SizedBox.square(
    key: key,
    dimension: 48,
    child: Tooltip(
      message: label,
      child: Semantics(
        key: semanticsKey,
        button: true,
        label: semanticsLabel,
        onTap: onTap,
        child: ExcludeSemantics(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Center(child: Icon(icon, size: 20)),
          ),
        ),
      ),
    ),
  );
}

/// Files web page and would answer with HTML, so it must not be downloaded.
final class _DavAttachment {
  const _DavAttachment({required this.uri, required this.vCardPath});

  final Uri uri;
  final bool vCardPath;
}

_DavAttachment? _davAttachment(
  StoredAccount account,
  ChatRichObjectParameter parameter,
) {
  final raw = parameter.wire['path'];
  if (raw is! String) {
    return null;
  }
  final DavRelativePath path;
  final DavUserId user;
  try {
    path = DavRelativePath.parse(raw);
    user = DavUserId.parse(account.loginName);
  } on TalkProtocolException {
    return null;
  }
  final server = ServerBase.parse(account.serverUrl);
  return _DavAttachment(
    uri: server.uri.replace(
      pathSegments: [
        ...server.uri.pathSegments.where((segment) => segment.isNotEmpty),
        'remote.php',
        'dav',
        'files',
        user.value,
        ...path.segments,
      ],
    ),
    vCardPath: path.segments.last.toLowerCase().endsWith('.vcf'),
  );
}

String? _mimeType(ChatRichObjectParameter parameter) {
  final value = parameter.wire['mimetype'] ?? parameter.wire['mimeType'];
  return value is String ? value.trim().toLowerCase() : null;
}

bool _isContactAttachment(bool vCardPath, String? mimeType) {
  if (const <String>{
    'text/vcard',
    'text/x-vcard',
    'text/directory',
  }.contains(mimeType)) {
    return true;
  }
  if (!vCardPath) {
    return false;
  }
  return const <String>{
    'application/octet-stream',
    'binary/octet-stream',
  }.contains(mimeType);
}

Uri? _previewUri(
  StoredAccount account,
  ChatRichObjectParameter parameter,
  String? mimeType,
) {
  if (mimeType?.startsWith('image/') != true) {
    return null;
  }
  final available = parameter.wire['preview-available'];
  if (available == false || available == 0 || available == 'no') {
    return null;
  }
  final fileId = int.tryParse(parameter.id ?? '');
  if (fileId == null || fileId < 1) {
    return null;
  }
  final server = ServerBase.parse(account.serverUrl);
  // `a` is Nextcloud's "preserve the aspect ratio" flag (see
  // core/Controller/PreviewController.php). With `a=0` the server crops the
  // image to exactly x by y, so a wide photo came back as a square cut out of
  // its middle instead of the whole picture. The box below is a bound, not a
  // target shape.
  return server.uri.replace(
    pathSegments: [...server.uri.pathSegments, 'index.php', 'core', 'preview'],
    queryParameters: {'fileId': '$fileId', 'x': '1024', 'y': '1024', 'a': '1'},
  );
}

Uri _fullScreenPreviewUri(Uri previewUri) {
  return previewUri.replace(
    queryParameters: <String, String>{
      ...previewUri.queryParameters,
      'x': '2048',
      'y': '2048',
    },
  );
}

/// A download over a slow link can run for many seconds. Without an immediate
/// indicator the bubble stays silent and the listener cannot tell a slow
/// download from a button that did nothing, so the notice goes up before the
/// request starts and comes down however the request ends. The server does not
/// always declare a length, so the bar falls back to indeterminate rather than
/// inventing a percentage.
///
/// An overlay entry rather than a snack bar: the messenger queues snack bars
/// behind whatever is still animating out, and closing one that is not at the
/// head of that queue is an assertion failure.
Future<T> _withDownloadNotice<T>(
  BuildContext context,
  Future<T> Function(ChatDownloadProgress onProgress) run,
) async {
  final overlay = Overlay.of(context);
  final progress = ValueNotifier<({int received, int? total})>((
    received: 0,
    total: null,
  ));
  final notice = OverlayEntry(
    builder: (_) => _AttachmentDownloadNotice(progress: progress),
  );
  overlay.insert(notice);
  try {
    return await run((received, total) {
      progress.value = (received: received, total: total);
    });
  } finally {
    notice
      ..remove()
      ..dispose();
    progress.dispose();
  }
}

final class _AttachmentDownloadNotice extends StatelessWidget {
  const _AttachmentDownloadNotice({required this.progress});

  final ValueListenable<({int received, int? total})> progress;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Material(
              key: const Key('chat-attachment-downloading'),
              color: scheme.inverseSurface,
              elevation: 6,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: ValueListenableBuilder<({int received, int? total})>(
                  valueListenable: progress,
                  builder: (context, value, _) {
                    final total = value.total;
                    final fraction = total != null && total > 0
                        ? (value.received / total).clamp(0.0, 1.0)
                        : null;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fraction == null
                              ? strings.attachmentDownloading
                              : strings.attachmentDownloadingPercent(
                                  (fraction * 100).round(),
                                ),
                          key: const Key('chat-attachment-downloading-label'),
                          style: TextStyle(color: scheme.onInverseSurface),
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          key: const Key('chat-attachment-downloading-bar'),
                          value: fraction,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _openDownloadedAttachment(
  BuildContext context,
  WidgetRef ref, {
  required StoredAccount account,
  required Uri uri,
  required String fileName,
  required String contentType,
}) async {
  final opener = ref.read(chatAttachmentOpenActionFactoryProvider)(
    ref.read(chatMediaRepositoryProvider),
  );
  final result = await _withDownloadNotice(
    context,
    (onProgress) => opener.open(
      account: account,
      uri: uri,
      fileName: fileName,
      expectedContentType: contentType,
      onProgress: onProgress,
    ),
  );
  if (result == ChatAttachmentOpenResult.opened || !context.mounted) {
    return;
  }
  final strings = AppLocalizations.of(context);
  final message = switch (result) {
    ChatAttachmentOpenResult.opened => strings.conversationActionErrorGeneric,
    ChatAttachmentOpenResult.reauthenticationRequired =>
      strings.attachmentReauthenticationRequired,
    ChatAttachmentOpenResult.tooLarge => strings.attachmentTooLarge,
    ChatAttachmentOpenResult.invalid => strings.attachmentInvalid,
    ChatAttachmentOpenResult.downloadFailed => strings.attachmentDownloadFailed,
    ChatAttachmentOpenResult.storageFailed => strings.attachmentStorageFailed,
    ChatAttachmentOpenResult.openFailed =>
      strings.conversationActionErrorGeneric,
  };
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
  );
}

Future<void> _exportDownloadedAttachment(
  BuildContext context,
  WidgetRef ref, {
  required _ChatAttachmentMenuAction action,
  required StoredAccount account,
  required Uri uri,
  required String fileName,
  required String contentType,
}) async {
  final exporter = ref.read(chatAttachmentExportActionFactoryProvider)(
    ref.read(chatMediaRepositoryProvider),
  );
  final strings = AppLocalizations.of(context);
  final String? message;
  switch (action) {
    case _ChatAttachmentMenuAction.save:
      final result = await _withDownloadNotice(
        context,
        (onProgress) => exporter.save(
          account: account,
          uri: uri,
          fileName: fileName,
          expectedContentType: contentType,
          onProgress: onProgress,
        ),
      );
      message = switch (result) {
        ChatAttachmentSaveResult.saved => strings.attachmentSaved,
        ChatAttachmentSaveResult.cancelled => strings.attachmentSaveCancelled,
        ChatAttachmentSaveResult.reauthenticationRequired =>
          strings.attachmentReauthenticationRequired,
        ChatAttachmentSaveResult.tooLarge => strings.attachmentTooLarge,
        ChatAttachmentSaveResult.invalid => strings.attachmentInvalid,
        ChatAttachmentSaveResult.downloadFailed =>
          strings.attachmentDownloadFailed,
        ChatAttachmentSaveResult.permissionDenied =>
          strings.attachmentPermissionDenied,
        ChatAttachmentSaveResult.storageFailed =>
          strings.attachmentStorageFailed,
      };
    case _ChatAttachmentMenuAction.share:
      final result = await _withDownloadNotice(
        context,
        (onProgress) => exporter.share(
          account: account,
          uri: uri,
          fileName: fileName,
          expectedContentType: contentType,
          onProgress: onProgress,
        ),
      );
      message = switch (result) {
        ChatAttachmentShareResult.shared ||
        ChatAttachmentShareResult.offered ||
        ChatAttachmentShareResult.cancelled => null,
        ChatAttachmentShareResult.reauthenticationRequired =>
          strings.attachmentReauthenticationRequired,
        ChatAttachmentShareResult.tooLarge => strings.attachmentTooLarge,
        ChatAttachmentShareResult.invalid => strings.attachmentInvalid,
        ChatAttachmentShareResult.downloadFailed =>
          strings.attachmentDownloadFailed,
        ChatAttachmentShareResult.permissionDenied =>
          strings.attachmentPermissionDenied,
        ChatAttachmentShareResult.shareFailed => strings.attachmentShareFailed,
      };
  }
  if (!context.mounted || message == null) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
  );
}
