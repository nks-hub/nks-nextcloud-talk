part of 'chat_room_pane_test.dart';

Map<String, Object?> _layoutImageWire(
  int id, {
  int width = 808,
  int height = 121,
  bool includeDimensions = true,
}) => _messageJson(
  id: id,
  actorId: 'other-user',
  actorDisplayName: 'Other user',
  timestamp: 1724300000 + id,
  message: '{file}',
  messageParameters: {
    'file': {
      'type': 'file',
      'id': '$id',
      'name': 'image.png',
      'path': 'Talk/image.png',
      'link': '/index.php/f/$id',
      'mimetype': 'image/png',
      'preview-available': 'yes',
      if (includeDimensions) 'width': width,
      if (includeDimensions) 'height': height,
    },
  },
);

Future<void> _cacheImageHistory(
  Set<int> imageIds, {
  bool dimensions = true,
}) async {
  for (var id = 101; id <= 130; id++) {
    final wire = imageIds.contains(id)
        ? _layoutImageWire(id, includeDimensions: dimensions)
        : _messageJson(
            id: id,
            actorId: 'other-user',
            actorDisplayName: 'Other user',
            timestamp: 1724300000 + id,
            message: 'History message $id',
          );
    await database
        .into(database.cachedChatMessages)
        .insert(
          CachedChatMessagesCompanion.insert(
            accountId: account.id,
            roomToken: conversation.token,
            messageId: id,
            actorType: 'users',
            actorId: 'other-user',
            actorDisplayName: 'Other user',
            timestamp: 1724300000 + id,
            systemMessage: '',
            messageType: 'comment',
            referenceId: 'reference-$id',
            displayText: 'History message $id',
            deleted: false,
            rawJson: jsonEncode(wire),
          ),
        );
  }
}

