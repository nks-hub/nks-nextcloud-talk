part of 'chat_media_composer_test.dart';

void _registerChatMediaComposerDesktopDropTests(
  DurableAttachmentSourceStore Function() sourceStore,
) {
  testWidgets(
    'six dropped files show their count and every file is reachable by mouse',
    (tester) async {
      tester.view.physicalSize = const Size(460, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final bridge = _RecordingBridge();
      addTearDown(bridge.close);
      final voiceBackends = _VoiceBackendFactory();
      addTearDown(voiceBackends.close);
      final media = ChatMediaComposerController();
      await tester.pumpWidget(
        DesktopAttachmentDrop(
          child: _composerApp(
            sourceStore: sourceStore(),
            bridge: bridge.bridge,
            threadId: null,
            voiceBackends: voiceBackends,
            controller: media,
          ),
        ),
      );
      final drop = DesktopAttachmentDrop.controllerOf(
        tester.element(find.byKey(const Key('chat-media-composer'))),
      );
      final files = List.generate(
        6,
        (index) => DropItemFile.fromData(
          Uint8List.fromList([0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x34]),
          name: 'file-${index + 1}.pdf',
          path: 'file-${index + 1}.pdf',
        ),
      );
      expect(
        await tester.runAsync(() => drop.accept(files)),
        DesktopAttachmentDropOutcome.accepted,
      );
      await tester.pumpAndSettle();
      expect(find.text('6 attachments'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const Key('previous-prepared-attachments')),
            )
            .onPressed,
        isNull,
      );
      final seen = <String>{};
      for (var page = 0; page < 6; page++) {
        for (var index = 1; index <= 6; index++) {
          if (find.text('file-$index.pdf').hitTestable().evaluate().isNotEmpty) {
            seen.add('file-$index.pdf');
          }
        }
        final next = find.byKey(const Key('next-prepared-attachments'));
        if (tester.widget<IconButton>(next).onPressed == null) break;
        await tester.tap(next);
        await tester.pumpAndSettle();
      }
      expect(seen, {
        for (var index = 1; index <= 6; index++) 'file-$index.pdf',
      });
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const Key('next-prepared-attachments')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('Remove').hitTestable().last);
      await tester.pumpAndSettle();
      expect(find.text('5 attachments'), findsOneWidget);
      expect(await tester.runAsync(media.sendPreparedAttachment), isTrue);
      expect(bridge.sources.map((source) => source.displayName), [
        for (var index = 1; index <= 5; index++) 'file-$index.pdf',
      ]);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('composer-attachment-count')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final (supportsSilent, sendSilently) in [
    (true, false),
    (true, true),
    (false, false),
  ]) {
    testWidgets(
      'photo batch notifications: support=$supportsSilent silent=$sendSilently',
      (tester) async {
        final profile = _profile(silent: supportsSilent);
        final bridge = _RecordingBridge(profile: profile);
        addTearDown(bridge.close);
        final voiceBackends = _VoiceBackendFactory();
        addTearDown(voiceBackends.close);
        final media = ChatMediaComposerController();
        await tester.pumpWidget(
          _composerApp(
            sourceStore: sourceStore(),
            bridge: bridge.bridge,
            threadId: null,
            voiceBackends: voiceBackends,
            controller: media,
            profile: profile,
            silent: sendSilently,
            imageSelectionBackend: _AlbumPicker(),
          ),
        );
        await tester.runAsync(
          () => media.pickAttachment(AttachmentPickerSource.gallery),
        );
        await tester.runAsync(media.sendPreparedAttachment);
        expect(bridge.metadata.map((metadata) => metadata.silent), [
          sendSilently,
          supportsSilent,
          supportsSilent,
          supportsSilent,
        ]);
        expect(
          bridge.metadata
              .map((metadata) => metadata.photoAlbum!.albumId)
              .toSet(),
          hasLength(1),
        );
      },
    );
  }

  testWidgets(
    'four picked photos share one album, another send gets a new one',
    (tester) async {
      final bridge = _RecordingBridge();
      addTearDown(bridge.close);
      final voiceBackends = _VoiceBackendFactory();
      addTearDown(voiceBackends.close);
      final media = ChatMediaComposerController();
      await tester.pumpWidget(
        _composerApp(
          sourceStore: sourceStore(),
          bridge: bridge.bridge,
          threadId: null,
          voiceBackends: voiceBackends,
          controller: media,
          imageSelectionBackend: _AlbumPicker(),
        ),
      );
      await tester.runAsync(
        () => media.pickAttachment(AttachmentPickerSource.gallery),
      );
      await tester.pump();
      expect(bridge.sessions, isEmpty);
      expect(await tester.runAsync(media.sendPreparedAttachment), isTrue);
      final albums = bridge.metadata.map((m) => m.photoAlbum!).toList();
      expect(albums, hasLength(4));
      expect(albums.map((a) => a.albumId).toSet(), hasLength(1));
      expect(albums.map((a) => a.index), [0, 1, 2, 3]);
      expect(albums.map((a) => a.referenceId).toSet(), hasLength(4));
      await tester.runAsync(() async {
        for (final session in bridge.sessions) {
          session.add(_progress(AttachmentJobPhase.completed));
        }
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(
        await tester.runAsync(
          () => media.pickAttachment(AttachmentPickerSource.gallery),
        ),
        isTrue,
      );
      await tester.pump();
      await tester.runAsync(media.sendPreparedAttachment);
      expect(bridge.metadata, hasLength(8));
      expect(
        bridge.metadata.last.photoAlbum!.albumId,
        isNot(albums.first.albumId),
      );
    },
  );

  for (final mode in ['together', 'separate', 'overlapping']) {
    testWidgets('two Office files wait and send ($mode)', (tester) async {
      final profile = _profile(caption: true);
      final bridge = _RecordingBridge(profile: profile);
      var captionsConsumed = 0;
      addTearDown(bridge.close);
      final voiceBackends = _VoiceBackendFactory();
      addTearDown(voiceBackends.close);
      final media = ChatMediaComposerController();
      await tester.pumpWidget(
        DesktopAttachmentDrop(
          child: _composerApp(
            sourceStore: sourceStore(),
            bridge: bridge.bridge,
            threadId: null,
            voiceBackends: voiceBackends,
            controller: media,
            profile: profile,
            captionSource: () => "Caption",
            onCaptionConsumed: () => captionsConsumed++,
            replyTarget: _replyTarget(),
          ),
        ),
      );
      final drop = DesktopAttachmentDrop.controllerOf(
        tester.element(find.byKey(const Key('chat-media-composer'))),
      );
      final files = ['slides.pptx', 'document.docx']
          .map(
            (name) => DropItemFile.fromData(
              Uint8List.fromList([0x50, 0x4b, 3, 4]),
              name: name,
              path: name,
            ),
          )
          .toList();
      if (mode == 'overlapping') {
        final outcomes = await tester.runAsync(
          () => Future.wait(files.map((file) => drop.accept([file]))),
        );
        expect(outcomes, everyElement(DesktopAttachmentDropOutcome.accepted));
      } else {
        for (final batch
            in mode == 'together' ? [files] : files.map((file) => [file])) {
          final outcome = await tester.runAsync(() => drop.accept(batch));
          expect(outcome, DesktopAttachmentDropOutcome.accepted);
        }
      }
      await tester.pump();
      expect(find.text('slides.pptx'), findsOneWidget);
      expect(find.text('document.docx'), findsOneWidget);
      expect(bridge.sessions, isEmpty);
      expect(await tester.runAsync(media.sendPreparedAttachment), isTrue);
      await tester.pump();
      expect(bridge.sources.map((source) => source.displayName), [
        'slides.pptx',
        'document.docx',
      ]);
      expect(media.hasPreparedAttachment, isFalse);
      expect(bridge.metadata.map((metadata) => metadata.caption), [
        "Caption",
        null,
      ]);
      expect(bridge.metadata.map((metadata) => metadata.replyTo), [51, 51]);
      expect(captionsConsumed, 1);
    });
  }

  testWidgets('removing one pasted file keeps the other for sending', (
    tester,
  ) async {
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);
    final media = ChatMediaComposerController();
    final files = await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('paste-files-');
      addTearDown(() => directory.delete(recursive: true));
      return Future.wait(
        ['slides.pptx', 'document.docx'].map((name) async {
          final file = File('${directory.path}/$name');
          await file.writeAsBytes([0x50, 0x4b, 3, 4]);
          return file.path;
        }),
      );
    });
    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore(),
        bridge: bridge.bridge,
        threadId: null,
        voiceBackends: voiceBackends,
        controller: media,
      ),
    );
    expect(await tester.runAsync(() => media.attachFiles(files!)), isTrue);
    await tester.pump();
    await tester.tap(find.byKey(const Key('remove-prepared-attachment')).first);
    await tester.pump();
    expect(find.text('slides.pptx'), findsNothing);
    expect(find.text('document.docx'), findsOneWidget);
    expect(await tester.runAsync(media.sendPreparedAttachment), isTrue);
    expect(bridge.sources.single.displayName, 'document.docx');
  });

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

final class _AlbumPicker
    implements ImageSelectionBackend, MultipleImageSelectionBackend {
  @override
  Future<ImageSelection?> selectImage(AttachmentPickerSource source) =>
      const _ImageBackend().selectImage(source);

  @override
  Future<List<ImageSelection>> selectImages() async {
    final selection = (await selectImage(AttachmentPickerSource.gallery))!;
    return List.generate(
      4,
      (index) => ImageSelection(
        displayName: 'photo-$index.png',
        declaredMimeType: selection.declaredMimeType,
        byteLength: selection.byteLength,
        openRead: selection.openRead,
      ),
    );
  }
}
