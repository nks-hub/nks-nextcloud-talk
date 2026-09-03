part of 'chat_media_composer_test.dart';

void _registerChatMediaComposerContactTests(
  DurableAttachmentSourceStore Function() sourceStore,
) {
  testWidgets('selected contact uses the scoped file attachment admission', (
    tester,
  ) async {
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final controller = ChatMediaComposerController();
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore(),
        bridge: bridge.bridge,
        threadId: null,
        controller: controller,
        voiceBackends: voiceBackends,
        contactSelectionBackend: _SelectedContactBackend(
          ContactSelection(displayName: 'Alice Example', vcard: _contactVCard),
        ),
      ),
    );

    expect(await tester.runAsync(controller.pickContact), isTrue);
    // Picking only prepares; nothing reaches admission until the send.
    expect(controller.hasPreparedAttachment, isTrue);
    expect(bridge.sessions, isEmpty);
    expect(await tester.runAsync(controller.sendPreparedAttachment), isTrue);
    await _pumpUntil(tester, () => bridge.sessions.isNotEmpty);

    expect(bridge.sources.single.mimeType, 'text/vcard');
    expect(bridge.sources.single.displayName, 'Alice Example.vcf');
    expect(bridge.metadata.single.kind, AttachmentMessageKind.file);
    expect(bridge.metadata.single.replyTo, isNull);
    expect(bridge.metadata.single.threadId, isNull);
    expect(find.byIcon(Icons.contact_page_outlined), findsOneWidget);
    final contactSemantics = find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.label == 'Contact',
    );
    expect(contactSemantics, findsOneWidget);
    expect(
      tester.widget<Semantics>(contactSemantics).properties.image,
      isFalse,
    );
  });

  testWidgets('dismissed contact picker queues nothing and shows no error', (
    tester,
  ) async {
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final controller = ChatMediaComposerController();
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore(),
        bridge: bridge.bridge,
        threadId: null,
        controller: controller,
        voiceBackends: voiceBackends,
        contactSelectionBackend: const _SelectedContactBackend(null),
      ),
    );

    expect(await tester.runAsync(controller.pickContact), isTrue);
    await tester.pump();

    expect(bridge.sources, isEmpty);
    expect(bridge.sessions, isEmpty);
    expect(
      find.byKey(const Key('image-attachment-upload-panel')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('named thread contact uses threadId without replyTo', (
    tester,
  ) async {
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final controller = ChatMediaComposerController();
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);

    await tester.pumpWidget(
      _threadComposerApp(
        sourceStore: sourceStore(),
        bridge: bridge.bridge,
        threadBinding: ChatMediaThreadBinding.named(
          accountId: _account,
          roomToken: _room,
          rootMessageId: 77,
        ),
        controller: controller,
        voiceBackends: voiceBackends,
        contactSelectionBackend: _SelectedContactBackend(
          ContactSelection(displayName: 'Alice Example', vcard: _contactVCard),
        ),
      ),
    );

    expect(await tester.runAsync(controller.pickContact), isTrue);
    expect(await tester.runAsync(controller.sendPreparedAttachment), isTrue);

    expect(bridge.metadata.single.kind, AttachmentMessageKind.file);
    expect(bridge.metadata.single.replyTo, isNull);
    expect(bridge.metadata.single.threadId, 77);
  });

  testWidgets('contact permission denial is localized and never queues', (
    tester,
  ) async {
    final bridge = _RecordingBridge();
    addTearDown(bridge.close);
    final controller = ChatMediaComposerController();
    final voiceBackends = _VoiceBackendFactory();
    addTearDown(voiceBackends.close);

    await tester.pumpWidget(
      _composerApp(
        sourceStore: sourceStore(),
        bridge: bridge.bridge,
        threadId: null,
        controller: controller,
        voiceBackends: voiceBackends,
        locale: const Locale('cs'),
        contactSelectionBackend: const _FailingContactBackend(
          ContactPickerFailure.permissionDenied,
        ),
      ),
    );

    expect(await tester.runAsync(controller.pickContact), isTrue);
    await tester.pump();

    expect(bridge.sessions, isEmpty);
    expect(
      find.text('Přístup k vybranému kontaktu byl odepřen.'),
      findsOneWidget,
    );
  });
}

final class _FailingContactBackend implements ContactSelectionBackend {
  const _FailingContactBackend(this.failure);

  final ContactPickerFailure failure;

  @override
  Future<ContactSelection?> selectContact() =>
      Future<ContactSelection?>.error(ContactPickerException(failure));
}

final class _SelectedContactBackend implements ContactSelectionBackend {
  const _SelectedContactBackend(this.selection);

  final ContactSelection? selection;

  @override
  Future<ContactSelection?> selectContact() async => selection;
}

final Uint8List _contactVCard = Uint8List.fromList(
  'BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Alice Example\r\nEND:VCARD\r\n'.codeUnits,
);
