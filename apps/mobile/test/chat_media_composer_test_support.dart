part of 'chat_media_composer_test.dart';

Widget _composerApp({
  Key composerKey = const Key('media-composer-under-test'),
  required DurableAttachmentSourceStore sourceStore,
  required AttachmentSubmissionBridge bridge,
  required int? threadId,
  AttachmentCapabilityProfile? profile,
  _VoiceBackendFactory? voiceBackends,
  ImageSelectionBackend imageSelectionBackend = const _ImageBackend(),
  List<Widget> idleActions = const <Widget>[],
  ChatMediaComposerController? controller,
  bool showAttachmentButton = true,
  ChatMediaReplyTarget? replyTarget,
  ValueChanged<int>? onReplyDurablyAccepted,
  bool silent = false,
  String Function()? captionSource,
  VoidCallback? onCaptionConsumed,
  Future<bool> Function()? openAppSettings,
  Locale locale = const Locale('en'),
}) {
  return localizedTestApp(
    locale: locale,
    home: Scaffold(
      body: ChatMediaComposer(
        key: composerKey,
        accountId: _account,
        server: _server,
        roomToken: _room,
        threadId: threadId,
        replyTarget: replyTarget,
        onReplyDurablyAccepted: onReplyDurablyAccepted,
        sourceStore: sourceStore,
        capabilityProfile: profile ?? _profile(),
        submissionBridge: bridge,
        silent: silent,
        captionSource: captionSource,
        onCaptionConsumed: onCaptionConsumed,
        openAppSettings: openAppSettings,
        controller: controller,
        showAttachmentButton: showAttachmentButton,
        idleActions: idleActions,
        imageSelectionBackend: imageSelectionBackend,
        createVoiceCaptureBackend: voiceBackends?.createCapture,
        createVoicePlaybackBackend: voiceBackends?.createPlayback,
      ),
    ),
  );
}

ChatMediaReplyTarget _replyTarget({
  AccountId? accountId,
  ConversationToken? roomToken,
  int messageId = 51,
  int? messageThreadId,
  bool deleted = false,
  bool systemMessage = false,
}) => ChatMediaReplyTarget(
  accountId: accountId ?? _account,
  roomToken: roomToken ?? _room,
  messageId: messageId,
  messageThreadId: messageThreadId,
  deleted: deleted,
  systemMessage: systemMessage,
);

Future<void> _prepareVoicePreview(
  WidgetTester tester,
  _VoiceBackendFactory backends,
) async {
  await tester.tap(find.byKey(const Key('voice-record')));
  await _pumpUntil(
    tester,
    () => find.byKey(const Key('voice-stop')).evaluate().isNotEmpty,
  );
  expect(backends.captureBackends.single.starts, 1);

  await tester.tap(find.byKey(const Key('voice-stop')));
  await _pumpUntil(
    tester,
    () => find.byKey(const Key('voice-send')).evaluate().isNotEmpty,
  );
}

String? _waveformValue(WidgetTester tester) => tester
    .widget<Semantics>(
      find.descendant(
        of: find.byKey(const Key('voice-waveform')),
        matching: find.byType(Semantics),
      ),
    )
    .properties
    .value;

/// Opens the attachment source sheet and chooses one of its entries, which is
/// the only way the picker is reachable from the composer toolbar.
Future<void> _pickAttachmentSource(
  WidgetTester tester, {
  AttachmentPickerSource source = AttachmentPickerSource.gallery,
}) async {
  await tester.tap(find.byKey(const Key('pick-image-attachment')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('attach-source-${source.name}')));
  await tester.pump();
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump();
    if (condition()) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  fail('Timed out while waiting for the media composer state.');
}

final class _RecordingBridge {
  _RecordingBridge({AttachmentCapabilityProfile? profile})
    : profile = profile ?? _profile() {
    bridge = AttachmentSubmissionBridge(
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
            sources.add(source);
            this.metadata.add(metadata);
            return _enqueueRequest(
              source: source,
              metadata: metadata,
              profile: this.profile,
            );
          },
      enqueue: (_) async {
        final session = _DurableSession();
        sessions.add(session);
        return session;
      },
    );
  }

  final AttachmentCapabilityProfile profile;
  final List<PreparedAttachmentSource> sources = <PreparedAttachmentSource>[];
  final List<AttachmentMetadata> metadata = <AttachmentMetadata>[];
  final List<_DurableSession> sessions = <_DurableSession>[];
  late final AttachmentSubmissionBridge bridge;

  Future<void> close() async {
    for (final session in sessions) {
      await session.close();
    }
  }
}

