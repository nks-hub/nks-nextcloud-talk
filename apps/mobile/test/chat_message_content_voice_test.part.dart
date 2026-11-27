part of 'chat_message_content_test.dart';

void _registerVoicePlaybackTests() {
  testWidgets('a voice message exposes its length, position and seeking', (
    tester,
  ) async {
    final backend = _FakePlaybackBackend();
    addTearDown(backend.dispose);

    await tester.pumpWidget(
      _voiceApp(
        backend,
        const ChatVoiceFile(path: 'a.m4a', contentType: 'audio/mp4'),
      ),
    );

    expect(find.byKey(const Key('chat-voice-44')), findsOneWidget);
    expect(find.byKey(const Key('chat-voice-position-44')), findsNothing);

    await tester.tap(find.byKey(const Key('chat-voice-toggle-44')));
    await tester.pump();
    await tester.pump();
    expect(backend.playedPaths, hasLength(1));

    backend
      ..emitDuration(const Duration(seconds: 72))
      ..emitPosition(const Duration(seconds: 9));
    await tester.pump();

    expect(find.text('0:09 of 1:12'), findsOneWidget);
    final slider = tester.widget<Slider>(
      find.byKey(const Key('chat-voice-position-44')),
    );
    expect(slider.value, 9000);
    expect(slider.max, 72000);

    slider.onChanged!(30000);
    await tester.pump();
    expect(find.text('0:30 of 1:12'), findsOneWidget);
    slider.onChangeEnd!(30000);
    await tester.pump();
    expect(backend.seeks, <Duration>[const Duration(seconds: 30)]);

    await tester.tap(find.byKey(const Key('chat-voice-toggle-44')));
    await tester.pump();
    expect(backend.pauses, 1);

    await tester.tap(find.byKey(const Key('chat-voice-toggle-44')));
    await tester.pump();
    expect(backend.resumes, 1);
    expect(backend.playedPaths, hasLength(1));
  });

  testWidgets(
    'desktop voice captions, file actions and playback share a compact layout',
    (tester) async {
      final backend = _FakePlaybackBackend();
      addTearDown(backend.dispose);
      const file = ChatVoiceFile(path: 'a.m4a', contentType: 'audio/mp4');
      final name = _voiceMessage.messageParameters['file']!.name!;
      Future<void> pump(ChatMessage message, {bool showAttachments = true}) =>
          tester.pumpWidget(
            _voiceApp(
              backend,
              file,
              width: 560,
              message: message,
              showAttachments: showAttachments,
            ),
          );

      // The original file link remains usable and its title is displayed once.
      await pump(_voiceMessage);
      expect(find.byKey(const Key('open-rich-object-file')), findsOneWidget);
      expect(find.text(name), findsOneWidget);
      final player = find.byKey(const Key('chat-voice-44'));
      final play = find.byKey(const Key('chat-voice-toggle-44'));
      final progress = find.byKey(const Key('chat-voice-progress-44'));
      expect(tester.getSize(player).width, lessThan(400));
      expect(
        tester.getCenter(play).dy,
        closeTo(tester.getCenter(progress).dy, 0.5),
      );

      await tester.tap(play);
      await tester.pump();
      backend.emitDuration(const Duration(seconds: 69));
      await tester.pump();
      final seek = find.byKey(const Key('chat-voice-position-44'));
      expect(
        tester.getCenter(play).dy,
        closeTo(tester.getCenter(seek).dy, 0.5),
      );
      expect(
        tester.getCenter(play).dy,
        closeTo(tester.getCenter(progress).dy, 0.5),
      );
      await tester.tapAt(tester.getCenter(seek));
      await tester.pump();
      expect(backend.seeks.single.inSeconds, closeTo(34, 1));

      final caption = ChatMessage.fromJson({
        ..._voiceMessage.wire,
        'message': 'Listen again. {file}',
        'messageParameters': {
          'file': {..._voiceMessage.messageParameters['file']!.wire}
            ..remove('link'),
        },
      });
      await pump(caption);
      expect(find.text('Listen again.', findRichText: true), findsOneWidget);
      expect(find.text(name), findsOneWidget);
      expect(find.byIcon(Icons.attachment_rounded), findsNothing);

      await pump(caption, showAttachments: false);
      expect(player, findsNothing);
      expect(find.text(name), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
