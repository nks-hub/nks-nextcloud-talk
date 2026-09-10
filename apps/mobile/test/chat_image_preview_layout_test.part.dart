part of 'chat_room_pane_test.dart';

// 80x160 stored JPEG pixels, EXIF orientation 6: display is 160x80.
const _orientationSixJpeg =
    '/9j/4AAQSkZJRgABAQAAAQABAAD/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAAABAAYAAAAAAAD/2wBD'
    'AAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8lJCIfIiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8'
    'SDc9Pjv/2wBDAQoLCw4NDhwQEBw7KCIoOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7'
    'Ozs7Ozs7Ozs7Ozs7Ozv/wAARCACgAFADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQF'
    'BgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAk'
    'M2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWG'
    'h4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx'
    '8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQA'
    'AQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5'
    'OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmq'
    'srO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDn'
    'KKKK+mPFCiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAoo'
    'ooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAoo'
    'ooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAoo'
    'ooAKKKKACiiigAooooAKKKKACiiigD//2Q==';

Future<ChatMediaImage> _solidPreview(
  WidgetTester tester,
  int width,
  int height,
) async => (await tester.runAsync(() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = Colors.indigo,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return ChatMediaImage(
      body: bytes!.buffer.asUint8List(),
      contentType: 'image/png',
    );
  } finally {
    image.dispose();
    picture.dispose();
  }
}))!;

Future<void> _showImageContent(
  WidgetTester tester,
  Map<String, Object?> wire, {
  Future<ChatMediaImage?>? image,
  double maxWidth = 620,
  List<Override> overrides = const [],
}) async {
  await tester.pumpWidget(
    app(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: ChatMessageContent(
                account: account,
                message: ChatMessage.fromJson(wire),
                fallbackText: '',
                foregroundColor: Colors.black,
              ),
            ),
          ),
        ),
      ),
      overrides: [
        ...overrides,
        if (image != null) chatMediaProvider.overrideWith((ref, key) => image),
      ],
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  await tester.pump();
}