final class _DurableSession implements AttachmentSubmissionDurableSession {
  final StreamController<AttachmentJobProgress> _events =
      StreamController<AttachmentJobProgress>.broadcast(sync: true);

  @override
  AccountId get accountId => _account;

  @override
  AttachmentJobId get jobId => _jobId;

  @override
  Stream<AttachmentJobProgress> get events => _events.stream;

  int cancelCount = 0;
  int retryCount = 0;

  void add(AttachmentJobProgress progress) => _events.add(progress);

  @override
  Future<void> cancel() async => cancelCount++;

  @override
  Future<void> retry() async => retryCount++;

  Future<void> close() => _events.close();
}

final class _ImageBackend implements ImageSelectionBackend {
  const _ImageBackend();

  @override
  Future<ImageSelection?> selectImage(AttachmentPickerSource source) async {
    final bytes = <int>[
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
      1,
      2,
      3,
    ];
    return ImageSelection(
      displayName: 'photo.png',
      declaredMimeType: 'image/png',
      byteLength: bytes.length,
      openRead: ({int? start, int? end}) {
        final first = start ?? 0;
        final last = end == null || end > bytes.length ? bytes.length : end;
        return Stream<List<int>>.value(bytes.sublist(first, last));
      },
    );
  }
}

final class _DocumentBackend implements ImageSelectionBackend {
  const _DocumentBackend();

  @override
  Future<ImageSelection?> selectImage(AttachmentPickerSource source) async {
    final bytes = <int>[0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x34, 0x0a];
    return ImageSelection(
      displayName: 'report.pdf',
      declaredMimeType: null,
      byteLength: bytes.length,
      openRead: ({int? start, int? end}) {
        final first = start ?? 0;
        final last = end == null || end > bytes.length ? bytes.length : end;
        return Stream<List<int>>.value(bytes.sublist(first, last));
      },
    );
  }
}

final class _RefusingCameraBackend implements ImageSelectionBackend {
  const _RefusingCameraBackend();

  @override
  Future<ImageSelection?> selectImage(AttachmentPickerSource source) async {
    throw const ImageAttachmentPickerException(
      ImageAttachmentPickerError.cameraPermissionDenied,
    );
  }
}

final class _PendingImageBackend implements ImageSelectionBackend {
  final Completer<ImageSelection?> _selection = Completer<ImageSelection?>();
  bool selectionRequested = false;

  @override
  Future<ImageSelection?> selectImage(AttachmentPickerSource source) {
    selectionRequested = true;
    return _selection.future;
  }

  Future<void> complete() async {
    _selection.complete(
      await const _ImageBackend().selectImage(AttachmentPickerSource.gallery),
    );
  }
}

final class _VoiceBackendFactory {
  _VoiceBackendFactory({this.failStart = false});

  final bool failStart;
  final List<_CaptureBackend> captureBackends = <_CaptureBackend>[];
  final List<_PlaybackBackend> playbackBackends = <_PlaybackBackend>[];

  VoiceCaptureBackend createCapture() {
    final backend = _CaptureBackend(failStart: failStart);
    captureBackends.add(backend);
    return backend;
  }

  VoicePlaybackBackend createPlayback() {
    final backend = _PlaybackBackend();
    playbackBackends.add(backend);
    return backend;
  }

  Future<void> close() async {
    for (final backend in playbackBackends) {
      await backend.closeIfNeeded();
    }
  }
}

final class _CaptureBackend implements VoiceCaptureBackend {
  _CaptureBackend({this.failStart = false});

  final bool failStart;
  final StreamController<double> _amplitude =
      StreamController<double>.broadcast();
  String? _path;
  int starts = 0;
  int pauses = 0;
  int resumes = 0;
  int disposes = 0;

  @override
  Future<void> pause() async => pauses++;

  @override
  Future<void> resume() async => resumes++;

  @override
  Stream<double> get amplitude => _amplitude.stream;

  void emitAmplitude(double value) => _amplitude.add(value);

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<bool> supportsEncoding() async => true;

