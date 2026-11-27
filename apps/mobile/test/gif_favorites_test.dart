import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/gif_favorites.dart';
import 'package:nextcloudtalk/features/chat/composer/giphy.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations.dart';
import 'package:talk_protocol/talk_protocol.dart';

GiphyEntry _entry(String id, {bool media = false}) => GiphyEntry(
  thumbnailUrl: Uri.parse(
    'https://cloud.example.invalid/apps/integration_giphy/gif/$id'
    '?fileName=fixed_width.gif&api_key=discard-this',
  ),
  title: id,
  subline: '',
  resourceUrl: Uri.parse(
    media
        ? 'https://media.giphy.com/media/$id/giphy.gif'
        : 'https://giphy.com/gifs/animal-$id',
  ),
);

void main() {
  late Directory directory;
  late GifFavoritesStore store;
  final first = AccountId.parse('account-one');
  final other = AccountId.parse('account-two');

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('owntalk-favorite-gifs-');
    store = GifFavoritesStore(directory: directory);
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'favorites survive restart, serialize changes and clear only their owner',
    () async {
      final otter = _entry('otter');
      await Future.wait([
        store.setFavorite(first, otter, saved: true),
        store.setFavorite(first, _entry('cat'), saved: true),
        store.setFavorite(other, _entry('seal'), saved: true),
      ]);
      final reopened = GifFavoritesStore(directory: directory);
      final found = await reopened.read(first);
      expect(found.map((e) => e.title), ['cat', 'otter']);
      expect(found.last.thumbnailUrl.queryParameters, {
        'fileName': 'fixed_width.gif',
      });
      expect(found.last.resourceUrl, otter.resourceUrl);
      final file =
          (await directory
                      .list(recursive: true)
                      .where((f) => f is File)
                      .toList())
                  .first
              as File;
      expect(await file.readAsString(), isNot(contains('discard-this')));
      await reopened.setFavorite(
        first,
        _entry('otter', media: true),
        saved: false,
      );
      expect((await reopened.read(first)).single.title, 'cat');
      await Future.wait([
        reopened.setFavorite(first, otter, saved: true),
        reopened.delete(first),
      ]);
      expect(await store.read(first), isEmpty);
      expect((await store.read(other)).single.title, 'seal');
    },
  );

  testWidgets(
    'star acts independently of sending and follows the active account',
    (tester) async {
      final entry = _entry('otter');
      var sent = 0;
      Widget room(AccountId account, String conversation) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: GifFavoritesScope(
            key: ValueKey(conversation),
            accountId: account,
            store: store,
            builder: (context, favorites) => Stack(
              children: [
                SizedBox(
                  width: 150,
                  height: 85,
                  child: TextButton(
                    onPressed: () => sent++,
                    child: const Text('Send'),
                  ),
                ),
                GifFavoriteButton(entry: entry, favorites: favorites),
              ],
            ),
          ),
        ),
      );
      Future<void> waitFor(bool saved) async {
        for (var step = 0; step < 200; step++) {
          await tester.pump(const Duration(milliseconds: 10));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 3)),
          );
          final star = tester.widget<IconButton>(find.byType(IconButton));
          if (star.isSelected == saved && star.onPressed != null) return;
        }
        fail('Favorite state did not become $saved');
      }

      await tester.pumpWidget(room(first, 'room-one'));
      await waitFor(false);
      await tester.tap(find.byType(IconButton));
      await waitFor(true);
      expect(sent, 0);
      await tester.pumpWidget(room(first, 'room-two'));
      await waitFor(true);
      await tester.pumpWidget(room(other, 'room-two'));
      await waitFor(false);
      await tester.pumpWidget(room(first, 'room-one'));
      await waitFor(true);
      await tester.tap(find.byType(IconButton));
      await waitFor(false);
      expect(sent, 0);
      await tester.tap(find.text('Send'));
      expect(sent, 1);
    },
  );
}
