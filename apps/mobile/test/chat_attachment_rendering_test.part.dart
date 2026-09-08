part of 'chat_room_pane_test.dart';

void _registerChatAttachmentRenderingTests() {
  testWidgets('an image bubble keeps the box Talk declared before and after '
      'the preview lands', (tester) async {
    final decodedPreview = await _solidPreview(tester, 300, 600);
    final thumbnail = Completer<ChatMediaImage?>();
    addTearDown(() {
      if (!thumbnail.isCompleted) {
        thumbnail.complete(null);
      }
    });
    final message = _attachmentMessage(
      id: 32,
      fileId: 90,
      name: 'tall.png',
      mimeType: 'image/png',
      previewAvailable: 'yes',
      link: '/index.php/f/90',
      extra: const <String, Object?>{'width': '600', 'height': '1200'},
    );
    await tester.pumpWidget(
      app(
        home: Scaffold(
          body: ChatMessageContent(
            account: account,
            message: message,
            fallbackText: '',
            foregroundColor: Colors.black,
          ),
        ),
        overrides: [
          chatMediaProvider.overrideWith((ref, key) => thumbnail.future),
        ],
      ),
    );
    await tester.pump();

    // 600x1200 scaled into the 420x320 bound keeps its proportions.
    final loading = find.byKey(const Key('chat-image-loading-32-0'));
    expect(tester.getSize(loading), const Size(160, 320));

    thumbnail.complete(decodedPreview);
    await tester.pump();
    await _pumpUntil(tester, () => loading.evaluate().isEmpty);

    // The downscaled preview preserves the declared aspect ratio.
    expect(
      tester.getSize(find.byKey(const Key('chat-image-32-0'))),
      const Size(160, 320),
    );
  });

  testWidgets('image attachment uses one surface while thumbnail is loading', (
    tester,
  ) async {
    final thumbnail = Completer<ChatMediaImage?>();
    addTearDown(() {
      if (!thumbnail.isCompleted) {
        thumbnail.complete(null);
      }
    });
    final message = _attachmentMessage(
      id: 30,
      fileId: 88,
      name: 'pending.gif',
      mimeType: 'image/gif',
      previewAvailable: 'yes',
      link: '/index.php/f/88',
    );
    final mediaOverride = chatMediaProvider.overrideWith(
      (ref, key) => thumbnail.future,
    );
    late Uri openedPreview;
    vault.values[account.id] = 'fixture-viewer-password';
    final viewerRepository = ChatMediaRepository(
      vault,
      client: MockClient((request) async {
        openedPreview = request.url;
        return http.Response.bytes(
          base64Decode(_onePixelGif),
          200,
          headers: const <String, String>{'content-type': 'image/gif'},
        );
      }),
    );
    addTearDown(viewerRepository.close);

    await tester.pumpWidget(
      app(
        home: Scaffold(
          body: ChatMessageContent(
            account: account,
            message: message,
            fallbackText: '',
            foregroundColor: Colors.black,
          ),
        ),
        overrides: [
          mediaOverride,
          chatMediaRepositoryProvider.overrideWithValue(viewerRepository),
        ],
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('chat-image-loading-30-0')), findsOneWidget);
    expect(find.byKey(const Key('chat-open-attachment-30-0')), findsNothing);
    thumbnail.complete(
      ChatMediaImage(
        body: base64Decode(_onePixelGif),
        contentType: 'image/gif',
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('chat-image-loading-30-0')), findsOneWidget);
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('chat-image-loading-30-0')).evaluate().isEmpty,
    );

    expect(find.byKey(const Key('chat-image-loading-30-0')), findsNothing);
    final openImage = find.byKey(const Key('chat-open-image-30-0'));
    expect(openImage, findsOneWidget);
    await tester.tap(openImage);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const Key('authenticated-image-viewer')), findsOneWidget);
    expect(openedPreview.queryParameters['fileId'], '88');
    expect(openedPreview.queryParameters['x'], '2048');
    expect(openedPreview.queryParameters['y'], '2048');
    expect(openedPreview.queryParameters['a'], '1');
  });

  testWidgets('failed image thumbnail retries and keeps internal viewer', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('chat-preview-viewer-');
    addTearDown(() => root.deleteSync(recursive: true));
    final disk = ChatMediaDiskCache(rootDirectory: () async => root);
    var thumbnailAttempts = 0;
    final message = _attachmentMessage(
      id: 31,
      fileId: 89,
      name: 'retry.gif',
      mimeType: 'image/gif',
      previewAvailable: 'yes',
      link: '/index.php/f/89',
    );
    final mediaOverride = chatMediaProvider.overrideWith((ref, key) async {
      thumbnailAttempts++;
      if (thumbnailAttempts == 1) {
        throw StateError('synthetic preview failure');
      }
      return ChatMediaImage(
        body: base64Decode(_onePixelGif),
        contentType: 'image/gif',
      );
    });
    vault.values[account.id] = 'fixture-viewer-password';
    final viewerRepository = ChatMediaRepository(
      vault,
      client: MockClient((request) async {
        return http.Response.bytes(
          base64Decode(_onePixelGif),
          200,
          headers: const <String, String>{'content-type': 'image/gif'},
        );
      }),
    );
    addTearDown(viewerRepository.close);

    await tester.pumpWidget(
      app(
        home: Scaffold(
          body: ChatMessageContent(
            account: account,
            message: message,
            fallbackText: '',
            foregroundColor: Colors.black,
          ),
        ),
        overrides: [
          mediaOverride,
          chatMediaDiskCacheProvider.overrideWithValue(disk),
          chatMediaRepositoryProvider.overrideWithValue(viewerRepository),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('chat-image-error-31-0')), findsOneWidget);
    expect(thumbnailAttempts, 1);
    expect(find.byKey(const Key('chat-open-attachment-31-0')), findsNothing);

    await tester.tap(find.byKey(const Key('chat-image-retry-31-0')));
    await _pumpUntil(
      tester,
      () =>
          thumbnailAttempts == 2 &&
          find.byKey(const Key('chat-image-loading-31-0')).evaluate().isEmpty,
    );

    expect(thumbnailAttempts, 2);
    expect(find.byKey(const Key('chat-image-31-0')), findsOneWidget);
    expect(find.byKey(const Key('chat-open-attachment-31-0')), findsNothing);
    final openImage = find.byKey(const Key('chat-open-image-31-0'));
    expect(openImage, findsOneWidget);
    await tester.tap(openImage);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('authenticated-image-viewer')), findsOneWidget);
  });

  testWidgets('generic attachments download authenticated originals', (
    tester,
  ) async {
    final opener = _RecordingAttachmentOpenAction();
    final document = _attachmentMessage(
      id: 32,
      fileId: 90,
      name: 'report.pdf',
      mimeType: 'application/pdf',
      previewAvailable: 'yes',
      link: '/remote.php/dav/files/fixture-user/report.pdf',
    );
    final previewDisabledImage = _attachmentMessage(
      id: 33,
      fileId: 91,
      name: 'disabled.gif',
      mimeType: 'image/gif',
      previewAvailable: 'no',
      link: '/index.php/f/91',
    );

    await tester.pumpWidget(
      app(
        home: Scaffold(
          body: Flex(
            direction: Axis.vertical,
            children: [
              ChatMessageContent(
                account: account,
                message: document,
                fallbackText: '',
                foregroundColor: Colors.black,
              ),
              ChatMessageContent(
                account: account,
                message: previewDisabledImage,
                fallbackText: '',
                foregroundColor: Colors.black,
              ),
            ],
          ),
        ),
        overrides: [
          chatAttachmentOpenActionFactoryProvider.overrideWithValue(
            (_) => opener,
          ),
        ],
      ),
    );
    await tester.pump();

    for (final messageId in const [32, 33]) {
      final row = find.byKey(Key('chat-open-attachment-$messageId-0'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(
          of: row,
          matching: find.byIcon(Icons.open_in_new_rounded),
        ),
        findsOneWidget,
      );
      await tester.tap(row);
      await tester.pump();
    }
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));

    expect(opener.uris, <Uri>[
      Uri.parse(
        'https://cloud.example.invalid/remote.php/dav/files/'
        'fixture-user/Talk/report.pdf',
      ),
      Uri.parse(
        'https://cloud.example.invalid/remote.php/dav/files/'
        'fixture-user/Talk/disabled.gif',
      ),
    ]);
    expect(opener.contentTypes, ['application/pdf', 'image/gif']);
    expect(find.byKey(const Key('authenticated-image-viewer')), findsNothing);
  });

  testWidgets('unsafe DAV paths do not expose an attachment action', (
    tester,
  ) async {
    final opener = _RecordingAttachmentOpenAction();
    final message = _attachmentMessage(
      id: 34,
      fileId: 92,
      name: 'unsafe.txt',
      mimeType: 'text/plain',
      previewAvailable: 'no',
      link: '/index.php/f/92',
      path: 'Talk/../unsafe.txt',
    );

    await tester.pumpWidget(
      app(
        home: Scaffold(
          body: ChatMessageContent(
            account: account,
            message: message,
            fallbackText: '',
            foregroundColor: Colors.black,
          ),
        ),
        overrides: [
          chatAttachmentOpenActionFactoryProvider.overrideWithValue(
            (_) => opener,
          ),
        ],
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('chat-open-attachment-34-0')), findsNothing);
    expect(opener.uris, isEmpty);
  });
}