void _registerChatRoomPaneImageGeometryTests() {
  for (final imageCount in [1, 2]) {
    testWidgets(
      '$imageCount late image dimensions preserve the visible history position',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1000, 800);
        addTearDown(tester.view.reset);
        final imageIds = {123, if (imageCount == 2) 122};
        await _cacheImageHistory(imageIds);
        final preview = Completer<ChatMediaImage?>();
        addTearDown(() {
          if (!preview.isCompleted) preview.complete(null);
        });
        await tester.pumpWidget(
          app(
            home: roomScreen(),
            overrides: [
              chatMediaProvider.overrideWith((ref, key) => preview.future),
            ],
          ),
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 1));
        });
        await tester.pump();
        final listFinder = find.byKey(const Key('chat-message-list'));
        final controller = tester
            .widget<CustomScrollView>(listFinder)
            .controller!;
        final oldest = imageIds.reduce((a, b) => a < b ? a : b);
        // Scrolled until a row ABOVE the images is on screen, rather than to
        // a fixed offset: how much history fits above them depends on the
        // font the device draws with, and at 300 an emulator showed only the
        // images themselves.
        var viewport = Rect.zero;
        var visible = <(int, Rect)>[];
        for (var offset = 300.0; offset <= 1200; offset += 150) {
          controller.jumpTo(offset);
          await tester.pump();
          await tester.pump();
          viewport = tester.getRect(listFinder);
          visible = <(int, Rect)>[];
          for (var id = 101; id <= 130; id++) {
            final finder = find.byKey(Key('chat-message-target-$id'));
            if (finder.evaluate().isEmpty || imageIds.contains(id)) continue;
            final rect = tester.getRect(finder);
            if (rect.top > viewport.top + 8 &&
                rect.bottom < viewport.bottom - 8) {
              visible.add((id, rect));
            }
          }
          // Both have to hold: history above the images on screen, and the
          // images themselves still built — scrolling far enough to expose
          // the first can carry the second out of the tree.
          final imagesBuilt = imageIds.every(
            (id) => find
                .byKey(Key('chat-image-loading-$id-0'))
                .evaluate()
                .isNotEmpty,
          );
          if (visible.any((row) => row.$1 < oldest) && imagesBuilt) {
            break;
          }
        }
        visible.sort((a, b) => a.$2.top.compareTo(b.$2.top));
        // A row ABOVE everything that is about to grow. What the reading
        // anchor promises is that history does not slide out from under the
        // eye — a row BELOW the growing images has to move down by exactly
        // what they gain, and asserting it stays put asserts the opposite of
        // the design. `visible.first` was whichever row happened to be
        // topmost, which on one font landed above the images and on another
        // below them: the same code then passed on a phone and failed on an
        // emulator.
        final above = visible.where((row) => row.$1 < oldest).toList();
        expect(above, isNotEmpty, reason: 'nothing visible above the images');
        final anchor = above.first;
        for (final id in imageIds) {
          expect(find.byKey(Key('chat-image-loading-$id-0')), findsOneWidget);
          await (database.update(
            database.cachedChatMessages,
          )..where((row) => row.messageId.equals(id))).write(
            CachedChatMessagesCompanion(
              rawJson: Value(
                jsonEncode(_layoutImageWire(id, width: 200, height: 1600)),
              ),
            ),
          );
        }
        final container = ProviderScope.containerOf(tester.element(listFinder));
        await _pumpUntil(tester, () {
          final messages =
              container
                  .read(
                    chatMessagesProvider((
                      accountId: account.id,
                      roomToken: conversation.token,
                      threadId: null,
                    )),
                  )
                  .valueOrNull ??
              [];
          return imageIds.every(
            (id) => messages.any(
              (message) =>
                  message.messageId == id &&
                  ((jsonDecode(message.rawJson) as Map)['messageParameters']
                          as Map)['file']['height'] ==
                      1600,
            ),
          );
        });
        await tester.pump();
        expect(
          find.byKey(Key('chat-message-target-${anchor.$1}')),
          findsOneWidget,
        );
        expect(
          tester
              .getRect(find.byKey(Key('chat-message-target-${anchor.$1}')))
              .top,
          closeTo(anchor.$2.top, 0.5),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      },
    );
  }

  for (final dimensions in [(200, 1600), (808, 121)]) {
    testWidgets(
      'delayed ${dimensions.$1}x${dimensions.$2} preview decode preserves history every frame',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1000, 800);
        addTearDown(tester.view.reset);
        final image = await _solidPreview(tester, dimensions.$1, dimensions.$2);
        await _cacheImageHistory({123}, dimensions: false);
        final preview = Completer<ChatMediaImage?>();
        addTearDown(() {
          if (!preview.isCompleted) preview.complete(null);
        });
        await tester.pumpWidget(
          app(
            home: roomScreen(),
            overrides: [
              chatMediaProvider.overrideWith((ref, key) => preview.future),
            ],
          ),
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        });
        await tester.pump();
        final list = find.byKey(const Key('chat-message-list'));
        final controller = tester.widget<CustomScrollView>(list).controller!;
        // Scrolled until a row ABOVE the image is on screen: the reading
        // anchor promises that history above the growing content stays where
        // it is, while a row below it has to move down by what the image
        // gains. How much fits above depends on the device's font, so the
        // offset cannot be a constant.
        var viewport = Rect.zero;
        var visible = <(int, Rect)>[];
        Size? initialSize;
        for (var offset = 300.0; offset <= 1200; offset += 150) {
          controller.jumpTo(offset);
          await tester.pump();
          await tester.pump();
          final loading = find.byKey(const Key('chat-image-loading-123-0'));
          expect(loading, findsOneWidget);
          initialSize = tester.getSize(loading);
          viewport = tester.getRect(list);
          visible = <(int, Rect)>[];
          for (var id = 101; id <= 130; id++) {
            final finder = find.byKey(Key('chat-message-target-$id'));
            if (finder.evaluate().isEmpty || id == 123) continue;
            final rect = tester.getRect(finder);
            if (rect.top > viewport.top + 8 &&
                rect.bottom < viewport.bottom - 8) {
              visible.add((id, rect));
            }
          }
          if (visible.any((row) => row.$1 < 123)) {
            break;
          }
        }
        visible = visible.where((row) => row.$1 < 123).toList();
        visible.sort((a, b) => a.$2.top.compareTo(b.$2.top));
        expect(visible, isNotEmpty, reason: 'nothing visible above the image');
        final anchor = visible.first;
        preview.complete(image);
        var decoded = false;
        for (var frame = 0; frame < 100; frame++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump(const Duration(milliseconds: 16));
          final target = find.byKey(Key('chat-message-target-${anchor.$1}'));
          expect(target, findsOneWidget);
          expect(
            tester.getRect(target).top,
            closeTo(anchor.$2.top, 0.5),
            reason: 'history moved during decode frame $frame',
          );
          if (image.decodedDimensions != null &&
              find
                  .byKey(const Key('chat-image-loading-123-0'))
                  .evaluate()
                  .isEmpty) {
            decoded = true;
            break;
          }
        }
        expect(decoded, isTrue);
        expect(
          tester.getSize(find.byKey(const Key('chat-image-123-0'))),
          isNot(initialSize),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      },
    );
  }
}
