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

  @override
  void dispose() {
    unawaited(_completion?.cancel());
    unawaited(_positionUpdates?.cancel());
    unawaited(_durationUpdates?.cancel());
    unawaited(_backend?.dispose());
    super.dispose();
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
    return Container(
      key: Key('chat-voice-${widget.messageId}'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
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
      ),
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
    final voiceUri = mimeType?.startsWith('audio/') == true
        ? _davDownloadUri(account, parameter)
        : null;
    final previewUri = _previewUri(account, parameter, mimeType);
    final link = _safeSameOriginLink(account, parameter.link);
    final previewProvider = previewUri == null
        ? null
        : chatMediaProvider((account: account, uri: previewUri));
    final image = previewProvider == null ? null : ref.watch(previewProvider);
    final loadedImage = image?.asData?.value;
    final imageFailed =
        image != null && !image.isLoading && loadedImage == null;
    final fullScreenPreviewUri = previewUri == null
        ? null
        : _fullScreenPreviewUri(previewUri);
    final VoidCallback? openImage = fullScreenPreviewUri == null
        ? null
        : () => unawaited(
            showAuthenticatedImageViewer(
              context,
              account: account,
              previewUri: fullScreenPreviewUri,
              imageName: name,
              repository: ref.read(chatMediaRepositoryProvider),
            ),
          );
    final VoidCallback? openExternal = link == null
        ? null
        : () =>
              unawaited(launchUrl(link, mode: LaunchMode.externalApplication));
    final openAttachment = openImage ?? openExternal;
    final opensExternally = openImage == null && openExternal != null;
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
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
        ] else if (image?.isLoading ?? false) ...[
          Container(
            key: Key('chat-image-loading-$messageId-$index'),
            width: 240,
            height: 120,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 6),
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
          const SizedBox(height: 6),
        ],
        // The message text already names the file through its rich object, so
        // this action stays a compact button instead of repeating the name.
        Semantics(
          button: true,
          label: '${strings.openAttachment}: $name',
          child: ExcludeSemantics(
            child: Material(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                key: Key('chat-open-attachment-$messageId-$index'),
                onTap: openAttachment,
                borderRadius: BorderRadius.circular(10),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          mimeType?.startsWith('image/') == true
                              ? Icons.image_rounded
                              : Icons.insert_drive_file_rounded,
                          color: scheme.primary,
                        ),
                        if (opensExternally) ...[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.open_in_new_rounded,
                            size: 18,
                            color: scheme.primary,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Files web page and would answer with HTML, so it must not be downloaded.
Uri? _davDownloadUri(StoredAccount account, ChatRichObjectParameter parameter) {
  final raw = parameter.wire['path'];
  if (raw is! String) {
    return null;
  }
  final segments = raw
      .split('/')
      .where((segment) => segment.isNotEmpty && segment != '.')
      .toList(growable: false);
  if (segments.isEmpty || segments.contains('..')) {
    return null;
  }
  final server = ServerBase.parse(account.serverUrl);
  return server.uri.replace(
    pathSegments: [
      ...server.uri.pathSegments,
      'remote.php',
      'dav',
      'files',
      account.loginName,
      ...segments,
    ],
  );
}

String? _mimeType(ChatRichObjectParameter parameter) {
  final value = parameter.wire['mimetype'] ?? parameter.wire['mimeType'];
  return value is String ? value.trim().toLowerCase() : null;
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
  return server.uri.replace(
    pathSegments: [...server.uri.pathSegments, 'index.php', 'core', 'preview'],
    queryParameters: {'fileId': '$fileId', 'x': '1024', 'y': '1024', 'a': '0'},
  );
}

Uri? _safeSameOriginLink(StoredAccount account, String? raw) {
  if (raw == null || raw.isEmpty || raw.contains(r'\')) {
    return null;
  }
  final parsed = Uri.tryParse(raw);
  if (parsed == null || parsed.userInfo.isNotEmpty) {
    return null;
  }
  final server = ServerBase.parse(account.serverUrl);
  final resolved = parsed.hasScheme ? parsed : server.uri.resolveUri(parsed);
  return resolved.scheme == 'https' && server.hasSameOrigin(resolved)
      ? resolved
      : null;
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