  @override
  Future<void> start({
    required String path,
    required int sampleRate,
    required int channels,
    required int bitRate,
  }) async {
    if (failStart) {
      throw StateError('Synthetic recording start failure.');
    }
    _path = path;
    starts++;
    await File(path).writeAsBytes(_oneSecondWav(), flush: true);
  }

  @override
  Future<void> retirePendingStart({required Future<void> pendingStart}) async {
    await pendingStart;
    await cancel();
  }

  @override
  Future<String?> stop() async => _path;

  @override
  Future<void> cancel() async {
    final path = _path;
    if (path != null && await File(path).exists()) {
      await File(path).delete();
    }
  }

  @override
  Future<void> dispose() async {
    disposes++;
    await _amplitude.close();
  }
}

final class _PlaybackBackend implements VoicePlaybackBackend {
  final StreamController<void> _completed = StreamController<void>.broadcast();
  final StreamController<Duration> _position =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _duration =
      StreamController<Duration>.broadcast();
  bool _closed = false;

  @override
  Stream<void> get completed => _completed.stream;

  @override
  Stream<Duration> get positionChanged => _position.stream;

  @override
  Stream<Duration> get durationChanged => _duration.stream;

  @override
  Future<void> playFile(String path, {required String mimeType}) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _completed.close();
    await _position.close();
    await _duration.close();
  }

  Future<void> closeIfNeeded() => dispose();
}

AttachmentEnqueueRequest _enqueueRequest({
  required PreparedAttachmentSource source,
  required AttachmentMetadata metadata,
  required AttachmentCapabilityProfile profile,
}) => AttachmentEnqueueRequest(
  accountId: _account,
  server: _server,
  roomToken: _room,
  source: source,
  metadata: metadata,
  davUserId: DavUserId.parse('user-a'),
  profile: profile,
  credentialGeneration: 3,
  capabilityGeneration: 7,
  roomCanWrite: true,
  policy: AttachmentUploadPolicy(
    normalUploadMaximumBytes: 1024 * 1024,
    chunkSizeBytes: 1024000,
  ),
);

AttachmentCapabilityProfile _profile({
  bool voice = true,
  bool silent = false,
  bool caption = false,
}) => AttachmentCapabilityProfile.fromSnapshot(
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
              'chat-replies',
              if (voice) 'voice-message-sharing',
              if (silent) 'silent-send',
              if (caption) 'media-caption',
              'threads',
            ],
            'config': <String, Object?>{
              'attachments': <String, Object?>{
                'allowed': true,
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

AttachmentJobProgress _progress(
  AttachmentJobPhase phase, {
  double progress = 0,
  bool retryAllowed = false,
  String? errorClass,
}) => AttachmentJobProgress(
  accountId: _account,
  jobId: _jobId,
  phase: phase,
  progress: progress,
  attemptCount: 1,
  automaticRetryCount: 0,
  retryAllowed: retryAllowed,
  errorClass: errorClass,
  messageIds: phase == AttachmentJobPhase.completed
      ? const <int>[42]
      : const <int>[],
);

Uint8List _oneSecondWav() {
  const sampleRate = 8000;
  const channels = 1;
  const bitsPerSample = 16;
  const dataLength = sampleRate * channels * (bitsPerSample ~/ 8);
  final bytes = Uint8List(44 + dataLength);
  final data = ByteData.sublistView(bytes);

  _writeAscii(bytes, 0, 'RIFF');
  data.setUint32(4, 36 + dataLength, Endian.little);
  _writeAscii(bytes, 8, 'WAVE');
  _writeAscii(bytes, 12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * channels * 2, Endian.little);
  data.setUint16(32, channels * 2, Endian.little);
  data.setUint16(34, bitsPerSample, Endian.little);
  _writeAscii(bytes, 36, 'data');
  data.setUint32(40, dataLength, Endian.little);
  return bytes;
}

void _writeAscii(Uint8List bytes, int offset, String value) {
  for (var index = 0; index < value.length; index++) {
    bytes[offset + index] = value.codeUnitAt(index);
  }
}

final _account = AccountId.parse('account-a');
final _server = ServerBase.parse('https://cloud.example.invalid/nextcloud');
final _room = ConversationToken.parse(
  'rooma123',
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidAttachmentModel,
);
final _jobId = AttachmentJobId.parse('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
