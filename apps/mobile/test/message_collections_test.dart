import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/message_collections.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  late Directory root;
  late MessageCollectionStore store;
  final owner = AccountId.parse('one');
  const link = SavedMessageLink(
    roomToken: 'room1',
    messageId: 42,
    threadId: 27,
    roomName: 'Project',
    excerpt: 'Final estimate',
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'owntalk-message-collections-',
    );
    store = MessageCollectionStore(directory: root);
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'preserves exact room and thread across restart without merging accounts',
    () async {
      const anotherRoom = SavedMessageLink(
        roomToken: 'room2',
        messageId: 42,
        threadId: null,
        roomName: 'Second',
        excerpt: 'Notes',
      );
      final id = await store.create(owner, 'Review', message: link);
      expect(await store.create(owner, 'review', message: link), id);
      await store.setSaved(owner, id, anotherRoom, saved: true);
      final second = AccountId.parse('two');
      await store.create(second, 'Review', message: anotherRoom);
      final reopened = MessageCollectionStore(directory: root);
      final collection = (await reopened.read(owner)).single;
      expect(
        collection.messages.map((m) => (m.roomToken, m.messageId, m.threadId)),
        [('room2', 42, null), ('room1', 42, 27)],
      );
      await reopened.rename(owner, id, 'Later');
      await reopened.setSaved(owner, id, anotherRoom, saved: false);
      final changed = (await reopened.read(owner)).single;
      expect(changed.name, 'Later');
      expect(changed.messages.single.excerpt, 'Final estimate');
      await reopened.delete(owner);
      expect(await reopened.read(owner), isEmpty);
      expect((await reopened.read(second)).single.name, 'Review');
    },
  );

  testWidgets(
    'saves a message into a new collection and selects its original thread',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(797.7, 411.4);
      addTearDown(tester.view.reset);
      SavedMessageLink? chosen;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  TextButton(
                    onPressed: () => showSaveToMessageCollection(
                      context,
                      account: owner,
                      store: store,
                      message: link,
                    ),
                    child: const Text('Save link'),
                  ),
                  TextButton(
                    onPressed: () async =>
                        chosen = await showMessageCollections(
                          context,
                          account: owner,
                          store: store,
                        ),
                    child: const Text('Open list'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final strings = AppLocalizations.of(
        tester.element(find.byType(Scaffold)),
      );
      Future<void> wait(Finder where) async {
        for (var i = 0; i < 150; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (where.hitTestable().evaluate().isNotEmpty) return;
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 3)),
          );
        }
        fail('Missing $where');
      }

      Future<void> tap(String text) async {
        final target = find.text(text);
        await wait(target);
        await tester.tap(target.hitTestable().last);
        await tester.pump(const Duration(milliseconds: 300));
      }

      await tap('Save link');
      await tap(strings.newMessageCollection);
      await tester.enterText(find.byType(TextFormField), 'Invoices');
      await tap(strings.editMessageSave);
      await wait(find.byType(CheckboxListTile));
      tester.view.viewInsets = const FakeViewPadding(bottom: 244.5);
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isTrue,
      );
      await tester.tap(find.byTooltip(strings.close));
      await tester.pumpAndSettle();
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tap('Open list');
      await tap('Invoices');
      await tap('Final estimate');
      await tester.pumpAndSettle();
      expect(
        (chosen?.roomToken, chosen?.messageId, chosen?.threadId),
        ('room1', 42, 27),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
