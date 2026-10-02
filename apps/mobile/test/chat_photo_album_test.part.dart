part of 'chat_room_pane_test.dart';

Map<String, Object?> _albumWire(
  int index, {
  String albumId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
}) => _layoutImageWire(100 + index)
  ..['threadId'] = 100 + index
  ..['referenceId'] = ChatPhotoAlbumReference(
    albumId: albumId,
    index: index,
    count: 4,
  ).referenceId;

void _registerPhotoAlbumTests() {
  testWidgets(
    'partial album keeps sent photos accessible inside the sending bubble',
    (tester) async {
      final jobs = StreamController<List<StoredAttachmentJob>>();
      addTearDown(jobs.close);
      for (var index = 0; index < 2; index++) {
        await _insertCachedMessage(
          database,
          _albumWire(index),
          displayText: 'Photo',
        );
      }
      await database.into(database.chatScopes).insert(ChatScopesCompanion.insert(
        accountId: account.id, roomToken: conversation.token, scopeKey: 'root',
        historyCursor: '10', futureCursor: '103', lastCommonRead: '10',
        lastReadMessage: 0, unreadMessages: 0, hasHistory: false,
        futureConverged: true, blocksJson: '[["10","103"]]',
      ));
      await tester.pumpWidget(
        app(
          home: roomScreen(),
          overrides: [
            attachmentRoomJobsProvider.overrideWith((ref, key) => jobs.stream),
            chatMediaProvider.overrideWith((ref, key) async => null),
          ],
        ),
      );
      await tester.pumpAndSettle();
      jobs.add([
        pendingAttachmentFixture(0, phase: 'completed'),
        pendingAttachmentFixture(1, phase: 'completed'),
        pendingAttachmentFixture(2, phase: 'failed'),
        pendingAttachmentFixture(3, phase: 'failed'),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PendingAttachmentBubble), findsOneWidget);
      expect(find.text('2 of 4 sent'), findsOneWidget);
      expect(find.byType(ChatPhotoAlbumContent), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(PendingAttachmentBubble),
          matching: find.byType(ChatPhotoAlbumContent),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('chat-message-target-100')), findsNothing);
      final gallery = tester.widget<ChatPhotoAlbumContent>(
        find.byType(ChatPhotoAlbumContent),
      );
      expect(gallery.messages.map((message) => message.messageId), [100, 101]);
      gallery.onOpenParent!(100);
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const Key('chat-jump-not-found')), findsNothing);
      expect(
        tester
            .widget<PendingAttachmentBubble>(
              find.byType(PendingAttachmentBubble),
            )
            .highlighted,
        isTrue,
      );
      for (var index = 2; index < 4; index++) {
        await _insertCachedMessage(
          database,
          _albumWire(index),
          displayText: 'Photo',
        );
      }
      jobs.add(
        List.generate(
          4,
          (index) => pendingAttachmentFixture(index, phase: 'completed'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PendingAttachmentBubble), findsNothing);
      expect(find.byKey(const Key('chat-photo-album-100')), findsOneWidget);
      expect(
        tester
            .widget<ChatPhotoAlbumContent>(find.byType(ChatPhotoAlbumContent))
            .messages,
        hasLength(4),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  test('album grouping respects sender, scope, gaps and separate sends', () {
    List<List<int>> groups(List<Map<String, Object?>> wire, {int? boundary}) =>
        groupPhotoAlbums(
          wire.map(ChatMessage.fromJson).toList(),
          canGroup: (_) => true,
          boundaryBefore: (index) => index == boundary,
        );
    expect(groups(List.generate(4, _albumWire)), [
      [0, 1, 2, 3],
    ]);
    expect(
      groups([_albumWire(1), _albumWire(2), _albumWire(3), _albumWire(0)]),
      [
        [0, 1, 2, 3],
      ],
    );
    expect(groups(List.generate(4, _albumWire), boundary: 2), [
      [0, 1],
      [2, 3],
    ]);
    expect(
      groups([
        _albumWire(0),
        _albumWire(1),
        _albumWire(2, albumId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
        _albumWire(3, albumId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
      ]),
      [
        [0, 1],
        [2, 3],
      ],
    );
    for (final field in ['actorId', 'actorType', 'token', 'threadId']) {
      final wire = List.generate(4, _albumWire);
      wire[2][field] = field == 'threadId' ? 50 : 'other';
      expect(groups(wire), [
        [0, 1],
      ], reason: field);
    }
    expect(
      ChatPhotoAlbumReference.tryParse('otg1.${'a' * 32}.0004.0004'),
      isNull,
    );
    expect(
      () => ChatReferenceId.parse('otg1.${'a' * 32}.0004.0004'),
      throwsA(isA<TalkProtocolException>()),
    );
    expect(
      ChatReferenceId.parse(_albumWire(0)['referenceId']).value,
      _albumWire(0)['referenceId'],
    );
  });

  for (final width in [390.0, 1100.0]) {
    testWidgets('four received photos form one album at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (var index = 0; index < 4; index++) {
        await _insertCachedMessage(
          database,
          index == 1
              ? (_albumWire(index)..['message'] = '{file}\nSecond caption')
              : _albumWire(index),
          displayText: 'Photo',
        );
      }
      await tester.pumpWidget(
        app(
          home: roomScreen(),
          overrides: [chatMediaProvider.overrideWith((ref, key) async => null)],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-photo-album-100')), findsOneWidget);
      expect(find.textContaining('Second caption'), findsOneWidget);
      expect(find.byKey(const Key('chat-message-target-100')), findsOneWidget);
      expect(find.byKey(const Key('chat-message-target-101')), findsNothing);
      expect(find.byKey(const Key('chat-message-target-103')), findsNothing);
      expect(find.byKey(const Key('chat-image-error-103-0')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  }
}
