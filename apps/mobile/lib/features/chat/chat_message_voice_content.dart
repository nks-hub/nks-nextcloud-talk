part of 'chat_message_content.dart';

final class _VoiceAttachment extends ConsumerStatefulWidget {
  const _VoiceAttachment({
    super.key,
    required this.account,
    required this.uri,
    required this.roomToken,
    required this.messageId,
    required this.index,
    required this.name,
  });

  final StoredAccount account;
  final Uri uri;
  final String roomToken;
  final int messageId;
  final int index;
  final String name;

  @override
  ConsumerState<_VoiceAttachment> createState() => _VoiceAttachmentState();
}

final class _VoiceAttachmentState extends ConsumerState<_VoiceAttachment> {
  VoicePlaybackBackend? _backend;

  /// Set once a failed download turned out to be a cached path the server
  /// does not know; see [_repairedAttachmentUri].
  Uri? _repairedUri;
  bool _pathRepairAttempted = false;
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

  Uri get _uri => _repairedUri ?? widget.uri;

  @override
  void didUpdateWidget(_VoiceAttachment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.id != widget.account.id ||
        oldWidget.messageId != widget.messageId) {
      _discardTranscription();
    }
    if (oldWidget.uri != widget.uri) {
      _repairedUri = null;
      _pathRepairAttempted = false;
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
          uri: _uri,
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
          uri: _uri,
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
    } on Object catch (error, stack) {
      // The bubble can only say "it did not play". Which of the download, the
      // credentials or the player refused it is in the log — a silent catch
      // here already cost a day once, on a device where it was the only clue.
      debugPrint('[voice] playback failed for $_uri: $error');
      debugPrintStack(stackTrace: stack, maxFrames: 8);
      if (!_pathRepairAttempted) {
        _pathRepairAttempted = true;
        // The failure is shown FIRST. The repair is two requests long on a
        // slow link, and holding the loading state through it left the play
        // button dead with no explanation.
        if (mounted) {
          setState(() {
            _loading = false;
            _playing = false;
            _failed = true;
          });
        }
        final repaired = await _repairedAttachmentUri(
          ref,
          account: widget.account,
          roomToken: widget.roomToken,
          messageId: widget.messageId,
          index: widget.index,
          failedUri: _uri,
        );
        if (repaired != null && mounted) {
          _repairedUri = repaired;
          await _start();
          return;
        }
        return;
      }
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
                // `voicePlaybackFailed` says "recording preview", which is
                // the composer's wording for the clip being reviewed before
                // it is sent. A message in the timeline is not a preview.
                _failed ? strings.voiceMessagePlaybackFailed : widget.name,
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
