import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_background_photo.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_image_cache.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_room_extras.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_settings_store.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/shared_appearance_section.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'owntalk_extensions_test_support.dart';
import 'test_support.dart';

const _row = Key('owntalk-shared-background');
const _tabColor = Key('owntalk-tab-color');
const _tabPreset = Key('owntalk-tab-preset');
const _tabPhoto = Key('owntalk-tab-photo');

void main() {
  late AppDatabase database;
  late FakeOwnTalkServer server;
  late List<({int maxBytes, int maxEdge})> pickerCalls;
  late Future<OwnTalkBackgroundPhoto?> Function() pick;

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
    pickerCalls = [];
    pick = () async => (bytes: ownTalkTestJpeg(3), contentType: 'image/jpeg');
  });

  tearDown(() => database.close());

  Widget app({int width = 800, int height = 600}) => ProviderScope(
    overrides: [
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
      ownTalkPhotoPickerProvider.overrideWithValue(({
        required int maxBytes,
        required int maxEdge,
      }) {
        pickerCalls.add((maxBytes: maxBytes, maxEdge: maxEdge));
        return pick();
      }),
    ],
    child: localizedTestApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: OwnTalkSharedAppearanceSection(
            accountId: 'account-a',
            roomToken: ownTalkTestToken,
            roomType: 2,
            federated: false,
          ),
        ),
      ),
    ),
  );

  Future<void> pumpUntil(WidgetTester tester, bool Function() condition) =>
      pumpUntilCondition(tester, condition);

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await pumpUntil(tester, () => find.byKey(_row).evaluate().isNotEmpty);
  }

  String? subtitle(WidgetTester tester) =>
      (tester.widget<ListTile>(find.byKey(_row)).subtitle! as Text).data;

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(_row));
    await pumpUntil(
      tester,
      () => find
          .byKey(const Key('owntalk-background-sheet'))
          .evaluate()
          .isNotEmpty,
    );
    // Let the sheet finish sliding in before anything inside it is tapped.
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> tapKey(WidgetTester tester, Key key) async {
    await tester.tap(find.byKey(key));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Map<String, Object?> lastPatch() =>
      (jsonDecode(server.settingsRequests.last.body)
              as Map<String, Object?>)['settings']!
          as Map<String, Object?>;

  group('the sheet', () {
    testWidgets('shows only the kinds the server supports', (tester) async {
      server.capability = ownTalkCapabilityJson(
        features: ['appearance.colors'],
        presets: null,
        limits: null,
      );
      await show(tester);
      await openSheet(tester);
      // One kind: no tabs, the palette is simply there.
      expect(find.byKey(const Key('owntalk-background-tabs')), findsNothing);
      expect(find.byKey(const Key('color-swatch-#1E3A5F')), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('offers a wallpaper only when both sides know its ID', (
      tester,
    ) async {
      server.capability = ownTalkCapabilityJson(
        presets: ['grid', 'neon', 'aurora'],
      );
      await show(tester);
      await openSheet(tester);
      await tapKey(tester, _tabPreset);
      expect(find.byKey(const Key('owntalk-preset-grid')), findsOneWidget);
      expect(find.byKey(const Key('owntalk-preset-aurora')), findsOneWidget);
      expect(find.byKey(const Key('owntalk-preset-neon')), findsNothing);
      expect(find.byKey(const Key('owntalk-preset-dots')), findsNothing);
      await unmount(tester);
    });

    testWidgets('has no wallpaper tab when none of the IDs can be drawn', (
      tester,
    ) async {
      server.capability = ownTalkCapabilityJson(presets: ['neon']);
      await show(tester);
      await openSheet(tester);
      expect(find.byKey(_tabPreset), findsNothing);
      expect(find.byKey(_tabColor), findsOneWidget);
      expect(find.byKey(_tabPhoto), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('opens on the kind in effect and marks the current choice', (
      tester,
    ) async {
      server.setExternally({'chat.backgroundPreset': 'ocean'});
      await show(tester);
      expect(subtitle(tester), 'Ocean');
      await openSheet(tester);
      expect(find.byKey(const Key('owntalk-preset-ocean')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('owntalk-preset-ocean')),
          matching: find.byIcon(Icons.check_circle),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('owntalk-preset-grid')),
          matching: find.byIcon(Icons.check_circle),
        ),
        findsNothing,
      );
      await unmount(tester);
    });

    for (final tab in [_tabColor, _tabPreset, _tabPhoto]) {
      testWidgets('fits a phone held sideways on the ${tab.toString()} tab', (
        tester,
      ) async {
        tester.view
          ..physicalSize = const Size(640, 360)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        server.setExternally({
          'chat.backgroundImage': ownTalkTestSha(ownTalkTestJpeg(3)),
        });
        await show(tester);
        await openSheet(tester);
        await tapKey(tester, tab);
        expect(tester.takeException(), isNull);

        final last = switch (tab) {
          _tabColor => find.byKey(const Key('owntalk-color-custom')),
          _tabPreset => find.byKey(const Key('owntalk-preset-grid')),
          _ => find.byKey(const Key('owntalk-photo-remove')),
        };
        await tester.ensureVisible(last);
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        expect(last, findsOneWidget);
        await unmount(tester);
      });
    }
  });

  group('landscape', () {
    testWidgets('on the photo tab every action scrolls fully into view and '
        'none is fixed in front of another', (tester) async {
      tester.view
        ..physicalSize = const Size(640, 360)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      server.setExternally({
        'chat.backgroundImage': ownTalkTestSha(ownTalkTestJpeg(3)),
      });
      await show(tester);
      await openSheet(tester);
      await tapKey(tester, _tabPhoto);

      // One scroll view carries title, tabs, body and actions.
      final sheet = find.byType(BottomSheet);
      final scroll = find.descendant(
        of: sheet,
        matching: find.byType(SingleChildScrollView),
      );
      expect(scroll, findsOneWidget);
      final viewport = tester.getRect(scroll);

      for (final key in const [
        Key('owntalk-photo-pick'),
        Key('owntalk-photo-remove'),
        Key('owntalk-background-theme'),
      ]) {
        final action = find.descendant(of: scroll, matching: find.byKey(key));
        expect(action, findsOneWidget, reason: '$key');
        await tester.ensureVisible(action);
        await tester.pump(const Duration(milliseconds: 300));
        final rect = tester.getRect(action);
        expect(
          rect.top,
          greaterThanOrEqualTo(viewport.top - 0.5),
          reason: '$key',
        );
        expect(
          rect.bottom,
          lessThanOrEqualTo(viewport.bottom + 0.5),
          reason: '$key',
        );
        // The pixel in the middle of it belongs to that action.
        final hit = tester.hitTestOnBinding(rect.center);
        expect(
          hit.path.any((entry) => entry.target == tester.renderObject(action)),
          isTrue,
          reason: '$key is covered by something else',
        );
      }
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });

    testWidgets('the sheet keeps its title and actions fixed when there is '
        'room', (tester) async {
      server.setExternally({
        'chat.backgroundImage': ownTalkTestSha(ownTalkTestJpeg(3)),
      });
      await show(tester);
      await openSheet(tester);
      await tapKey(tester, _tabPhoto);
      final scroll = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(SingleChildScrollView),
      );
      // Portrait: only the body scrolls, the theme action stays below it.
      expect(
        find.descendant(
          of: scroll,
          matching: find.byKey(const Key('owntalk-background-theme')),
        ),
        findsNothing,
      );
      expect(find.byKey(const Key('owntalk-background-theme')), findsOneWidget);
      await unmount(tester);
    });
  });

  group('accessibility', () {
    testWidgets('the sheet barrier has our own label, not "Scrim"', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await show(tester);
      await openSheet(tester);
      expect(find.bySemanticsLabel('Scrim'), findsNothing);
      expect(
        find.bySemanticsLabel('Close the background picker'),
        findsOneWidget,
      );
      semantics.dispose();
      await unmount(tester);
    });
  });

  group('choosing', () {
    testWidgets('a swatch saves the colour with If-Match', (tester) async {
      await show(tester);
      await openSheet(tester);
      await tapKey(tester, const Key('color-swatch-#1E3A5F'));
      await pumpUntil(tester, () => subtitle(tester) == '#1E3A5F');
      expect(server.settingsRequests.last.method, 'PATCH');
      expect(server.settingsRequests.last.headers['If-Match'], '"r0"');
      expect(lastPatch(), {'chat.backgroundColor': '#1E3A5F'});
      await unmount(tester);
    });

    testWidgets('a wallpaper saves just the preset', (tester) async {
      await show(tester);
      await openSheet(tester);
      await tapKey(tester, _tabPreset);
      await tapKey(tester, const Key('owntalk-preset-aurora'));
      await pumpUntil(tester, () => subtitle(tester) == 'Aurora');
      expect(lastPatch(), {'chat.backgroundPreset': 'aurora'});
      await unmount(tester);
    });

    testWidgets('a colour also clears the wallpaper and photo that would '
        'hide it', (tester) async {
      final sha = ownTalkTestSha(ownTalkTestJpeg(3));
      server.setExternally({
        'chat.backgroundPreset': 'ocean',
        'chat.backgroundImage': sha,
      });
      await show(tester);
      expect(subtitle(tester), 'Your photo');
      await openSheet(tester);
      await tapKey(tester, _tabColor);
      await tapKey(tester, const Key('color-swatch-#7A2E3A'));
      await pumpUntil(tester, () => subtitle(tester) == '#7A2E3A');
      expect(lastPatch(), {
        'chat.backgroundColor': '#7A2E3A',
        'chat.backgroundImage': null,
        'chat.backgroundPreset': null,
      });
      await unmount(tester);
    });

    testWidgets('a wallpaper clears the photo but keeps the colour', (
      tester,
    ) async {
      server.setExternally({
        'chat.backgroundColor': '#7A2E3A',
        'chat.backgroundImage': ownTalkTestSha(ownTalkTestJpeg(3)),
      });
      await show(tester);
      await openSheet(tester);
      await tapKey(tester, _tabPreset);
      await tapKey(tester, const Key('owntalk-preset-dots'));
      await pumpUntil(tester, () => subtitle(tester) == 'Dots');
      expect(lastPatch(), {
        'chat.backgroundPreset': 'dots',
        'chat.backgroundImage': null,
      });
      expect(server.settings['chat.backgroundColor'], '#7A2E3A');
      await unmount(tester);
    });

    testWidgets('"Follow the theme" clears all three', (tester) async {
      server.setExternally({
        'chat.backgroundColor': '#7A2E3A',
        'chat.backgroundPreset': 'grid',
        'chat.backgroundImage': ownTalkTestSha(ownTalkTestJpeg(3)),
      });
      await show(tester);
      await openSheet(tester);
      await tapKey(tester, const Key('owntalk-background-theme'));
      await pumpUntil(tester, () => subtitle(tester) == 'Follow the theme');
      expect(lastPatch(), {
        'chat.backgroundColor': null,
        'chat.backgroundPreset': null,
        'chat.backgroundImage': null,
      });
      await unmount(tester);
    });

    testWidgets('choosing what is already in effect sends nothing', (
      tester,
    ) async {
      server.setExternally({'chat.backgroundColor': '#1E3A5F'});
      await show(tester);
      final before = server.settingsRequests.length;
      await openSheet(tester);
      await tapKey(tester, const Key('color-swatch-#1E3A5F'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(server.settingsRequests.length, before);
      await unmount(tester);
    });

    testWidgets('a preset the client cannot draw reads as the theme', (
      tester,
    ) async {
      server.capability = ownTalkCapabilityJson(presets: ['neon', 'grid']);
      server.setExternally({'chat.backgroundPreset': 'neon'});
      await show(tester);
      expect(subtitle(tester), 'Follow the theme');
      await unmount(tester);
    });

    testWidgets('"Custom" opens the hex field', (tester) async {
      await show(tester);
      await openSheet(tester);
      await tapKey(tester, const Key('owntalk-color-custom'));
      await pumpUntil(
        tester,
        () =>
            find.byKey(const Key('owntalk-shared-field')).evaluate().isNotEmpty,
      );
      await tester.enterText(
        find.byKey(const Key('owntalk-shared-field')),
        '#abcdef',
      );
      await tester.tap(find.byKey(const Key('owntalk-shared-save')));
      await pumpUntil(tester, () => subtitle(tester) == '#ABCDEF');
      expect(lastPatch(), {'chat.backgroundColor': '#ABCDEF'});
      await unmount(tester);
    });
  });

  group('photo', () {
    testWidgets('is picked with the server limits, uploaded and shown', (
      tester,
    ) async {
      await show(tester);
      await openSheet(tester);
      await tapKey(tester, _tabPhoto);
      await tapKey(tester, const Key('owntalk-photo-pick'));
      await pumpUntil(tester, () => subtitle(tester) == 'Your photo');

      expect(pickerCalls, [(maxBytes: 10485760, maxEdge: 2560)]);
      final request = server.uploads.single;
      expect(request.method, 'PUT');
      expect(request.headers['If-Match'], '"r0"');
      expect(request.headers['Content-Type'], 'image/jpeg');
      expect(request.bodyBytes, orderedEquals(ownTalkTestJpeg(3)));
      expect(
        server.settings['chat.backgroundImage'],
        ownTalkTestSha(ownTalkTestJpeg(3)),
      );
      await unmount(tester);
    });

    testWidgets('cancelling the picker uploads nothing', (tester) async {
      pick = () async => null;
      await show(tester);
      await openSheet(tester);
      await tapKey(tester, _tabPhoto);
      await tapKey(tester, const Key('owntalk-photo-pick'));
      await pumpUntil(tester, () => pickerCalls.isNotEmpty);
      await tester.pump(const Duration(milliseconds: 100));
      expect(server.uploads, isEmpty);
      expect(subtitle(tester), 'Follow the theme');
      expect(tester.widget<ListTile>(find.byKey(_row)).onTap, isNotNull);
      await unmount(tester);
    });

    testWidgets('a picker that fails explains why and uploads nothing', (
      tester,
    ) async {
      for (final entry in {
        OwnTalkPhotoError.unsupportedType:
            'The server accepts only JPEG, PNG or WebP photos.',
        OwnTalkPhotoError.unreadable: 'The photo could not be read.',
        OwnTalkPhotoError.tooLarge:
            'The photo could not be reduced below 10 MB.',
      }.entries) {
        pick = () async => throw OwnTalkPhotoException(entry.key);
        await show(tester);
        await openSheet(tester);
        await tapKey(tester, _tabPhoto);
        await tapKey(tester, const Key('owntalk-photo-pick'));
        await pumpUntil(
          tester,
          () => find.text(entry.value).evaluate().isNotEmpty,
        );
        expect(server.uploads, isEmpty);
        await unmount(tester);
      }
    });

    testWidgets('server refusals get a plain message', (tester) async {
      for (final entry in {
        413: 'The server rejected the photo as too large.',
        415: 'The server accepts only JPEG, PNG or WebP photos.',
        507: 'The background storage on this server is full.',
        429: 'Too many uploads. Try again later.',
        503: 'The shared appearance could not be saved.',
      }.entries) {
        server.failUploadWith = entry.key;
        await show(tester);
        await openSheet(tester);
        await tapKey(tester, _tabPhoto);
        await tapKey(tester, const Key('owntalk-photo-pick'));
        await pumpUntil(
          tester,
          () => find.text(entry.value).evaluate().isNotEmpty,
        );
        expect(subtitle(tester), 'Follow the theme', reason: '${entry.key}');
        await unmount(tester);
      }
    });

    testWidgets('an image the server cannot decode is named as such', (
      tester,
    ) async {
      server
        ..failUploadWith = 400
        ..failUploadError = 'invalid_image';
      await show(tester);
      await openSheet(tester);
      await tapKey(tester, _tabPhoto);
      await tapKey(tester, const Key('owntalk-photo-pick'));
      await pumpUntil(
        tester,
        () => find
            .text('That file could not be read as an image.')
            .evaluate()
            .isNotEmpty,
      );
      await unmount(tester);
    });

    testWidgets('a photo changed meanwhile asks, and applies on the new '
        'revision when told to', (tester) async {
      await show(tester);
      server.beforePatch = () => server.setExternally({
        'chat.backgroundImage': ownTalkTestSha(ownTalkTestJpeg(9)),
      });
      await openSheet(tester);
      await tapKey(tester, _tabPhoto);
      await tapKey(tester, const Key('owntalk-photo-pick'));
      await pumpUntil(
        tester,
        () => find
            .byKey(const Key('owntalk-conflict-dialog'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text('Photo: Your photo'), findsOneWidget);

      await tester.tap(find.byKey(const Key('owntalk-conflict-apply')));
      await pumpUntil(tester, () => server.uploads.length == 2);
      expect(server.uploads.last.headers['If-Match'], '"r1"');
      await pumpUntil(
        tester,
        () =>
            server.settings['chat.backgroundImage'] ==
            ownTalkTestSha(ownTalkTestJpeg(3)),
      );
      await pumpUntil(
        tester,
        () => find.byType(SnackBar).evaluate().isNotEmpty,
      );
      await unmount(tester);
    });

    testWidgets('keeping theirs after a conflict uploads once', (tester) async {
      await show(tester);
      server.beforePatch = () => server.setExternally({
        'chat.backgroundImage': ownTalkTestSha(ownTalkTestJpeg(9)),
      });
      await openSheet(tester);
      await tapKey(tester, _tabPhoto);
      await tapKey(tester, const Key('owntalk-photo-pick'));
      await pumpUntil(
        tester,
        () => find
            .byKey(const Key('owntalk-conflict-keep'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.byKey(const Key('owntalk-conflict-keep')));
      await pumpUntil(tester, () => subtitle(tester) == 'Your photo');
      expect(server.uploads, hasLength(1));
      await unmount(tester);
    });

    testWidgets('can be removed again', (tester) async {
      server.setExternally({
        'chat.backgroundImage': ownTalkTestSha(ownTalkTestJpeg(3)),
      });
      await show(tester);
      await openSheet(tester);
      await tapKey(tester, const Key('owntalk-photo-remove'));
      await pumpUntil(tester, () => subtitle(tester) == 'Follow the theme');
      expect(lastPatch(), {'chat.backgroundImage': null});
      expect(server.uploads, isEmpty);
      await unmount(tester);
    });

    testWidgets('the hint names the server limit', (tester) async {
      server.capability = ownTalkCapabilityJson(
        limits: {'maxImageBytes': 2621440, 'maxImageEdge': 1600},
      );
      await show(tester);
      await openSheet(tester);
      await tapKey(tester, _tabPhoto);
      expect(
        find.text(
          'JPEG, PNG or WebP, up to 2.5 MB. The server scales it down.',
        ),
        findsOneWidget,
      );
      await unmount(tester);
    });
  });

  group('read-only', () {
    testWidgets('shows the current wallpaper or photo but cannot change it', (
      tester,
    ) async {
      server
        ..canEdit = false
        ..setExternally({'chat.backgroundPreset': 'forest'});
      await show(tester);
      expect(subtitle(tester), 'Forest');
      expect(tester.widget<ListTile>(find.byKey(_row)).onTap, isNull);
      await tester.tap(find.byKey(_row), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('owntalk-background-sheet')), findsNothing);
      await unmount(tester);

      server.setExternally({
        'chat.backgroundImage': ownTalkTestSha(ownTalkTestJpeg(3)),
      });
      await show(tester);
      await pumpUntil(tester, () => subtitle(tester) == 'Your photo');
      expect(tester.widget<ListTile>(find.byKey(_row)).onTap, isNull);
      await unmount(tester);
    });
  });
}
