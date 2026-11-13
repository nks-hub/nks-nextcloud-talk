import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_background_surface.dart';
import 'package:nextcloudtalk/features/chat/chat_background_theme.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/chat_appearance.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_room_extras.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_settings_store.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/shared_appearance_section.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'owntalk_extensions_test_support.dart';
import 'test_support.dart';

const _background = Key('owntalk-shared-background');
const _ownBubble = Key('owntalk-shared-bubble-owncolor');
const _quickEmoji = Key('owntalk-shared-composer-quickemoji');

void main() {
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

  List<Override> overrides() => [
    appDatabaseProvider.overrideWithValue(database),
    credentialVaultProvider.overrideWithValue(
      MemoryCredentialVault()..values['account-a'] = 'fixture-password',
    ),
    nextcloudApiProvider.overrideWithValue(
      HttpNextcloudApi(client: server.client),
    ),
    // File I/O never completes inside the widget-test clock; the cache is
    // covered by the store tests.
    ownTalkSettingsStoreProvider.overrideWith(
      (ref) => Future<OwnTalkSettingsStore>.error(StateError('no store')),
    ),
    appLifecycleResumeEventsProvider.overrideWithValue(
      const Stream<void>.empty(),
    ),
  ];

  Widget sectionApp({int roomType = 2, bool federated = false}) =>
      ProviderScope(
        overrides: overrides(),
        child: localizedTestApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: OwnTalkSharedAppearanceSection(
                accountId: 'account-a',
                roomToken: ownTalkTestToken,
                roomType: roomType,
                federated: federated,
              ),
            ),
          ),
        ),
      );

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() condition) =>
      pumpUntilCondition(tester, condition);

  /// The hex field sits behind the "Custom" entry of the palette or sheet.
  Future<void> openCustom(WidgetTester tester, Key custom) async {
    await pumpUntil(tester, () => find.byKey(custom).evaluate().isNotEmpty);
    // Let a bottom sheet finish sliding in before it is tapped.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(custom));
  }

  String? subtitleOf(WidgetTester tester, Key row) {
    final tile = find.byKey(row);
    if (tile.evaluate().isEmpty) {
      return null;
    }
    return (tester.widget<ListTile>(tile).subtitle! as Text).data;
  }

  group('section visibility', () {
    testWidgets('is hidden and silent without the capability', (tester) async {
      server.capability = null;
      await tester.pumpWidget(sectionApp());
      await pumpUntil(tester, () => server.requests.isNotEmpty);
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(const Key('owntalk-shared-section')), findsNothing);
      expect(server.settingsRequests, isEmpty);
      await unmount(tester);
    });

    testWidgets('is hidden for a federated conversation', (tester) async {
      await tester.pumpWidget(sectionApp(federated: true));
      await pumpUntil(tester, () => server.settingsRequests.isNotEmpty);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('owntalk-shared-section')), findsNothing);
      await unmount(tester);
    });

    testWidgets('is hidden for a room type the server does not cover', (
      tester,
    ) async {
      await tester.pumpWidget(sectionApp(roomType: 6));
      // The account lookup is real database I/O; wait until it got through.
      await pumpUntil(tester, () => server.settingsRequests.isNotEmpty);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('owntalk-shared-section')), findsNothing);
      await unmount(tester);
    });

    testWidgets('only offers the features the server lists', (tester) async {
      server.capability = ownTalkCapabilityJson(
        features: ['appearance.colors'],
      );
      await tester.pumpWidget(sectionApp());
      await pumpUntil(
        tester,
        () => find.byKey(_background).evaluate().isNotEmpty,
      );
      expect(find.byKey(_ownBubble), findsNothing);
      expect(find.byKey(_quickEmoji), findsNothing);
      await unmount(tester);
    });
  });

  group('editing', () {
    testWidgets('saves a colour with If-Match and shows the server value', (
      tester,
    ) async {
      await tester.pumpWidget(sectionApp());
      await pumpUntil(
        tester,
        () => find.byKey(_background).evaluate().isNotEmpty,
      );
      expect(find.byKey(const Key('owntalk-shared-read-only')), findsNothing);
      expect(subtitleOf(tester, _background), 'Follow the theme');

      await tester.tap(find.byKey(_background));
      await openCustom(tester, const Key('owntalk-color-custom'));
      await pumpUntil(
        tester,
        () =>
            find.byKey(const Key('owntalk-shared-field')).evaluate().isNotEmpty,
      );
      await tester.enterText(
        find.byKey(const Key('owntalk-shared-field')),
        '#1e3a5f',
      );
      await tester.tap(find.byKey(const Key('owntalk-shared-save')));
      await pumpUntil(
        tester,
        () => subtitleOf(tester, _background) == '#1E3A5F',
      );

      final patch = server.settingsRequests.last;
      expect(patch.method, 'PATCH');
      expect(patch.headers['If-Match'], '"r0"');
      expect(server.settings['chat.backgroundColor'], '#1E3A5F');
      await unmount(tester);
    });

    testWidgets('rejects an invalid colour without a request', (tester) async {
      await tester.pumpWidget(sectionApp());
      await pumpUntil(
        tester,
        () => find.byKey(_background).evaluate().isNotEmpty,
      );
      await tester.tap(find.byKey(_background));
      await openCustom(tester, const Key('owntalk-color-custom'));
      await pumpUntil(
        tester,
        () =>
            find.byKey(const Key('owntalk-shared-field')).evaluate().isNotEmpty,
      );
      await tester.enterText(
        find.byKey(const Key('owntalk-shared-field')),
        'magenta',
      );
      await tester.tap(find.byKey(const Key('owntalk-shared-save')));
      await pumpUntil(
        tester,
        () => find.byType(SnackBar).evaluate().isNotEmpty,
      );
      expect(find.text('That value is not accepted.'), findsOneWidget);
      expect(
        server.settingsRequests.where((r) => r.method == 'PATCH'),
        isEmpty,
      );
      await unmount(tester);
    });

    testWidgets('an empty value clears the field', (tester) async {
      server.setExternally({'bubble.ownColor': '#2F6FEB'});
      await tester.pumpWidget(sectionApp());
      await pumpUntil(
        tester,
        () => subtitleOf(tester, _ownBubble) == '#2F6FEB',
      );
      await tester.tap(find.byKey(_ownBubble));
      await pumpUntil(
        tester,
        () =>
            find.byKey(const Key('color-palette-theme')).evaluate().isNotEmpty,
      );
      await tester.tap(find.byKey(const Key('color-palette-theme')));
      await pumpUntil(
        tester,
        () => subtitleOf(tester, _ownBubble) == 'Follow the theme',
      );
      expect(server.settings['bubble.ownColor'], isNull);
      await unmount(tester);
    });

    testWidgets('saves the quick emoji', (tester) async {
      await tester.pumpWidget(sectionApp());
      await pumpUntil(
        tester,
        () => find.byKey(_quickEmoji).evaluate().isNotEmpty,
      );
      await tester.tap(find.byKey(_quickEmoji));
      await pumpUntil(
        tester,
        () =>
            find.byKey(const Key('owntalk-shared-field')).evaluate().isNotEmpty,
      );
      await tester.enterText(
        find.byKey(const Key('owntalk-shared-field')),
        '\u{1F44D}',
      );
      await tester.tap(find.byKey(const Key('owntalk-shared-save')));
      await pumpUntil(
        tester,
        () => server.settings['composer.quickEmoji'] != null,
      );
      expect(server.settings['composer.quickEmoji'], '\u{1F44D}');
      await unmount(tester);
    });
  });

  group('read-only', () {
    testWidgets('shows the values and explains who may change them', (
      tester,
    ) async {
      server
        ..canEdit = false
        ..setExternally({'chat.backgroundColor': '#1E3A5F'});
      await tester.pumpWidget(sectionApp());
      await pumpUntil(
        tester,
        () => subtitleOf(tester, _background) == '#1E3A5F',
      );

      expect(
        find.text('Only moderators can change the shared appearance.'),
        findsOneWidget,
      );
      expect(tester.widget<ListTile>(find.byKey(_background)).onTap, isNull);
      await tester.tap(find.byKey(_background), warnIfMissed: false);
      await tester.pump();
      expect(find.byKey(const Key('owntalk-shared-dialog')), findsNothing);
      await unmount(tester);
    });

    testWidgets('without Talk roles it does not blame the moderators', (
      tester,
    ) async {
      server
        ..capability = ownTalkCapabilityJson(acl: 'membership')
        ..canEdit = false
        ..setExternally({'chat.backgroundColor': '#1E3A5F'});
      await tester.pumpWidget(sectionApp());
      await pumpUntil(
        tester,
        () => subtitleOf(tester, _background) == '#1E3A5F',
      );

      expect(
        find.text('Only moderators can change the shared appearance.'),
        findsNothing,
      );
      expect(find.textContaining('cannot read Talk roles'), findsOneWidget);
      await unmount(tester);
    });
  });

  group('conflict', () {
    testWidgets(
      'shows the server value and re-applies on the new revision on request',
      (tester) async {
        await tester.pumpWidget(sectionApp());
        await pumpUntil(
          tester,
          () => find.byKey(_ownBubble).evaluate().isNotEmpty,
        );
        server.beforePatch = () =>
            server.setExternally({'bubble.ownColor': '#00FF00'});

        await tester.tap(find.byKey(_ownBubble));
        await openCustom(tester, const Key('color-palette-custom'));
        await pumpUntil(
          tester,
          () => find
              .byKey(const Key('owntalk-shared-field'))
              .evaluate()
              .isNotEmpty,
        );
        await tester.enterText(
          find.byKey(const Key('owntalk-shared-field')),
          '#FF0000',
        );
        await tester.tap(find.byKey(const Key('owntalk-shared-save')));
        await pumpUntil(
          tester,
          () => find
              .byKey(const Key('owntalk-conflict-dialog'))
              .evaluate()
              .isNotEmpty,
        );

        expect(find.text('Someone changed this meanwhile'), findsOneWidget);
        expect(find.text('Your message bubbles: #00FF00'), findsOneWidget);
        expect(server.settings['bubble.ownColor'], '#00FF00');

        await tester.tap(find.byKey(const Key('owntalk-conflict-apply')));
        await pumpUntil(
          tester,
          () => server.settings['bubble.ownColor'] == '#FF0000',
        );
        expect(server.settingsRequests.last.headers['If-Match'], '"r1"');
        await pumpUntil(
          tester,
          () => subtitleOf(tester, _ownBubble) == '#FF0000',
        );
        await unmount(tester);
      },
    );

    testWidgets('a conflict that already holds the wanted value counts as '
        'saved, without the conflict dialog', (tester) async {
      await tester.pumpWidget(sectionApp());
      await pumpUntil(
        tester,
        () => find.byKey(_ownBubble).evaluate().isNotEmpty,
      );
      // The first attempt landed but its answer was lost; the server already
      // holds exactly what this write asks for.
      server.beforePatch = () =>
          server.setExternally({'bubble.ownColor': '#FF0000'});

      await tester.tap(find.byKey(_ownBubble));
      await openCustom(tester, const Key('color-palette-custom'));
      await pumpUntil(
        tester,
        () =>
            find.byKey(const Key('owntalk-shared-field')).evaluate().isNotEmpty,
      );
      await tester.enterText(
        find.byKey(const Key('owntalk-shared-field')),
        '#FF0000',
      );
      await tester.tap(find.byKey(const Key('owntalk-shared-save')));
      await pumpUntil(
        tester,
        () => subtitleOf(tester, _ownBubble) == '#FF0000',
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('owntalk-conflict-dialog')), findsNothing);
      await unmount(tester);
    });

    testWidgets('keeping theirs leaves the server value alone', (tester) async {
      await tester.pumpWidget(sectionApp());
      await pumpUntil(
        tester,
        () => find.byKey(_ownBubble).evaluate().isNotEmpty,
      );
      server.beforePatch = () =>
          server.setExternally({'bubble.ownColor': '#00FF00'});
      await tester.tap(find.byKey(_ownBubble));
      await openCustom(tester, const Key('color-palette-custom'));
      await pumpUntil(
        tester,
        () =>
            find.byKey(const Key('owntalk-shared-field')).evaluate().isNotEmpty,
      );
      await tester.enterText(
        find.byKey(const Key('owntalk-shared-field')),
        '#FF0000',
      );
      await tester.tap(find.byKey(const Key('owntalk-shared-save')));
      await pumpUntil(
        tester,
        () => find
            .byKey(const Key('owntalk-conflict-keep'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.byKey(const Key('owntalk-conflict-keep')));
      await pumpUntil(
        tester,
        () => subtitleOf(tester, _ownBubble) == '#00FF00',
      );
      expect(server.settings['bubble.ownColor'], '#00FF00');
      expect(
        server.settingsRequests.where((r) => r.method == 'PATCH'),
        hasLength(1),
      );
      await unmount(tester);
    });
  });

  group('chat surface', () {
    Widget surfaceApp({String? local, ThemeData? theme}) => ProviderScope(
      overrides: [
        ...overrides(),
        chatBackgroundProvider.overrideWith(
          (ref, key) => Stream<String?>.value(local),
        ),
      ],
      child: MaterialApp(
        theme: theme ?? AppTheme.light(),
        home: const ChatBackgroundSurface(
          accountId: 'account-a',
          roomToken: ownTalkTestToken,
          sharedSettings: true,
          child: SizedBox.expand(),
        ),
      ),
    );

    Color surfaceColor(WidgetTester tester) => tester
        .widget<Material>(find.byKey(const Key('chat-background-surface')))
        .color!;

    ColorScheme schemeOf(WidgetTester tester) => Theme.of(
      tester.element(find.byKey(const Key('chat-background-surface'))),
    ).colorScheme;

    testWidgets('applies the shared colour through the contrast fallback', (
      tester,
    ) async {
      server.setExternally({'chat.backgroundColor': '#FF00FF'});
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        await tester.pumpWidget(surfaceApp(theme: theme));
        await pumpUntil(
          tester,
          () => surfaceColor(tester) != schemeOf(tester).surface,
        );
        final scheme = schemeOf(tester);
        expect(
          surfaceColor(tester),
          safeChatBackground(const Color(0xFFFF00FF), scheme),
        );
        expect(
          chatBackgroundContrast(surfaceColor(tester), scheme.onSurface),
          greaterThanOrEqualTo(4.5),
        );
        await unmount(tester);
      }
    });

    testWidgets('the colour set on this device wins over the shared one', (
      tester,
    ) async {
      server.setExternally({'chat.backgroundColor': '#FF00FF'});
      await tester.pumpWidget(surfaceApp(local: '#123456'));
      await pumpUntil(tester, () => server.settingsRequests.isNotEmpty);
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        surfaceColor(tester),
        safeChatBackground(const Color(0xFF123456), schemeOf(tester)),
      );
      await unmount(tester);
    });

    testWidgets('without the extension the theme surface is used', (
      tester,
    ) async {
      server.capability = null;
      await tester.pumpWidget(surfaceApp());
      await pumpUntil(tester, () => server.requests.isNotEmpty);
      await tester.pump(const Duration(milliseconds: 50));
      expect(surfaceColor(tester), schemeOf(tester).surface);
      expect(server.settingsRequests, isEmpty);
      await unmount(tester);
    });

    testWidgets('bubbles read the shared colours', (tester) async {
      server.setExternally({
        'bubble.ownColor': '#101010',
        'bubble.ownTextColor': '#202020',
      });
      late BuildContext inner;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...overrides(),
            chatBackgroundProvider.overrideWith(
              (ref, key) => Stream<String?>.value(null),
            ),
          ],
          child: MaterialApp(
            home: ChatBackgroundSurface(
              accountId: 'account-a',
              roomToken: ownTalkTestToken,
              sharedSettings: true,
              child: Builder(
                builder: (context) {
                  inner = context;
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      );
      await pumpUntil(
        tester,
        () => SharedChatAppearance.maybeOf(inner)?.ownBubble != null,
      );
      final appearance = SharedChatAppearance.maybeOf(inner)!;
      expect(appearance.ownBubble, '#101010');
      expect(appearance.otherBubble, isNull);
      await unmount(tester);
    });
  });

  group('bubble colours', () {
    final scheme = AppTheme.light().colorScheme;

    test('are the theme pairing when nothing is shared', () {
      final own = resolveBubbleColors(outgoing: true, scheme: scheme);
      expect(own.background, scheme.primaryContainer);
      expect(own.foreground, scheme.onPrimaryContainer);
      expect(own.shared, isFalse);
      final other = resolveBubbleColors(outgoing: false, scheme: scheme);
      expect(other.background, scheme.surfaceContainerHigh);
      expect(other.foreground, scheme.onSurface);
      expect(other.meta, scheme.onSurfaceVariant);
    });

    test('keep a shared text colour that reads on the bubble', () {
      final colors = resolveBubbleColors(
        outgoing: true,
        scheme: scheme,
        sharedBubble: '#1E3A5F',
        sharedText: '#FFFFFF',
      );
      expect(colors.background, const Color(0xFF1E3A5F));
      expect(colors.foreground, const Color(0xFFFFFFFF));
      expect(colors.shared, isTrue);
    });

    test('replace a text colour below 4.5:1 with black or white', () {
      for (final entry in {
        '#FFFF00': const Color(0xFF000000),
        '#101010': const Color(0xFFFFFFFF),
      }.entries) {
        final colors = resolveBubbleColors(
          outgoing: false,
          scheme: scheme,
          sharedBubble: entry.key,
          sharedText: entry.key,
        );
        expect(colors.foreground, entry.value, reason: entry.key);
        expect(
          chatBackgroundContrast(colors.foreground, colors.background),
          greaterThanOrEqualTo(4.5),
        );
      }
    });

    test('check the theme text against a shared bubble colour alone', () {
      final colors = resolveBubbleColors(
        outgoing: true,
        scheme: scheme,
        sharedBubble: '#000000',
      );
      expect(
        chatBackgroundContrast(colors.foreground, colors.background),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('every mid-tone bubble still gets readable text', () {
      for (var value = 0; value <= 0xFF; value += 5) {
        final hex = value.toRadixString(16).padLeft(2, '0').toUpperCase();
        final colors = resolveBubbleColors(
          outgoing: true,
          scheme: scheme,
          sharedBubble: '#$hex$hex$hex',
          sharedText: '#808080',
        );
        expect(
          chatBackgroundContrast(colors.foreground, colors.background),
          greaterThanOrEqualTo(4.5),
          reason: hex,
        );
      }
    });
  });
}
