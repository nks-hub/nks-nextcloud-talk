import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_background_surface.dart';
import 'package:nextcloudtalk/features/chat/chat_background_theme.dart';
import 'package:nextcloudtalk/features/chat/chat_wallpaper.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_image_cache.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_room_extras.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_settings_store.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'owntalk_extensions_test_support.dart';
import 'test_support.dart';

/// A 1 x 1 PNG, small enough to decode inside a widget test.
final Uint8List _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
  'hKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  group('presets', () {
    test('the client draws exactly the IDs the server documents', () {
      expect(chatWallpaperPresets.map((preset) => preset.id), [
        'aurora',
        'sunset',
        'forest',
        'ocean',
        'dots',
        'grid',
        'lavender',
        'peach',
        'mint',
        'nebula',
        'bokeh',
        'waves',
        'dunes',
        'topo',
        'stars',
        'confetti',
      ]);
    });

    test('an unknown or missing ID has no preset', () {
      expect(chatWallpaperPresetById('neon'), isNull);
      expect(chatWallpaperPresetById(''), isNull);
      expect(chatWallpaperPresetById(null), isNull);
      expect(chatWallpaperPresetById('ocean')!.id, 'ocean');
    });

    test('only IDs the server lists and the client knows are offered', () {
      expect(
        offeredChatWallpaperPresets([
          'grid',
          'neon',
          'aurora',
          'aurora',
        ]).map((preset) => preset.id),
        ['grid', 'aurora', 'aurora'],
        reason: 'server order; the server never repeats an ID',
      );
      expect(offeredChatWallpaperPresets(const []), isEmpty);
      expect(offeredChatWallpaperPresets(['neon']), isEmpty);
    });

    for (final entry in {
      'light': AppTheme.light(),
      'dark': AppTheme.dark(),
    }.entries) {
      test('every ${entry.key} colour keeps text and borders readable '
          'without being altered', () {
        final scheme = entry.value.colorScheme;
        for (final preset in chatWallpaperPresets) {
          final declared = scheme.brightness == Brightness.dark
              ? preset.dark
              : preset.light;
          expect(preset.colorsFor(scheme), declared, reason: preset.id);
          for (final color in declared) {
            expect(
              chatBackgroundContrast(color, scheme.onSurface),
              greaterThanOrEqualTo(4.5),
              reason: '${preset.id} $color',
            );
            expect(
              chatBackgroundContrast(color, scheme.onSurfaceVariant),
              greaterThanOrEqualTo(4.5),
              reason: '${preset.id} $color',
            );
            expect(
              chatBackgroundContrast(color, scheme.outline),
              greaterThanOrEqualTo(3),
              reason: '${preset.id} $color',
            );
          }
        }
      });

      test('text on a chip reads at 4.5:1 over the worst wallpaper in the '
          '${entry.key} theme', () {
        final scheme = entry.value.colorScheme;
        final alpha = wallpaperChipAlpha(scheme);
        expect(alpha, inInclusiveRange(0.8, 1));
        final fill = scheme.surface.withValues(alpha: alpha);
        for (final wallpaper in const [Color(0xFF000000), Color(0xFFFFFFFF)]) {
          final chip = Color.alphaBlend(fill, wallpaper);
          for (final text in [scheme.onSurface, scheme.onSurfaceVariant]) {
            expect(
              chatBackgroundContrast(chip, text),
              greaterThanOrEqualTo(4.5),
              reason: '$text over $wallpaper',
            );
          }
        }
      });
    }

    test('the photo veil is light, lighter in the light theme', () {
      final dark = photoScrimAlpha(AppTheme.dark().colorScheme);
      final light = photoScrimAlpha(AppTheme.light().colorScheme);
      expect(dark, inInclusiveRange(0.25, 0.35));
      expect(light, inInclusiveRange(0.15, 0.25));
    });

    testWidgets('each preset paints in both themes without errors', (
      tester,
    ) async {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        for (final preset in chatWallpaperPresets) {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: SizedBox(
                width: 200,
                height: 300,
                child: ChatWallpaper(preset: preset),
              ),
            ),
          );
          expect(tester.takeException(), isNull, reason: preset.id);
          expect(
            find.descendant(
              of: find.byType(ChatWallpaper),
              matching: find.byType(CustomPaint),
            ),
            findsWidgets,
          );
        }
      }
    });
  });

  group('photo layer', () {
    testWidgets('veils the photo once it is on screen', (tester) async {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.binding.imageCache.clear();
        final widget = MaterialApp(
          theme: theme,
          home: SizedBox(
            width: 100,
            height: 100,
            child: ChatWallpaperPhoto(bytes: _pixel),
          ),
        );
        await tester.pumpWidget(widget);
        // Nothing to veil before the first frame has been decoded.
        expect(find.byKey(const Key('chat-wallpaper-scrim')), findsNothing);
        await tester.runAsync(
          () => precacheImage(
            MemoryImage(_pixel),
            tester.element(find.byType(ChatWallpaperPhoto)),
          ),
        );
        await tester.pumpWidget(widget);
        await tester.pump();

        final scrim = tester.widget<ColoredBox>(
          find.byKey(const Key('chat-wallpaper-scrim')),
        );
        final scheme = theme.colorScheme;
        expect(
          scrim.color,
          scheme.surface.withValues(alpha: photoScrimAlpha(scheme)),
        );
        final image = tester.widget<Image>(find.byType(Image));
        expect(image.fit, BoxFit.cover);
      }
    });

    testWidgets('a photo that cannot be decoded draws nothing', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 100,
            height: 100,
            child: ChatWallpaperPhoto(bytes: Uint8List.fromList([1, 2, 3])),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(find.byKey(const Key('chat-wallpaper-scrim')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('chip', () {
    testWidgets('is just its child without a wallpaper', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ChatBackgroundChip(child: Text('Dnes', key: Key('label'))),
        ),
      );
      expect(find.byType(DecoratedBox), findsNothing);
      expect(
        ChatBackgroundChip.colorOf(
          tester.element(find.byKey(const Key('label'))),
        ),
        isNull,
      );
    });

    testWidgets('is a rounded translucent surface over a wallpaper', (
      tester,
    ) async {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: const ChatWallpaperScope(
              active: true,
              child: ChatBackgroundChip(child: Text('Dnes', key: Key('label'))),
            ),
          ),
        );
        // The theme change animates; let it arrive.
        await tester.pump(const Duration(seconds: 1));
        final box = tester.widget<DecoratedBox>(
          find.ancestor(
            of: find.byKey(const Key('label')),
            matching: find.byType(DecoratedBox),
          ),
        );
        final decoration = box.decoration as BoxDecoration;
        final scheme = theme.colorScheme;
        expect(
          decoration.color,
          scheme.surface.withValues(alpha: wallpaperChipAlpha(scheme)),
        );
        expect(decoration.borderRadius, isNotNull);
        expect(decoration.color!.a, greaterThanOrEqualTo(0.8));
      }
    });
  });

  group('chat surface', () {
    late AppDatabase database;
    late FakeOwnTalkServer server;

    setUp(() async {
      database = openTestDatabase();
      await AccountRepository(database).upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://cloud.example.invalid',
        loginName: 'fixture-user',
        serverProductName: 'Nextcloud',
        talkFeatures: const {},
        createdAt: DateTime.utc(2026, 1, 1),
      );
      server = FakeOwnTalkServer();
    });

    tearDown(() => database.close());

    List<Override> overrides({
      String? local,
      bool imageProvider = false,
      Uint8List? imageBytes,
    }) => [
      appDatabaseProvider.overrideWithValue(database),
      credentialVaultProvider.overrideWithValue(
        MemoryCredentialVault()..values['account-a'] = 'fixture-password',
      ),
      nextcloudApiProvider.overrideWithValue(
        HttpNextcloudApi(client: server.client),
      ),
      ownTalkSettingsStoreProvider.overrideWith(
        (ref) => Future<OwnTalkSettingsStore>.error(StateError('no store')),
      ),
      ownTalkImageCacheProvider.overrideWith(
        (ref) => Future<OwnTalkImageCache>.error(StateError('no cache')),
      ),
      appLifecycleResumeEventsProvider.overrideWithValue(
        const Stream<void>.empty(),
      ),
      chatBackgroundProvider.overrideWith(
        (ref, key) => Stream<String?>.value(local),
      ),
      if (imageProvider)
        ownTalkRoomImageProvider.overrideWith((ref, key) async => imageBytes),
    ];

    Widget surface({
      String? local,
      bool shared = true,
      bool imageProvider = false,
      Uint8List? imageBytes,
      ThemeData? theme,
      List<bool>? headerTints,
    }) => ProviderScope(
      overrides: overrides(
        local: local,
        imageProvider: imageProvider,
        imageBytes: imageBytes,
      ),
      child: MaterialApp(
        theme: theme ?? AppTheme.light(),
        home: ChatBackgroundSurface(
          accountId: 'account-a',
          roomToken: ownTalkTestToken,
          sharedSettings: shared,
          header: headerTints == null
              ? null
              : (context, tinted) {
                  headerTints.add(tinted);
                  return const SizedBox(key: Key('chat-header'), height: 56);
                },
          child: const SizedBox.expand(key: Key('chat-child')),
        ),
      ),
    );

    Color surfaceColor(WidgetTester tester) => tester
        .widget<Material>(find.byKey(const Key('chat-background-surface')))
        .color!;

    ColorScheme schemeOf(WidgetTester tester) => Theme.of(
      tester.element(find.byKey(const Key('chat-background-surface'))),
    ).colorScheme;

    /// Pumps the surface and waits for its own settings request, so a test
    /// never ends with a database query still in flight.
    Future<void> pumpSurface(WidgetTester tester, Widget widget) async {
      final before = server.settingsRequests.length;
      await tester.pumpWidget(widget);
      await pumpUntilCondition(
        tester,
        () => server.settingsRequests.length > before,
        reason: 'the settings were never read',
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    }

    final photoLayer = find.byKey(const Key('chat-wallpaper-photo'));
    final presetLayer = find.byKey(const Key('chat-wallpaper-preset'));

    testWidgets('draws the shared preset and keeps the theme colour', (
      tester,
    ) async {
      server.setExternally({'chat.backgroundPreset': 'sunset'});
      await tester.pumpWidget(surface());
      await pumpUntilCondition(
        tester,
        () => presetLayer.evaluate().isNotEmpty,
        reason: 'the preset never appeared',
      );
      expect(photoLayer, findsNothing);
      expect(surfaceColor(tester), schemeOf(tester).surface);
      await unmount(tester);
    });

    testWidgets('the header shares the background and is veiled over a '
        'preset only', (tester) async {
      final tints = <bool>[];
      await pumpSurface(tester, surface(headerTints: tints));
      expect(find.byKey(const Key('chat-header')), findsOneWidget);
      expect(tints.last, isFalse);
      expect(find.byKey(const Key('chat-header-veil')), findsNothing);
      expect(
        tester.getTopLeft(find.byKey(const Key('chat-child'))).dy,
        tester.getBottomLeft(find.byKey(const Key('chat-header'))).dy,
        reason: 'the chat starts below the header',
      );
      await unmount(tester);

      server.setExternally({'chat.backgroundPreset': 'nebula'});
      await tester.pumpWidget(surface(headerTints: tints));
      await pumpUntilCondition(
        tester,
        () => presetLayer.evaluate().isNotEmpty,
        reason: 'the preset never appeared',
      );
      expect(tints.last, isTrue);
      final veil = tester.widget<ColoredBox>(
        find.byKey(const Key('chat-header-veil')),
      );
      expect(veil.color, schemeOf(tester).surface.withValues(alpha: 0.35));
      expect(
        tester.getTopLeft(presetLayer).dy,
        tester.getTopLeft(find.byKey(const Key('chat-header'))).dy,
        reason: 'the wallpaper reaches up behind the header',
      );
      await unmount(tester);
    });

    testWidgets('an ID the client cannot draw falls back to the colour, '
        'then the theme', (tester) async {
      server.setExternally({
        'chat.backgroundPreset': 'neon',
        'chat.backgroundColor': '#FF00FF',
      });
      await tester.pumpWidget(surface());
      await pumpUntilCondition(
        tester,
        () => surfaceColor(tester) != schemeOf(tester).surface,
      );
      expect(presetLayer, findsNothing);
      expect(
        surfaceColor(tester),
        safeChatBackground(const Color(0xFFFF00FF), schemeOf(tester)),
      );
      await unmount(tester);

      server
        ..settings['chat.backgroundColor'] = null
        ..revision += 1;
      await pumpSurface(tester, surface());
      expect(presetLayer, findsNothing);
      expect(surfaceColor(tester), schemeOf(tester).surface);
      await unmount(tester);
    });

    testWidgets('the photo outranks the preset, which outranks the colour', (
      tester,
    ) async {
      server.setExternally({
        'chat.backgroundColor': '#FF00FF',
        'chat.backgroundPreset': 'ocean',
        'chat.backgroundImage': ownTalkTestSha(ownTalkTestJpeg()),
      });
      await tester.pumpWidget(surface(imageProvider: true, imageBytes: _pixel));
      await pumpUntilCondition(
        tester,
        () => photoLayer.evaluate().isNotEmpty,
        reason: 'the photo never appeared',
      );
      // Beneath the photo, the preset stays as the fallback while it decodes;
      // beneath that, the colour.
      expect(presetLayer, findsOneWidget);
      expect(
        surfaceColor(tester),
        safeChatBackground(const Color(0xFFFF00FF), schemeOf(tester)),
      );
      final layers = tester
          .widgetList<Widget>(
            find.descendant(
              of: find.byKey(const Key('chat-background-surface')),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget.key == const Key('chat-wallpaper-preset') ||
                    widget.key == const Key('chat-wallpaper-photo'),
              ),
            ),
          )
          .map((widget) => (widget.key! as ValueKey<String>).value)
          .toList();
      expect(layers, ['chat-wallpaper-preset', 'chat-wallpaper-photo']);
      await unmount(tester);
    });

    testWidgets('while the photo is not available the preset shows', (
      tester,
    ) async {
      server.setExternally({
        'chat.backgroundPreset': 'ocean',
        'chat.backgroundImage': ownTalkTestSha(ownTalkTestJpeg()),
      });
      await tester.pumpWidget(surface(imageProvider: true));
      await pumpUntilCondition(tester, () => presetLayer.evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 100));
      expect(photoLayer, findsNothing);
      await unmount(tester);
    });

    testWidgets('the colour of this device hides every shared layer and the '
        'photo is not even downloaded', (tester) async {
      final jpeg = ownTalkTestJpeg();
      server
        ..images[ownTalkTestSha(jpeg)] = jpeg
        ..setExternally({
          'chat.backgroundColor': '#FF00FF',
          'chat.backgroundPreset': 'ocean',
          'chat.backgroundImage': ownTalkTestSha(jpeg),
        });
      await pumpSurface(tester, surface(local: '#123456'));
      expect(presetLayer, findsNothing);
      expect(photoLayer, findsNothing);
      expect(
        surfaceColor(tester),
        safeChatBackground(const Color(0xFF123456), schemeOf(tester)),
      );
      expect(server.downloads, isEmpty);
      await unmount(tester);
    });

    testWidgets('without shared settings nothing is asked or drawn', (
      tester,
    ) async {
      server.setExternally({'chat.backgroundPreset': 'ocean'});
      await tester.pumpWidget(surface(shared: false));
      await tester.pump(const Duration(milliseconds: 200));
      expect(presetLayer, findsNothing);
      expect(server.requests, isEmpty);
      expect(surfaceColor(tester), schemeOf(tester).surface);
      await unmount(tester);
    });

    testWidgets('downloads the photo through the server and draws it', (
      tester,
    ) async {
      final jpeg = ownTalkTestJpeg();
      server
        ..images[ownTalkTestSha(jpeg)] = jpeg
        ..setExternally({'chat.backgroundImage': ownTalkTestSha(jpeg)});
      await tester.pumpWidget(surface());
      await pumpUntilCondition(
        tester,
        () => photoLayer.evaluate().isNotEmpty,
        reason: 'the photo never appeared',
      );
      expect(server.downloads, hasLength(1));
      final request = server.downloads.single;
      expect(request.method, 'GET');
      expect(request.url.pathSegments.last, ownTalkTestSha(jpeg));
      expect(request.headers['OCS-APIRequest'], 'true');
      expect(request.headers['Authorization'], startsWith('Basic '));
      expect(
        tester.widget<ChatWallpaperPhoto>(photoLayer).bytes,
        orderedEquals(jpeg),
      );
      await unmount(tester);
    });

    testWidgets('a failed download leaves the colour and retries later', (
      tester,
    ) async {
      final jpeg = ownTalkTestJpeg();
      server
        ..images[ownTalkTestSha(jpeg)] = jpeg
        ..failDownloadWith = 503
        ..setExternally({
          'chat.backgroundColor': '#FF00FF',
          'chat.backgroundImage': ownTalkTestSha(jpeg),
        });
      await tester.pumpWidget(surface());
      await pumpUntilCondition(tester, () => server.downloads.isNotEmpty);
      await tester.pump(const Duration(milliseconds: 100));
      expect(photoLayer, findsNothing);
      expect(
        surfaceColor(tester),
        safeChatBackground(const Color(0xFFFF00FF), schemeOf(tester)),
      );
      // The retry timer dies with the provider.
      await unmount(tester);
    });

    Widget probe({
      String? local,
      bool imageProvider = false,
      Uint8List? imageBytes,
    }) => ProviderScope(
      overrides: overrides(
        local: local,
        imageProvider: imageProvider,
        imageBytes: imageBytes,
      ),
      child: MaterialApp(
        home: ChatBackgroundSurface(
          accountId: 'account-a',
          roomToken: ownTalkTestToken,
          sharedSettings: true,
          child: Builder(
            builder: (context) => Text(
              ChatWallpaperScope.isActive(context) ? 'chips' : 'plain',
              textDirection: TextDirection.ltr,
            ),
          ),
        ),
      ),
    );

    testWidgets('chips are on for a preset or a loaded photo, off for a '
        'plain colour or the theme', (tester) async {
      await pumpSurface(tester, probe());
      expect(find.text('plain'), findsOneWidget);
      await unmount(tester);

      server.setExternally({'chat.backgroundColor': '#123456'});
      await pumpSurface(tester, probe());
      expect(find.text('plain'), findsOneWidget);
      await unmount(tester);

      server.setExternally({'chat.backgroundPreset': 'forest'});
      await pumpSurface(tester, probe());
      await pumpUntilCondition(
        tester,
        () => find.text('chips').evaluate().isNotEmpty,
      );
      await unmount(tester);

      // This device's own colour hides the wallpaper, so no chips either.
      await pumpSurface(tester, probe(local: '#123456'));
      expect(find.text('plain'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a photo that is still loading has no chips yet, a loaded one '
        'has', (tester) async {
      server.setExternally({
        'chat.backgroundImage': ownTalkTestSha(ownTalkTestJpeg()),
      });
      await pumpSurface(tester, probe(imageProvider: true));
      expect(find.text('plain'), findsOneWidget);
      await unmount(tester);

      await pumpSurface(tester, probe(imageProvider: true, imageBytes: _pixel));
      await pumpUntilCondition(
        tester,
        () => find.text('chips').evaluate().isNotEmpty,
      );
      await unmount(tester);
    });

    testWidgets('keeps the chat below in place when a wallpaper appears', (
      tester,
    ) async {
      await pumpSurface(tester, surface());
      final before = tester.element(find.byKey(const Key('chat-child')));

      server.setExternally({'chat.backgroundPreset': 'grid'});
      final container = ProviderScope.containerOf(before);
      // Real I/O: not awaited, the condition below waits for its result.
      unawaited(
        container
            .read(
              ownTalkRoomExtrasProvider((
                accountId: 'account-a',
                roomToken: ownTalkTestToken,
              )).notifier,
            )
            .refresh(),
      );
      await pumpUntilCondition(tester, () => presetLayer.evaluate().isNotEmpty);
      expect(
        identical(tester.element(find.byKey(const Key('chat-child'))), before),
        isTrue,
        reason: 'the chat element must survive a wallpaper change',
      );
      await unmount(tester);
    });
  });
}
