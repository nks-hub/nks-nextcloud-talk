part of 'chat_media_composer_test.dart';

void _registerChatMediaComposerFileTests(
  DurableAttachmentSourceStore Function() sourceStore,
) {
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
        sourceStore: sourceStore(),
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
    var settingsOpenCalls = 0;

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore(),
        bridge: bridge.bridge,
        threadId: null,
        voiceBackends: voiceBackends,
        imageSelectionBackend: const _RefusingCameraBackend(),
        openAppSettings: () async {
          settingsOpenCalls++;
          return false;
        },
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
    await tester.tap(find.byKey(const Key('open-attachment-app-settings')));
    await tester.pump();
    expect(settingsOpenCalls, 1);
    expect(
      find.text('The system settings could not be opened.'),
      findsOneWidget,
    );
    expect(bridge.sessions, isEmpty);
  });

  testWidgets('a typed message goes out as the attachment caption', (
    tester,
  ) async {
    // Talk carries a file's caption on the share itself, so text waiting in
    // the field belongs to the attachment picked next instead of being left
    // behind. Measured against Nextcloud 34: the share came back as a comment
    // whose message is the caption, with `actor` and `file` among the
    // parameters.
    final bridge = _RecordingBridge(profile: _profile(caption: true));
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);
    var field = '  Tohle je popisek  ';
    var cleared = 0;

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore(),
        bridge: bridge.bridge,
        threadId: null,
        profile: _profile(caption: true),
        voiceBackends: voiceBackends,
        captionSource: () => field,
        onCaptionConsumed: () {
          cleared++;
          field = '';
        },
      ),
    );
    await _pickAttachmentSource(tester);
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);

    expect(bridge.metadata.single.caption, 'Tohle je popisek');
    expect(cleared, 1, reason: 'the field it came from is emptied once');
    expect(field, isEmpty);
  });

  testWidgets('an empty field sends no caption and clears nothing', (
    tester,
  ) async {
    final bridge = _RecordingBridge(profile: _profile(caption: true));
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);
    var cleared = 0;

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore(),
        bridge: bridge.bridge,
        threadId: null,
        profile: _profile(caption: true),
        voiceBackends: voiceBackends,
        captionSource: () => '   ',
        onCaptionConsumed: () => cleared++,
      ),
    );
    await _pickAttachmentSource(tester);
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);

    expect(bridge.metadata.single.caption, isNull);
    expect(cleared, 0);
  });

  testWidgets('without the capability the text stays where it is', (
    tester,
  ) async {
    // A server without `media-caption` would only refuse the share, and
    // taking the text away for a caption that never went is worse than
    // sending the attachment on its own.
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);
    var cleared = 0;

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore(),
        bridge: bridge.bridge,
        threadId: null,
        voiceBackends: voiceBackends,
        captionSource: () => 'Tohle musí zůstat',
        onCaptionConsumed: () => cleared++,
      ),
    );
    await _pickAttachmentSource(tester);
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);

    expect(bridge.metadata.single.caption, isNull);
    expect(cleared, 0, reason: 'nothing was consumed, so nothing is cleared');
  });
}
