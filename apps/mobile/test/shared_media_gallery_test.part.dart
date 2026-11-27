part of 'shared_items_screen_test.dart';

void _galleryTests() {
  testWidgets(
    'media grid loads the next page, swipes across messages and opens the exact original',
    (tester) async {
      final cursors = <int>[];
      final first = List.generate(sharedItemsPageLimit, (i) => 200 - i);
      final service = _FakeSharedItemsService(
        overviewHandler: (_, _) async => _overview({
          SharedItemType.media: [200],
        }),
        pageHandler: (_, _, type, cursor, _) async {
          cursors.add(cursor);
          return _page(
            type: type,
            messageIds: cursor == 0 ? first : [100],
            lastKnownMessageId: cursor,
            message: (id) {
              final m = _message(id);
              if (![200, 199, 100].contains(id)) return m;
              return m
                ..['message'] = '{file}'
                ..['messageParameters'] = {
                  'file': {
                    'id': '$id',
                    'type': 'file',
                    'name': '$id.png',
                    'path': 'Talk/$id.png',
                    'link': '/index.php/f/$id',
                    'mimetype': 'image/png',
                    'preview-available': id == 100 ? 'no' : 'yes',
                  },
                };
            },
          );
        },
      );
      final image = ChatMediaImage(
        contentType: 'image/png',
        body: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGP6zwAAAgcBApocMXEAAAAASUVORK5CYII=',
        ),
      );
      final vault = MemoryCredentialVault()..values[_account.id] = 'fixture';
      final db = openTestDatabase();
      addTearDown(db.close);
      await tester.runAsync(() async {
        await db.into(db.accounts).insert(_account);
        await db.into(db.cachedConversations).insert(_conversation);
      });
      final requests = <Uri>[];
      final media = ChatMediaRepository(
        vault,
        client: MockClient((request) async {
          requests.add(request.url);
          return http.Response.bytes(
            image.body,
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          credentialVaultProvider.overrideWithValue(vault),
          sharedItemsServiceProvider.overrideWithValue(service),
          chatMediaRepositoryProvider.overrideWithValue(media),
          chatMediaProvider.overrideWith((_, _) async => image),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: localizedTestApp(
            home: SharedItemsScreen(
              account: _account,
              conversation: _conversation,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final a = find.byKey(const Key('shared-photo-200-0'));
      final b = find.byKey(const Key('shared-photo-199-0'));
      expect(tester.getTopLeft(a).dy, tester.getTopLeft(b).dy);
      await tester.tap(a);
      await tester.pumpAndSettle();
      expect(cursors, [0, first.last]);
      expect(find.text('1 / 3'), findsOneWidget);
      await tester.fling(find.byType(PageView), const Offset(-650, 0), 900);
      await tester.pumpAndSettle();
      expect(find.text('2 / 3'), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-gallery-next')));
      await tester.pumpAndSettle();
      expect(find.text('3 / 3'), findsOneWidget);
      await pumpUntilCondition(
        tester,
        () => requests.any((u) => u.path.endsWith('/Talk/100.png')),
      );
      await tester.tap(find.byKey(const Key('chat-gallery-open-source')));
      await pumpUntilCondition(
        tester,
        () => find.byType(PresenceChatRoomScreen).evaluate().isNotEmpty,
      );
      final opened = tester.widget<PresenceChatRoomScreen>(
        find.byType(PresenceChatRoomScreen),
      );
      expect(opened.jumpToMessageId, 100);
      expect(opened.account.id, _account.id);
      expect(opened.conversation.token, _conversation.token);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}
