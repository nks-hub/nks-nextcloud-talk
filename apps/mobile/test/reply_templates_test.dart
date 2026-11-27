import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/composer_text_editing.dart';
import 'package:nextcloudtalk/features/chat/composer/reply_templates.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  final account = AccountId.parse('one');
  late Directory root;
  late ReplyTemplateStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('owntalk-reply-templates-');
    store = ReplyTemplateStore(directory: root);
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'renamed and edited templates survive restart and stay with their account',
    () async {
      await store.save(account, name: 'Later', text: 'brb');
      final id = (await store.read(account)).single.id;
      await store.save(
        account,
        id: id,
        name: 'Tomorrow',
        text: 'See you tomorrow.',
      );
      final reopened = ReplyTemplateStore(directory: root);
      final template = (await reopened.read(account)).single;
      expect(
        (template.id, template.name, template.text),
        (id, 'Tomorrow', 'See you tomorrow.'),
      );
      final second = AccountId.parse('other');
      expect(await reopened.read(second), isEmpty);
      await reopened.save(second, name: 'Greetings', text: 'Hello.');
      await reopened.delete(account);
      expect(await reopened.read(account), isEmpty);
      expect((await reopened.read(second)).single.text, 'Hello.');
    },
  );

  testWidgets('create, edit, insert at the selection and remove a reply', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(797.7, 411.4);
    addTearDown(tester.view.reset);
    final field = TextEditingController(text: 'before OLD after')
      ..selection = const TextSelection(baseOffset: 7, extentOffset: 10);
    addTearDown(field.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final reply = await showReplyTemplates(
                  context,
                  account: account,
                  store: store,
                );
                if (reply != null) insertComposerText(field, reply);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    Future<void> wait(Finder target) async {
      for (var i = 0; i < 150; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (target.hitTestable().evaluate().isNotEmpty) return;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 3)),
        );
      }
      fail('Missing $target');
    }

    Future<void> tap(String label) async {
      final target = find.text(label).last;
      await wait(target);
      await tester.tap(target);
      await tester.pump(const Duration(milliseconds: 300));
    }

    await tap('Open');
    final strings = AppLocalizations.of(tester.element(find.byType(Scaffold)));
    await wait(find.text(strings.replyTemplatesEmpty));
    tester.view.viewInsets = const FakeViewPadding(bottom: 244.5);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tap(strings.newReplyTemplate);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Name');
    await tester.enterText(find.byType(TextFormField).last, 'initial');
    await tap(strings.editMessageSave);
    await wait(find.text('Name'));
    Future<void> menu() async {
      await tester.tap(find.byType(PopupMenuButton<bool>));
      await tester.pumpAndSettle();
    }

    await menu();
    await tap(strings.messageActionEdit);
    await tester.enterText(find.byType(TextFormField).last, 'NEW');
    await tap(strings.editMessageSave);
    await wait(find.text('NEW'));
    tester.view.viewInsets = const FakeViewPadding(bottom: 244.5);
    await tester.pumpAndSettle();
    await tap('Name');
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(field.text, 'before NEW after');
    expect(field.selection, const TextSelection.collapsed(offset: 10));
    await tap('Open');
    await wait(find.text('Name'));
    await menu();
    await tap(strings.messageActionDelete);
    await wait(find.text(strings.replyTemplatesEmpty));
    expect(tester.takeException(), isNull);
  });
}
