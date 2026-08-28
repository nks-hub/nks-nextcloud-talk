import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/attachment_service.dart';
import 'package:nextcloudtalk/features/chat/composer/attachment_submission.dart';
import 'package:nextcloudtalk/features/chat/composer/chat_media_composer.dart';
import 'package:nextcloudtalk/features/chat/composer/giphy_attachment.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';
import 'package:nextcloudtalk/platform/media/image_attachment_picker.dart';
import 'package:nextcloudtalk/platform/media/voice_platform_adapters.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

part 'chat_media_composer_test_support.dart';
part 'chat_media_composer_thread_context_test.part.dart';

void main() {
  late Directory root;
  late DurableAttachmentSourceStore sourceStore;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nctalk-media-composer-test-');
    sourceStore = DurableAttachmentSourceStore(
      root: root,
      maximumSourceBytes: 128 * 1024,
    );
    await sourceStore.initialize();
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  _registerChatMediaComposerThreadContextTests(() => sourceStore);

  testWidgets('a silent composer marks the attachment it submits silent', (
    tester,
  ) async {
    final profile = _profile(silent: true);
    final bridge = _RecordingBridge(profile: profile);
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore,
        bridge: bridge.bridge,
        threadId: null,
        profile: profile,
        silent: true,
        voiceBackends: voiceBackends,
      ),
    );
    await _pickAttachmentSource(tester);
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);

    expect(bridge.metadata.single.silent, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a server without silent-send refuses a silent attachment', (
    tester,
  ) async {
    // The capability profile is the guard, not the button: a stale toggle must
    // not turn into a request the server never agreed to.
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore,
        bridge: bridge.bridge,
        threadId: null,
        silent: true,
        voiceBackends: voiceBackends,
      ),
    );
    // No admission, so the media actions never arm: the request the server
    // would refuse cannot be built in the first place.
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('pick-image-attachment')))
          .onPressed,
      isNull,
    );
    expect(bridge.metadata, isEmpty);
    expect(bridge.sessions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('root image reply is accepted before later upload confirmation', (
    tester,
  ) async {
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);
    final acceptedReplies = <int>[];

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore,
        bridge: bridge.bridge,
        threadId: null,
        replyTarget: _replyTarget(),
        onReplyDurablyAccepted: (messageId) {
          acceptedReplies.add(messageId);
          throw StateError('host callback failures stay outside admission');
        },
        voiceBackends: voiceBackends,
      ),
    );
    await _pickAttachmentSource(tester);
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);

    expect(bridge.metadata, hasLength(1));
    expect(bridge.metadata.single.kind, AttachmentMessageKind.file);
    expect(bridge.metadata.single.replyTo, 51);
    expect(bridge.metadata.single.threadId, isNull);
    expect(acceptedReplies, <int>[51]);

    bridge.sessions.single.add(
      _progress(AttachmentJobPhase.uploading, progress: 0.42),
    );
    await tester.pump();
    expect(find.text('Uploading… 42%'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('image-attachment-upload-progress')),
          )
          .value,
      0.42,
    );

    bridge.sessions.single
      ..add(_progress(AttachmentJobPhase.awaitingConfirmation, progress: 1))
      ..add(_progress(AttachmentJobPhase.completed, progress: 1));
    await tester.pump();

    expect(
      find.byKey(const Key('image-attachment-upload-panel')),
      findsNothing,
    );
    expect(find.text('Attachment sent'), findsNothing);
    expect(
      find.byKey(const Key('image-attachment-upload-progress')),
      findsNothing,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('pick-image-attachment')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('ordinary thread Giphy keeps reply-specific notification scope', (
    tester,
  ) async {
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);
    final controller = ChatMediaComposerController();

    await tester.pumpWidget(
      _threadComposerApp(
        sourceStore: sourceStore,
        bridge: bridge.bridge,
        threadBinding: ChatMediaThreadBinding.ordinary(
          accountId: _account,
          roomToken: _room,
          rootMessageId: 73,
        ),
        voiceBackends: voiceBackends,
        controller: controller,
      ),
    );

    final started = await tester.runAsync(
      () => controller.submitGiphyAttachment(
        (_) async => GiphyAttachmentPayload(
          body: Uint8List.fromList(const <int>[
            0x47,
            0x49,
            0x46,
            0x38,
            0x39,
            0x61,
            0x01,
            0x00,
            0x01,
            0x00,
          ]),
          mimeType: 'image/gif',
          displayName: 'giphy-fixture.gif',
        ),
      ),
    );
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);

    expect(started, isTrue);
    expect(bridge.sources, hasLength(1));
    expect(bridge.sources.single.mimeType, 'image/gif');
    expect(bridge.sources.single.displayName, 'giphy-fixture.gif');
    expect(bridge.metadata.single.kind, AttachmentMessageKind.file);
    expect(bridge.metadata.single.replyTo, 73);
    expect(bridge.metadata.single.threadId, isNull);

    await tester.pump();
    bridge.sessions.single.add(
      _progress(AttachmentJobPhase.completed, progress: 1),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('image-attachment-upload-panel'))
          .evaluate()
          .isEmpty,
    );
  });

  testWidgets('ordinary thread image retry keeps replyTo scope', (
    tester,
  ) async {
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);

    await tester.pumpWidget(
      _threadComposerApp(
        sourceStore: sourceStore,
        bridge: bridge.bridge,
        threadBinding: ChatMediaThreadBinding.ordinary(
          accountId: _account,
          roomToken: _room,
          rootMessageId: 73,
        ),
        voiceBackends: voiceBackends,
      ),
    );
    await _pickAttachmentSource(tester);
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);

    final metadata = bridge.metadata.single;
    expect(metadata.kind, AttachmentMessageKind.file);
    expect(metadata.replyTo, 73);
    expect(metadata.threadId, isNull);

    final session = bridge.sessions.single;
    session.add(
      _progress(
        AttachmentJobPhase.retryable,
        retryAllowed: true,
        errorClass: 'dav-transient',
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const Key('retry-image-attachment-upload')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('retry-image-attachment-upload')));
    await _pumpUntil(tester, () => session.retryCount == 1);
    session.add(_progress(AttachmentJobPhase.uploading, progress: 0.55));
    await tester.pump();

    await tester.tap(find.byKey(const Key('cancel-image-attachment-upload')));
    await _pumpUntil(tester, () => session.cancelCount == 1);

    expect(find.text('Upload cancelled'), findsOneWidget);
    expect(bridge.metadata, hasLength(1));
  });

  testWidgets(
    'image retry after a same-room rebuild reuses the admitted durable job',
    (tester) async {
      final admittedBridge = _RecordingBridge();
      final rebuiltBridge = _RecordingBridge();
      addTearDown(admittedBridge.close);
      addTearDown(rebuiltBridge.close);
      final voiceBackends = _VoiceBackendFactory();
      addTearDown(voiceBackends.close);
      const composerKey = Key('same-room-media-composer');

      await tester.pumpWidget(
        _composerApp(
          composerKey: composerKey,
          sourceStore: sourceStore,
          bridge: admittedBridge.bridge,
          threadId: null,
          voiceBackends: voiceBackends,
        ),
      );
      await _pickAttachmentSource(tester);
      await _pumpUntil(tester, () => admittedBridge.sessions.isNotEmpty);
      final admittedSession = admittedBridge.sessions.single;
      admittedSession.add(
        _progress(
          AttachmentJobPhase.retryable,
          retryAllowed: true,
          errorClass: 'dav-transient',
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('retry-image-attachment-upload')),
        findsOneWidget,
      );

      await tester.pumpWidget(
        _composerApp(
          composerKey: composerKey,
          sourceStore: sourceStore,
          bridge: rebuiltBridge.bridge,
          threadId: null,
          voiceBackends: voiceBackends,
        ),
      );
      await tester.tap(find.byKey(const Key('retry-image-attachment-upload')));
      await _pumpUntil(
        tester,
        () =>
            admittedSession.retryCount > 0 || rebuiltBridge.sessions.isNotEmpty,
      );

      expect(admittedSession.retryCount, 1);
      expect(admittedBridge.metadata, hasLength(1));
      expect(rebuiltBridge.metadata, isEmpty);
      expect(rebuiltBridge.sessions, isEmpty);
    },
  );

  testWidgets('root voice recording queues and resets after confirmation', (
    tester,
  ) async {
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);
    final acceptedReplies = <int>[];

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore,
        bridge: bridge.bridge,
        threadId: null,
        replyTarget: _replyTarget(messageId: 52),
        onReplyDurablyAccepted: acceptedReplies.add,
        voiceBackends: voiceBackends,
      ),
    );
    await _prepareVoicePreview(tester, voiceBackends);

    await tester.tap(find.byKey(const Key('voice-send')));
    await _pumpUntil(tester, () => bridge.metadata.isNotEmpty);

    final metadata = bridge.metadata.single;
    expect(metadata.kind, AttachmentMessageKind.voice);
    expect(metadata.replyTo, 52);
    expect(metadata.threadId, isNull);
    expect(acceptedReplies, <int>[52]);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 901));
    expect(find.byKey(const Key('voice-record')), findsOneWidget);
  });

  testWidgets(
    'voice draft survives provider rebuild and submits through current bridge',
    (tester) async {
      final firstBridge = _RecordingBridge();
      final currentBridge = _RecordingBridge();
      addTearDown(firstBridge.close);
      addTearDown(currentBridge.close);
      final voiceBackends = _VoiceBackendFactory();
      addTearDown(voiceBackends.close);

      await tester.pumpWidget(
        _threadComposerApp(
          sourceStore: sourceStore,
          bridge: firstBridge.bridge,
          threadBinding: ChatMediaThreadBinding.named(
            accountId: _account,
            roomToken: _room,
            rootMessageId: 90210,
          ),
          voiceBackends: voiceBackends,
        ),
      );
      await _prepareVoicePreview(tester, voiceBackends);
      expect(voiceBackends.captureBackends, hasLength(1));

      await tester.pumpWidget(
        _threadComposerApp(
          sourceStore: sourceStore,
          bridge: currentBridge.bridge,
          threadBinding: ChatMediaThreadBinding.named(
            accountId: _account,
            roomToken: _room,
            rootMessageId: 90210,
          ),
          voiceBackends: voiceBackends,
        ),
      );

      expect(find.byKey(const Key('voice-send')), findsOneWidget);
      expect(voiceBackends.captureBackends, hasLength(1));
      await tester.tap(find.byKey(const Key('voice-send')));
      await _pumpUntil(tester, () => currentBridge.metadata.isNotEmpty);

      expect(firstBridge.metadata, isEmpty);
      final metadata = currentBridge.metadata.single;
      expect(metadata.kind, AttachmentMessageKind.voice);
      expect(metadata.replyTo, isNull);
      expect(metadata.threadId, 90210);
    },
  );

  testWidgets('pending image selection survives a same-room parent rebuild', (
    tester,
  ) async {
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final backend = _PendingImageBackend();
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);
    var currentReply = _replyTarget(messageId: 61);
    final acceptedReplies = <int>[];

    Widget app() => _composerApp(
      composerKey: ValueKey((_account.value, _room.value, null)),
      sourceStore: sourceStore,
      bridge: bridge.bridge,
      threadId: null,
      replyTarget: currentReply,
      onReplyDurablyAccepted: (messageId) {
        acceptedReplies.add(messageId);
        if (currentReply.messageId == messageId) {
          currentReply = _replyTarget(messageId: 0);
        }
      },
      imageSelectionBackend: backend,
      voiceBackends: voiceBackends,
    );

    await tester.pumpWidget(app());
    await _pickAttachmentSource(tester);
    await _pumpUntil(tester, () => backend.selectionRequested);

    currentReply = _replyTarget(messageId: 62);
    await tester.pumpWidget(app());
    await backend.complete();
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);

    expect(bridge.metadata, hasLength(1));
    expect(bridge.metadata.single.replyTo, 61);
    expect(acceptedReplies, <int>[61]);
    expect(currentReply.messageId, 62);
    expect(bridge.sessions, hasLength(1));
  });

  testWidgets(
    'navigation does not discard an image before durable admission settles',
    (tester) async {
      final prepareStarted = Completer<void>();
      final releasePrepare = Completer<void>();
      final enqueueFinished = Completer<void>();
      final durable = _DurableSession();
      addTearDown(durable.close);
      final voiceBackends = _VoiceBackendFactory();
      addTearDown(voiceBackends.close);
      final acceptedReplies = <int>[];
      PreparedAttachmentSource? preparedSource;
      final bridge = AttachmentSubmissionBridge(
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
              preparedSource = source;
              prepareStarted.complete();
              await releasePrepare.future;
              return _enqueueRequest(
                source: source,
                metadata: metadata,
                profile: _profile(),
              );
            },
        enqueue: (_) async {
          enqueueFinished.complete();
          return durable;
        },
      );

      await tester.pumpWidget(
        _composerApp(
          sourceStore: sourceStore,
          bridge: bridge,
          threadId: null,
          replyTarget: _replyTarget(messageId: 63),
          onReplyDurablyAccepted: acceptedReplies.add,
          voiceBackends: voiceBackends,
        ),
      );
      await _pickAttachmentSource(tester);
      await _pumpUntil(tester, () => prepareStarted.isCompleted);
      final source = preparedSource!;
      final sourcePath = (await tester.runAsync(
        () => sourceStore.resolveVerifiedPath(source),
      ))!;

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      var sourceExistsDuringAdmission = true;
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.pump(const Duration(milliseconds: 1));
        sourceExistsDuringAdmission = (await tester.runAsync(
          () => File(sourcePath).exists(),
        ))!;
        if (!sourceExistsDuringAdmission) {
          break;
        }
      }

      releasePrepare.complete();
      await _pumpUntil(tester, () => enqueueFinished.isCompleted);
      expect(sourceExistsDuringAdmission, isTrue);
      expect(acceptedReplies, isEmpty);
    },
  );

  testWidgets('failed admission after navigation discards the prepared image', (
    tester,
  ) async {
    final prepareStarted = Completer<void>();
    final releasePrepare = Completer<void>();
    final prepareSettled = Completer<void>();
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);
    final acceptedReplies = <int>[];
    PreparedAttachmentSource? preparedSource;
    final bridge = AttachmentSubmissionBridge(
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
            preparedSource = source;
            prepareStarted.complete();
            await releasePrepare.future;
            prepareSettled.complete();
            throw StateError('durable admission failed');
          },
      enqueue: (_) => throw StateError('enqueue must not run'),
    );

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore,
        bridge: bridge,
        threadId: null,
        replyTarget: _replyTarget(messageId: 64),
        onReplyDurablyAccepted: acceptedReplies.add,
        voiceBackends: voiceBackends,
      ),
    );
    await _pickAttachmentSource(tester);
    await _pumpUntil(tester, () => prepareStarted.isCompleted);
    final sourcePath = (await tester.runAsync(
      () => sourceStore.resolveVerifiedPath(preparedSource!),
    ))!;

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    releasePrepare.complete();
    await _pumpUntil(tester, () => prepareSettled.isCompleted);

    var sourceExists = true;
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump(const Duration(milliseconds: 1));
      sourceExists = (await tester.runAsync(() => File(sourcePath).exists()))!;
      if (!sourceExists) {
        break;
      }
    }
    expect(sourceExists, isFalse);
    expect(acceptedReplies, isEmpty);
  });

  testWidgets('narrow idle toolbar keeps all five actions on one baseline', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore,
        bridge: bridge.bridge,
        threadId: null,
        voiceBackends: voiceBackends,
        idleActions: <Widget>[
          IconButton(
            key: const Key('open-emoji-picker'),
            onPressed: () {},
            icon: const Icon(Icons.emoji_emotions_outlined),
          ),
          IconButton(
            key: const Key('open-giphy-picker'),
            onPressed: () {},
            icon: const Icon(Icons.gif_box_outlined),
          ),
          IconButton.filled(
            key: const Key('send-message'),
            onPressed: () {},
            icon: const Icon(Icons.send_rounded),
          ),
        ],
      ),
    );

    const actionKeys = <String>[
      'pick-image-attachment',
      'voice-record',
      'open-emoji-picker',
      'open-giphy-picker',
      'send-message',
    ];
    final centerYs = actionKeys
        .map((key) => tester.getCenter(find.byKey(Key(key))).dy)
        .toSet();
    expect(centerYs, hasLength(1));
    for (final key in actionKeys) {
      final size = tester.getSize(find.byKey(Key(key)));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported voice capability leaves a disabled microphone', (
    tester,
  ) async {
    final bridge = _RecordingBridge(profile: _profile(voice: false));
    addTearDown(bridge.close);

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore,
        bridge: bridge.bridge,
        threadId: null,
        profile: _profile(voice: false),
      ),
    );

    final button = tester.widget<IconButton>(
      find.byKey(const Key('voice-record-unavailable')),
    );
    expect(button.onPressed, isNull);
    expect(find.byKey(const Key('voice-record')), findsNothing);
  });

  testWidgets('invalid reply bindings fail closed for every media action', (
    tester,
  ) async {
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);
    final invalidBindings = <({ChatMediaReplyTarget target, int? threadId})>[
      (
        target: _replyTarget(accountId: AccountId.parse('account-b')),
        threadId: null,
      ),
      (
        target: _replyTarget(
          roomToken: ConversationToken.parse('roomb123', path: r'$.roomToken'),
        ),
        threadId: null,
      ),
      (target: _replyTarget(messageId: 0), threadId: null),
      (
        target: _replyTarget(messageId: 51, messageThreadId: 50),
        threadId: null,
      ),
      (target: _replyTarget(deleted: true), threadId: null),
      (target: _replyTarget(systemMessage: true), threadId: null),
      (target: _replyTarget(), threadId: 73),
    ];

    for (var index = 0; index < invalidBindings.length; index++) {
      final binding = invalidBindings[index];
      final controller = ChatMediaComposerController();
      await tester.pumpWidget(
        _composerApp(
          composerKey: ValueKey('invalid-reply-$index'),
          sourceStore: sourceStore,
          bridge: bridge.bridge,
          threadId: binding.threadId,
          replyTarget: binding.target,
          voiceBackends: voiceBackends,
          controller: controller,
        ),
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('pick-image-attachment')))
            .onPressed,
        isNull,
      );
      final giphyStarted = await tester.runAsync(
        () => controller.submitGiphyAttachment(
          (_) => throw StateError('an invalid binding must not load bytes'),
        ),
      );
      expect(giphyStarted, isFalse);
      if (find.byKey(const Key('voice-record')).evaluate().isNotEmpty) {
        await tester.tap(find.byKey(const Key('voice-record')));
        await tester.pump();
      }
      expect(bridge.metadata, isEmpty);
    }
  });

  testWidgets('capability failure replaces loading and exposes retry', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      localizedTestApp(
        home: const Scaffold(body: ChatMediaComposerStatus.loading()),
      ),
    );
    expect(
      find.byKey(const Key('chat-media-composer-loading')),
      findsOneWidget,
    );

    await tester.pumpWidget(
      localizedTestApp(
        home: Scaffold(
          body: ChatMediaComposerStatus.unavailable(onRetry: () => retries++),
        ),
      ),
    );
    expect(find.byKey(const Key('chat-media-composer-loading')), findsNothing);
    expect(
      find.byKey(const Key('chat-media-composer-unavailable')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('retry-media-capabilities')));
    expect(retries, 1);
  });

  testWidgets('recording offers pause, resume and a live waveform', (
    tester,
  ) async {
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore,
        bridge: bridge.bridge,
        threadId: null,
        voiceBackends: voiceBackends,
      ),
    );
    await tester.tap(find.byKey(const Key('voice-record')));
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('voice-pause')).evaluate().isNotEmpty,
    );

    expect(find.byKey(const Key('voice-waveform')), findsOneWidget);
    final capture = voiceBackends.captureBackends.single;
    capture
      ..emitAmplitude(0.8)
      ..emitAmplitude(0.2);
    await _pumpUntil(tester, () => _waveformValue(tester) == '20%');

    await tester.tap(find.byKey(const Key('voice-pause')));
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('voice-resume')).evaluate().isNotEmpty,
    );
    expect(capture.pauses, 1);
    expect(find.byKey(const Key('voice-pause')), findsNothing);
    expect(find.byKey(const Key('voice-waveform')), findsOneWidget);

    await tester.tap(find.byKey(const Key('voice-resume')));
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('voice-pause')).evaluate().isNotEmpty,
    );
    expect(capture.resumes, 1);

    await tester.tap(find.byKey(const Key('voice-cancel-recording')));
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('voice-record')).evaluate().isNotEmpty,
    );
    expect(find.byKey(const Key('voice-waveform')), findsNothing);
  });

  testWidgets('a generic file travels the same durable upload path', (
    tester,
  ) async {
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);
    final acceptedReplies = <int>[];

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore,
        bridge: bridge.bridge,
        threadId: null,
        replyTarget: _replyTarget(messageId: 65),
        onReplyDurablyAccepted: acceptedReplies.add,
        voiceBackends: voiceBackends,
        imageSelectionBackend: const _DocumentBackend(),
      ),
    );
    await _pickAttachmentSource(tester, source: AttachmentPickerSource.file);
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);

    expect(bridge.sources, hasLength(1));
    expect(bridge.sources.single.mimeType, 'application/pdf');
    expect(bridge.sources.single.displayName, 'report.pdf');
    expect(
      bridge.sources.single.ownership,
      AttachmentSourceOwnership.appOwnedCopy,
    );
    expect(bridge.metadata.single.kind, AttachmentMessageKind.file);
    expect(bridge.metadata.single.replyTo, 65);
    expect(bridge.metadata.single.threadId, isNull);
    expect(acceptedReplies, <int>[65]);
  });

  testWidgets('a refused camera reports its own message, not a generic one', (
    tester,
  ) async {
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore,
        bridge: bridge.bridge,
        threadId: null,
        voiceBackends: voiceBackends,
        imageSelectionBackend: const _RefusingCameraBackend(),
      ),
    );
    await _pickAttachmentSource(tester, source: AttachmentPickerSource.camera);
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('image-attachment-upload-panel'))
          .evaluate()
          .isNotEmpty,
    );

    expect(
      find.text(
        'Taking a picture needs camera access. Grant it in the system '
        'settings and try again.',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('retry-image-attachment-upload')),
      findsNothing,
    );
    expect(bridge.sessions, isEmpty);
  });
}
