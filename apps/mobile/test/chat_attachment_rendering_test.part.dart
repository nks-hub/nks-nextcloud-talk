part of 'chat_room_pane_test.dart';

void _registerChatAttachmentRenderingTests() {
  testWidgets('received image menu offers copying the image and its text', (
    tester,
  ) async {
    final preview = await _solidPreview(tester, 120, 80);
    await _insertCachedMessage(
      database,
      _layoutImageWire(100, width: 120, height: 80),
      displayText: 'Photo',
    );
    await tester.pumpWidget(
      app(
        home: roomScreen(),
        overrides: [
          chatMediaProvider.overrideWith((ref, key) async => preview),
        ],
      ),
    );
    await _pumpUntil(
      tester,
      () =>
          find
              .byKey(const Key('chat-image-100-0'))
              .hitTestable()
              .evaluate()
              .isNotEmpty &&
          find.byKey(const Key('chat-image-loading-100-0')).evaluate().isEmpty,
    );
    await tester.tap(
      find.byKey(const Key('chat-image-100-0')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('message-action-copy-image')), findsOneWidget);
    expect(find.byKey(const Key('message-action-copy')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a touch platform keeps the sheet for a picture, even on a '
      'mouse right click', (tester) async {
    final preview = await _solidPreview(tester, 120, 80);
    await _insertCachedMessage(
      database,
      _layoutImageWire(100, width: 120, height: 80),
      displayText: 'Photo',
    );
    await tester.pumpWidget(
      app(
        home: roomScreen(),
        overrides: [
          chatMediaProvider.overrideWith((ref, key) async => preview),
        ],
      ),
    );
    final image = find.byKey(const Key('chat-image-100-0'));
    await _pumpUntil(
      tester,
      () =>
          image.hitTestable().evaluate().isNotEmpty &&
          find.byKey(const Key('chat-image-loading-100-0')).evaluate().isEmpty,
    );
    for (final open in <Future<void> Function()>[
      () => tester.longPress(image),
      () => _rightClick(tester, tester.getCenter(image)),
    ]) {
      await open();
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(PopupMenuDivider), findsNothing);
      expect(
        find.byKey(const Key('message-action-copy-image')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('message-action-save-image')), findsNothing);
      expect(find.byKey(const Key('message-action-open-image')), findsNothing);
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }, variant: TargetPlatformVariant.mobile());

  testWidgets('a right click on a picture on desktop leads with the picture '
      'commands and runs the existing actions', (tester) async {
    final preview = await _solidPreview(tester, 120, 80);
    await _insertCachedMessage(
      database,
      _layoutImageWire(100, width: 120, height: 80),
      displayText: 'Photo',
    );
    final fakes = _PictureMenuFakes(preview.body);
    await tester.pumpWidget(
      app(
        home: roomScreen(),
        overrides: [
          chatMediaProvider.overrideWith((ref, key) async => preview),
          ...fakes.overrides,
          chatMessageActionsProfileProvider.overrideWith(
            (ref, key) async => _capabilityProfile(reply: true),
          ),
        ],
      ),
    );
    final image = find.byKey(const Key('chat-image-100-0'));
    await _pumpUntil(
      tester,
      () =>
          image.hitTestable().evaluate().isNotEmpty &&
          find.byKey(const Key('chat-image-loading-100-0')).evaluate().isEmpty,
    );
    Finder action(String name) => find.byKey(Key('message-action-$name'));
    // Linux has no image clipboard: neither the picture nor the message
    // offers a copy there.
    final copies = imageClipboardSupported;
    void dropSnackBar() =>
        ScaffoldMessenger.of(tester.element(image)).removeCurrentSnackBar();

    await _rightClick(tester, tester.getCenter(image));
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(PopupMenuDivider), findsOneWidget);
    final order = [
      if (copies) 'copy-image',
      'save-image',
      'open-image',
      'open-file',
      'forward',
      'reply',
    ];
    for (final name in order) {
      expect(action(name), findsOneWidget, reason: name);
    }
    for (var index = 1; index < order.length; index++) {
      expect(
        tester.getTopLeft(action(order[index - 1])).dy,
        lessThan(tester.getTopLeft(action(order[index])).dy),
        reason: '${order[index - 1]} comes before ${order[index]}',
      );
    }

    if (copies) {
      await tester.tap(action('copy-image'));
      await _pumpUntil(tester, () => fakes.clipboard.copied.isNotEmpty);
      expect(fakes.requested.single.path, endsWith('/Talk/image.png'));
      expect(fakes.clipboard.copied.single, preview.body);
      await tester.pumpAndSettle();
      expect(find.text('Image copied to clipboard.'), findsOneWidget);
      dropSnackBar();
    } else {
      expect(action('copy-image'), findsNothing);
      await tester.tapAt(Offset.zero);
    }
    await tester.pumpAndSettle();

    await _rightClick(tester, tester.getCenter(image));
    await tester.tap(action('save-image'));
    await tester.pumpAndSettle();
    expect(fakes.files.saved, ['image.png']);
    expect(find.text('Attachment saved.'), findsOneWidget);
    dropSnackBar();
    await tester.pumpAndSettle();

    await _rightClick(tester, tester.getCenter(image));
    await tester.tap(action('open-file'));
    await tester.pumpAndSettle();
    expect(fakes.opener.uris.single.path, endsWith('/Talk/image.png'));
    expect(fakes.opener.contentTypes, ['image/png']);

    await _rightClick(tester, tester.getCenter(image));
    await tester.tap(action('open-image'));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('authenticated-image-close'))
          .hitTestable()
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(find.byKey(const Key('authenticated-image-close')));
    await _pumpUntil(tester, () => image.hitTestable().evaluate().isNotEmpty);

    // Anywhere else on the bubble the message's own menu is what it was.
    await _rightClick(
      tester,
      tester.getTopLeft(find.byKey(const Key('chat-message-target-100'))) +
          const Offset(4, 4),
    );
    expect(find.byType(PopupMenuDivider), findsNothing);
    expect(action('save-image'), findsNothing);
    expect(action('open-image'), findsNothing);
    expect(action('copy-image'), copies ? findsOneWidget : findsNothing);
    expect(
      tester.getTopLeft(action('reply')).dy,
      lessThan(tester.getTopLeft(action('forward')).dy),
      reason: 'forward stays among the message actions',
    );
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await _rightClick(tester, tester.getCenter(image));
    await tester.tap(action('forward'));
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('chat-forward-sheet')).evaluate().isNotEmpty,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('a picture that failed to load offers only its file on a right '
      'click', (tester) async {
    await _insertCachedMessage(
      database,
      _layoutImageWire(100, width: 120, height: 80),
      displayText: 'Photo',
    );
    final fakes = _PictureMenuFakes(Uint8List(0));
    await tester.pumpWidget(
      app(
        home: roomScreen(),
        overrides: [
          chatMediaProvider.overrideWith(
            (ref, key) async => throw const ChatMediaRepositoryException(
              ChatMediaRepositoryError.unavailable,
            ),
          ),
          ...fakes.overrides,
        ],
      ),
    );
    final failed = find.byKey(const Key('chat-image-error-100-0'));
    await _pumpUntil(tester, () => failed.hitTestable().evaluate().isNotEmpty);

    // Off the retry button in the middle of the placeholder.
    await _rightClick(tester, tester.getTopLeft(failed) + const Offset(4, 4));
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byKey(const Key('message-action-copy-image')), findsNothing);
    expect(find.byKey(const Key('message-action-open-image')), findsNothing);
    expect(find.byKey(const Key('message-action-open-file')), findsOneWidget);
    expect(find.byKey(const Key('message-action-forward')), findsOneWidget);
    await tester.tap(find.byKey(const Key('message-action-save-image')));
    await tester.pumpAndSettle();
    expect(fakes.files.saved, ['image.png']);
    expect(fakes.clipboard.copied, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

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

Future<void> _rightClick(WidgetTester tester, Offset position) async {
  final gesture = await tester.startGesture(
    position,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  // A real click holds the button past the tap deadline, which is when the
  // selection region used to open its own toolbar under the menu.
  await tester.pump(const Duration(milliseconds: 150));
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Stands in for everything a picture's menu commands reach outside the app:
/// the original's download, the clipboard, the save dialog and the opener.
final class _PictureMenuFakes {
  _PictureMenuFakes(Uint8List original) {
    vault.values[account.id] = 'fixture-password';
    media = ChatMediaRepository(
      vault,
      client: MockClient((request) async {
        requested.add(request.url);
        return http.Response.bytes(
          original,
          200,
          headers: const {'content-type': 'image/png'},
        );
      }),
      wait: (_) async {},
    );
    addTearDown(media.close);
  }

  final requested = <Uri>[];
  final clipboard = _RecordingImageExporter();
  final files = _RecordingAttachmentExportAction();
  final opener = _RecordingAttachmentOpenAction();
  late final ChatMediaRepository media;

  List<Override> get overrides => [
    chatMediaRepositoryProvider.overrideWithValue(media),
    chatImageExporterProvider.overrideWithValue(clipboard),
    chatAttachmentExportActionFactoryProvider.overrideWithValue((_) => files),
    chatAttachmentOpenActionFactoryProvider.overrideWithValue((_) => opener),
  ];
}

final class _RecordingImageExporter implements ChatImageExporter {
  final List<Uint8List> copied = [];

  @override
  Future<bool> copyToClipboard({required Uint8List bytes}) async {
    copied.add(bytes);
    return true;
  }

  @override
  Future<ChatImageSaveResult> saveToGallery({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async => ChatImageSaveResult.saved;

  @override
  Future<bool> share({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async => true;
}

final class _RecordingAttachmentExportAction
    implements ChatAttachmentExportAction {
  final List<String> saved = [];

  @override
  Future<ChatAttachmentSaveResult> save({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
    ChatDownloadProgress? onProgress,
  }) async {
    saved.add(fileName);
    return ChatAttachmentSaveResult.saved;
  }

  @override
  Future<ChatAttachmentShareResult> share({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
    ChatDownloadProgress? onProgress,
  }) async => ChatAttachmentShareResult.shared;
}
