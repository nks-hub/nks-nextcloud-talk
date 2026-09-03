part of 'chat_media_composer_test.dart';

void _registerChatMediaComposerDesktopDropTests(
  DurableAttachmentSourceStore Function() sourceStore,
) {
  testWidgets('a desktop drop joins the durable attachment upload path', (
    tester,
  ) async {
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);
    final mediaController = ChatMediaComposerController();

    await tester.pumpWidget(
      DesktopAttachmentDrop(
        child: _composerApp(
          sourceStore: sourceStore(),
          bridge: bridge.bridge,
          threadId: null,
          voiceBackends: voiceBackends,
          controller: mediaController,
        ),
      ),
    );
    final controller = DesktopAttachmentDrop.controllerOf(
      tester.element(find.byKey(const Key('chat-media-composer'))),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    final submission = controller.accept(<DropItem>[
      DropItemFile.fromData(
        Uint8List.fromList('%PDF-1.7 desktop'.codeUnits),
        name: 'desktop.pdf',
        path: 'desktop.pdf',
        mimeType: 'application/pdf',
      ),
    ]);
    await _pumpUntil(tester, () => mediaController.hasPreparedAttachment);
    final outcome = await submission;
    // A drop prepares the file like the picker does; the send uploads it.
    expect(mediaController.hasPreparedAttachment, isTrue);
    expect(bridge.sessions, isEmpty);
    expect(
      await tester.runAsync(mediaController.sendPreparedAttachment),
      isTrue,
    );
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);

    expect(outcome, DesktopAttachmentDropOutcome.accepted);
    expect(bridge.sources, hasLength(1));
    expect(bridge.sources.single.displayName, 'desktop.pdf');
    expect(bridge.sources.single.mimeType, 'application/pdf');
    expect(
      bridge.sources.single.ownership,
      AttachmentSourceOwnership.appOwnedCopy,
    );
    expect(bridge.metadata.single.kind, AttachmentMessageKind.file);
  });

  testWidgets('pasted image bytes wait in the composer like a picked file', (
    tester,
  ) async {
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);
    final mediaController = ChatMediaComposerController();

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore(),
        bridge: bridge.bridge,
        threadId: null,
        voiceBackends: voiceBackends,
        controller: mediaController,
      ),
    );

    final attached = mediaController.attachImageBytes(
      Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
      mimeType: 'image/png',
      displayName: 'screenshot-20260903-184207.png',
    );
    await _pumpUntil(tester, () => mediaController.hasPreparedAttachment);
    expect(await attached, isTrue);
    expect(bridge.sessions, isEmpty, reason: 'nothing leaves before send');
    expect(find.text('screenshot-20260903-184207.png'), findsOneWidget);

    unawaited(mediaController.sendPreparedAttachment());
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);
    expect(bridge.sources.single.mimeType, 'image/png');
    expect(bridge.sources.single.displayName, 'screenshot-20260903-184207.png');
  });

  testWidgets('an oversize desktop drop never reaches upload admission', (
    tester,
  ) async {
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);
    final store = sourceStore();

    await tester.pumpWidget(
      DesktopAttachmentDrop(
        child: _composerApp(
          sourceStore: store,
          bridge: bridge.bridge,
          threadId: null,
          voiceBackends: voiceBackends,
        ),
      ),
    );
    final controller = DesktopAttachmentDrop.controllerOf(
      tester.element(find.byKey(const Key('chat-media-composer'))),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    final submission = controller.accept(<DropItem>[
      DropItemFile.fromData(
        Uint8List(store.maximumSourceBytes + 1),
        name: 'oversize.bin',
        path: 'oversize.bin',
      ),
    ]);
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('image-attachment-upload-panel'))
          .evaluate()
          .isNotEmpty,
    );
    final outcome = await submission;

    expect(outcome, DesktopAttachmentDropOutcome.accepted);
    expect(bridge.sessions, isEmpty);
    expect(find.text('The attachment could not be sent.'), findsOneWidget);
  });
}