void _registerChatImagePreviewLayoutTests() {
  testWidgets(
    'retry waits for a disposed preview load before evicting its bytes',
    (tester) async {
      final good = await _solidPreview(tester, 808, 121);
      final bad = ChatMediaImage(
        body: base64Decode('iVBORw0KGgo='),
        contentType: 'image/png',
      );
      final root = Directory.systemTemp.createTempSync('chat-preview-pending-');
      addTearDown(() => root.deleteSync(recursive: true));
      final memory = ChatMediaCache();
      final disk = ChatMediaDiskCache(rootDirectory: () async => root);
      final uri = Uri.parse(
        '${account.serverUrl}/index.php/core/preview?fileId=89&x=1024&y=1024&a=1',
      );
      final key = ChatMediaCache.keyOf(accountId: account.id, uri: uri);
      final first = Completer<http.Response>();
      addTearDown(() {
        if (!first.isCompleted) first.complete(http.Response('', 500));
      });
      var requests = 0;
      final requestUris = <Uri>[];
      vault.values[account.id] = 'fixture-preview-password';
      final repository = ChatMediaRepository(
        vault,
        client: MockClient((request) {
          requestUris.add(request.url);
          requests++;
          return requests == 1
              ? first.future
              : Future.value(
                  http.Response.bytes(
                    good.body,
                    200,
                    headers: {'content-type': 'image/png'},
                  ),
                );
        }),
      );
      addTearDown(repository.close);
      await _showImageContent(
        tester,
        _layoutImageWire(89),
        overrides: [
          chatMediaCacheProvider.overrideWithValue(memory),
          chatMediaDiskCacheProvider.overrideWithValue(disk),
          chatMediaRepositoryProvider.overrideWithValue(repository),
        ],
      );
      await _pumpUntil(tester, () => requests == 1);
      memory.write(key, bad);
      final content = find.byType(ChatMessageContent);
      final container = ProviderScope.containerOf(tester.element(content));
      container.invalidate(
        chatMediaProvider(ChatMediaProviderKey(account: account, uri: uri)),
      );
      tester.element(content).markNeedsBuild();
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('chat-image-error-89-0'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.byKey(const Key('chat-image-retry-89-0')));
      await tester.pump();
      expect(requests, 1);
      first.complete(
        http.Response.bytes(
          bad.body,
          200,
          headers: {'content-type': 'image/png'},
        ),
      );
      await _pumpUntil(tester, () => requests >= 2);
      expect(requests, 2);
      await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('chat-image-loading-89-0')).evaluate().isEmpty,
      );
      expect(find.byKey(const Key('chat-image-error-89-0')), findsNothing);
      expect(memory.read(key)!.body, good.body);
      final persisted = await tester.runAsync(
        () => disk.read(accountId: account.id, uri: uri),
      );
      expect(persisted!.body, good.body);
      expect(requests, 2);
      expect(requestUris, [uri, uri]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a warm preview uses remembered dimensions in its first layout', (
    tester,
  ) async {
    final preview = await _solidPreview(tester, 808, 121);
    final wire = _layoutImageWire(86);
    final file = (wire['messageParameters'] as Map)['file'] as Map;
    file.remove('width');
    file.remove('height');
    await _showImageContent(tester, wire, image: Future.value(preview));
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('chat-image-loading-86-0')).evaluate().isEmpty,
    );
    final firstSize = tester.getSize(find.byKey(const Key('chat-image-86-0')));
    expect(preview.decodedDimensions, (width: 808, height: 121));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    final cache = ChatMediaCache();
    cache.write(
      ChatMediaCache.keyOf(
        accountId: account.id,
        uri: Uri.parse(
          '${account.serverUrl}/index.php/core/preview?fileId=86&x=1024&y=1024&a=1',
        ),
      ),
      preview,
    );
    final pending = Completer<ChatMediaImage?>();
    addTearDown(() {
      if (!pending.isCompleted) pending.complete(null);
    });
    await _showImageContent(
      tester,
      wire,
      image: pending.future,
      overrides: [chatMediaCacheProvider.overrideWithValue(cache)],
    );
    expect(pending.isCompleted, isFalse);
    expect(tester.getSize(find.byKey(const Key('chat-image-86-0'))), firstSize);
  });

  testWidgets('a changed etag selects a fresh preview and its own dimensions', (
    tester,
  ) async {
    final portrait = await _solidPreview(tester, 160, 320);
    final landscape = await _solidPreview(tester, 320, 160);
    ChatMessage message(String version) {
      final wire = _layoutImageWire(87);
      final file = (wire['messageParameters'] as Map)['file'] as Map;
      file['width'] = 160;
      file['height'] = 320;
      file['etag'] = version;
      return ChatMessage.fromJson(wire);
    }

    final selected = ValueNotifier(message('v1'));
    addTearDown(selected.dispose);
    final versions = <String?>[];
    await tester.pumpWidget(
      app(
        home: Scaffold(
          body: ValueListenableBuilder<ChatMessage>(
            valueListenable: selected,
            builder: (_, value, _) => ChatMessageContent(
              account: account,
              message: value,
              fallbackText: '',
              foregroundColor: Colors.black,
            ),
          ),
        ),
        overrides: [
          chatMediaProvider.overrideWith((ref, key) async {
            final version = key.uri.queryParameters['c'];
            versions.add(version);
            return version == 'v1' ? portrait : landscape;
          }),
        ],
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pump();
    await _pumpUntil(
      tester,
      () =>
          find.byKey(const Key('chat-image-87-0')).evaluate().isNotEmpty &&
          find.byKey(const Key('chat-image-loading-87-0')).evaluate().isEmpty,
    );
    expect(
      tester.getSize(find.byKey(const Key('chat-image-87-0'))),
      const Size(160, 320),
    );
    selected.value = message('v2');
    await tester.pump();
    await _pumpUntil(
      tester,
      () =>
          versions.contains('v2') &&
          find.byKey(const Key('chat-image-loading-87-0')).evaluate().isEmpty,
    );
    expect(
      tester.getSize(find.byKey(const Key('chat-image-87-0'))),
      const Size(320, 160),
    );
    expect(versions, ['v1', 'v2']);
  });

  testWidgets('a narrow error preview keeps a usable retry without overflow', (
    tester,
  ) async {
    await _showImageContent(
      tester,
      _layoutImageWire(88, width: 100, height: 800),
      image: Future.value(null),
      maxWidth: 72,
    );
    await _pumpUntil(
      tester,
      () =>
          find.byKey(const Key('chat-image-error-88-0')).evaluate().isNotEmpty,
    );
    final retry = tester.getSize(
      find.byKey(const Key('chat-image-retry-88-0')),
    );
    expect(retry.width, greaterThanOrEqualTo(48));
    expect(retry.height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'EXIF rotation uses the dimensions returned by the image decoder',
    (tester) async {
      final preview = ChatMediaImage(
        body: base64Decode(_orientationSixJpeg),
        contentType: 'image/jpeg',
      );
      final wire = _layoutImageWire(83);
      final file = (wire['messageParameters'] as Map)['file'] as Map;
      file.remove('width');
      file.remove('height');
      file['mimetype'] = 'image/jpeg';
      await _showImageContent(tester, wire, image: Future.value(preview));
      await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('chat-image-loading-83-0')).evaluate().isEmpty,
      );
      expect(
        tester.getSize(find.byKey(const Key('chat-image-83-0'))),
        const Size(160, 80),
      );
      expect(preview.decodedDimensions, (width: 160, height: 80));
    },
  );

  testWidgets('an invalid image dimension falls back to the decoded preview', (
    tester,
  ) async {
    final preview = await _solidPreview(tester, 120, 240);
    final wire = _layoutImageWire(84);
    final file = (wire['messageParameters'] as Map)['file'] as Map;
    file['width'] = 'NaN';
    file['height'] = -1;
    await _showImageContent(tester, wire, image: Future.value(preview));
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('chat-image-loading-84-0')).evaluate().isEmpty,
    );
    expect(
      tester.getSize(find.byKey(const Key('chat-image-84-0'))),
      const Size(120, 240),
    );
  });

  testWidgets(
    'a corrupt cached preview is evicted before its retry reaches the network',
    (tester) async {
      final good = await _solidPreview(tester, 808, 121);
      final bad = ChatMediaImage(
        body: base64Decode('iVBORw0KGgo='),
        contentType: 'image/png',
      );
      final root = Directory.systemTemp.createTempSync('chat-preview-retry-');
      addTearDown(() => root.deleteSync(recursive: true));
      final memory = ChatMediaCache();
      final disk = ChatMediaDiskCache(rootDirectory: () async => root);
      final uri = Uri.parse(
        '${account.serverUrl}/index.php/core/preview?fileId=85&x=1024&y=1024&a=1&c=v1',
      );
      final cacheKey = ChatMediaCache.keyOf(accountId: account.id, uri: uri);
      memory.write(cacheKey, bad);
      await tester.runAsync(() async {
        await disk.write(accountId: account.id, uri: uri, image: bad);
        await disk.write(accountId: 'account-b', uri: uri, image: good);
      });
      var requests = 0;
      final requestUris = <Uri>[];
      vault.values[account.id] = 'fixture-preview-password';
      final repository = ChatMediaRepository(
        vault,
        client: MockClient((request) async {
          requests++;
          requestUris.add(request.url);
          return http.Response.bytes(
            good.body,
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      );
      addTearDown(repository.close);
      final wire = _layoutImageWire(85);
      ((wire['messageParameters'] as Map)['file'] as Map)['etag'] = 'v1';
      await _showImageContent(
        tester,
        wire,
        overrides: [
          chatMediaCacheProvider.overrideWithValue(memory),
          chatMediaDiskCacheProvider.overrideWithValue(disk),
          chatMediaRepositoryProvider.overrideWithValue(repository),
        ],
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('chat-image-error-85-0'))
            .evaluate()
            .isNotEmpty,
      );
      expect(requests, 0);
      await tester.tap(find.byKey(const Key('chat-image-retry-85-0')));
      await _pumpUntil(
        tester,
        () =>
            requests == 1 &&
            find.byKey(const Key('chat-image-error-85-0')).evaluate().isEmpty &&
            find.byKey(const Key('chat-image-loading-85-0')).evaluate().isEmpty,
      );
      expect(memory.read(cacheKey)?.body, good.body);
      expect(requestUris, [uri]);
      final restored = await tester.runAsync(
        () async => (
          (await disk.read(accountId: account.id, uri: uri))?.body,
          (await disk.read(accountId: 'account-b', uri: uri))?.body,
        ),
      );
      expect(restored!.$1, good.body);
      expect(restored.$2, good.body);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('missing image metadata uses decoded preview dimensions', (
    tester,
  ) async {
    // The surface is pinned because the assertion below is an absolute width.
    // Run on a real phone this test used to fail at 392.7 instead of 420 —
    // the bubble was correctly obeying a 411 dp screen, and only the test
    // believed everything is 800 dp wide.
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final preview = await _solidPreview(tester, 808, 121);
    final wire = _layoutImageWire(80);
    final file = (wire['messageParameters'] as Map)['file'] as Map;
    file.remove('width');
    file.remove('height');
    await _showImageContent(tester, wire, image: Future.value(preview));
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('chat-image-loading-80-0')).evaluate().isEmpty,
    );
    final size = tester.getSize(find.byKey(const Key('chat-image-80-0')));
    expect(size.width, 420);
    expect(size.height, closeTo(420 * 121 / 808, 0.01));
  });

  testWidgets('narrow constraints scale declared image height with its width', (
    tester,
  ) async {
    final preview = Completer<ChatMediaImage?>();
    addTearDown(() {
      if (!preview.isCompleted) preview.complete(null);
    });
    await _showImageContent(
      tester,
      _layoutImageWire(81, width: 800, height: 400),
      image: preview.future,
      maxWidth: 260,
    );
    expect(
      tester.getSize(find.byKey(const Key('chat-image-loading-81-0'))),
      const Size(260, 130),
    );
  });

  for (final caption in [false, true]) {
    testWidgets(
      '${caption ? 'captioned' : 'image-only'} message shows one bounded filename below the image',
      (tester) async {
        final preview = await _solidPreview(tester, 640, 320);
        final wire = _layoutImageWire(82, width: 640, height: 320);
        if (caption) wire['message'] = 'A caption';
        const name =
            'a-very-long-image-filename-that-must-not-widen-the-bubble.png';
        ((wire['messageParameters'] as Map)['file'] as Map)['name'] = name;
        await _showImageContent(tester, wire, image: Future.value(preview));
        await _pumpUntil(
          tester,
          () => find
              .byKey(const Key('chat-image-loading-82-0'))
              .evaluate()
              .isEmpty,
        );
        final filename = find.byKey(const Key('chat-image-name-82-0'));
        expect(filename, findsOneWidget);
        expect(find.text(name, findRichText: true), findsOneWidget);
        final imageRect = tester.getRect(
          find.byKey(const Key('chat-image-82-0')),
        );
        expect(
          tester.getRect(filename).top,
          greaterThanOrEqualTo(imageRect.bottom),
        );
        expect(
          tester.getSize(find.byKey(const Key('chat-rich-content-82'))).width,
          imageRect.width,
        );
        if (!caption) {
          expect(
            imageRect.top,
            tester.getRect(find.byKey(const Key('chat-rich-content-82'))).top,
          );
        }
      },
    );
  }
}
