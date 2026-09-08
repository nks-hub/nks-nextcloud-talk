part of 'chat_room_pane_test.dart';

Map<String, Object?> _layoutImageWire(
  int id, {
  int width = 808,
  int height = 121,
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
      'width': width,
      'height': height,
    },
  },
);

void _registerChatRoomPaneImageGeometryTests() {
  for (final imageCount in [1, 2]) {
    testWidgets(
      '$imageCount late image dimensions preserve the visible history position',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1000, 800);
        addTearDown(tester.view.reset);
        final imageIds = {123, if (imageCount == 2) 122};
        for (var id = 101; id <= 130; id++) {
          final wire = imageIds.contains(id)
              ? _layoutImageWire(id)
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
        controller.jumpTo(300);
        await tester.pump();
        await tester.pump();
        final viewport = tester.getRect(listFinder);
        final visible = <(int, Rect)>[];
        for (var id = 101; id <= 130; id++) {
          final finder = find.byKey(Key('chat-message-target-$id'));
          if (finder.evaluate().isEmpty || imageIds.contains(id)) continue;
          final rect = tester.getRect(finder);
          if (rect.top > viewport.top + 8 &&
              rect.bottom < viewport.bottom - 8) {
            visible.add((id, rect));
          }
        }
        visible.sort((a, b) => a.$2.top.compareTo(b.$2.top));
        expect(visible, isNotEmpty);
        final anchor = visible.first;
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
}
