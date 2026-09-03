part of 'chat_media_composer_test.dart';

void _registerChatMediaComposerThreadContextTests(
  DurableAttachmentSourceStore Function() currentSourceStore,
) {
  group('media thread context', () {
    testWidgets('named thread Giphy uses threadId without replyTo', (
      tester,
    ) async {
      final bridge = _RecordingBridge();
      addTearDown(bridge.close);
      final voiceBackends = _VoiceBackendFactory();
      addTearDown(voiceBackends.close);
      final controller = ChatMediaComposerController();

      await tester.pumpWidget(
        _threadComposerApp(
          sourceStore: currentSourceStore(),
          bridge: bridge.bridge,
          threadBinding: ChatMediaThreadBinding.named(
            accountId: _account,
            roomToken: _room,
            rootMessageId: 74,
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
            displayName: 'named-thread.gif',
          ),
        ),
      );
      await _pumpUntil(tester, () => bridge.metadata.isNotEmpty);

      expect(started, isTrue);
      expect(bridge.metadata.single.replyTo, isNull);
      expect(bridge.metadata.single.threadId, 74);
    });

    testWidgets('named thread file uses threadId without replyTo', (
      tester,
    ) async {
      final bridge = _RecordingBridge();
      addTearDown(bridge.close);
      final voiceBackends = _VoiceBackendFactory();
      addTearDown(voiceBackends.close);

      await tester.pumpWidget(
        _threadComposerApp(
          sourceStore: currentSourceStore(),
          bridge: bridge.bridge,
          threadBinding: ChatMediaThreadBinding.named(
            accountId: _account,
            roomToken: _room,
            rootMessageId: 75,
          ),
          voiceBackends: voiceBackends,
        ),
      );
      await _pickAttachmentSource(tester);
      await _pumpUntil(tester, () => bridge.metadata.isNotEmpty);

      expect(bridge.metadata.single.replyTo, isNull);
      expect(bridge.metadata.single.threadId, 75);
    });

    testWidgets('ordinary thread voice uses replyTo without threadId', (
      tester,
    ) async {
      final bridge = _RecordingBridge();
      addTearDown(bridge.close);
      final voiceBackends = _VoiceBackendFactory();
      addTearDown(voiceBackends.close);

      await tester.pumpWidget(
        _threadComposerApp(
          sourceStore: currentSourceStore(),
          bridge: bridge.bridge,
          threadBinding: ChatMediaThreadBinding.ordinary(
            accountId: _account,
            roomToken: _room,
            rootMessageId: 76,
          ),
          voiceBackends: voiceBackends,
        ),
      );
      await _prepareVoicePreview(tester, voiceBackends);
      await tester.tap(find.byKey(const Key('voice-send')));
      await _pumpUntil(tester, () => bridge.metadata.isNotEmpty);

      expect(bridge.metadata.single.replyTo, 76);
      expect(bridge.metadata.single.threadId, isNull);
    });

    testWidgets('scope-mismatched thread binding disables every media action', (
      tester,
    ) async {
      final bridge = _RecordingBridge();
      addTearDown(bridge.close);
      final voiceBackends = _VoiceBackendFactory();
      addTearDown(voiceBackends.close);
      final controller = ChatMediaComposerController();

      await tester.pumpWidget(
        _threadComposerApp(
          sourceStore: currentSourceStore(),
          bridge: bridge.bridge,
          threadBinding: ChatMediaThreadBinding.ordinary(
            accountId: AccountId.parse('account-b'),
            roomToken: _room,
            rootMessageId: 77,
          ),
          threadId: 77,
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
      expect(find.byKey(const Key('voice-record')), findsNothing);
      expect(
        await tester.runAsync(
          () => controller.submitGiphyAttachment(
            (_) => throw StateError('invalid binding must not load bytes'),
          ),
        ),
        isFalse,
      );
      expect(bridge.metadata, isEmpty);
    });
  });
}

Widget _threadComposerApp({
  Key composerKey = const Key('thread-media-composer-under-test'),
  required DurableAttachmentSourceStore sourceStore,
  required AttachmentSubmissionBridge bridge,
  required ChatMediaThreadBinding threadBinding,
  int? threadId,
  _VoiceBackendFactory? voiceBackends,
  ChatMediaComposerController? controller,
  ContactSelectionBackend contactSelectionBackend =
      const PlatformContactSelectionBackend(),
}) {
  return localizedTestApp(
    home: Scaffold(
      body: ChatMediaComposer(
        key: composerKey,
        accountId: _account,
        server: _server,
        roomToken: _room,
        threadId: threadId ?? threadBinding.rootMessageId,
        threadBinding: threadBinding,
        replyTarget: null,
        onReplyDurablyAccepted: null,
        sourceStore: sourceStore,
        capabilityProfile: _profile(),
        submissionBridge: bridge,
        controller: controller ?? ChatMediaComposerController(),
        imageSelectionBackend: const _ImageBackend(),
        contactSelectionBackend: contactSelectionBackend,
        createVoiceCaptureBackend: voiceBackends?.createCapture,
        createVoicePlaybackBackend: voiceBackends?.createPlayback,
      ),
    ),
  );
}
