import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';
import 'package:nextcloudtalk/features/chat/media/photo_notes.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'owntalk_extensions_test_support.dart';
import 'test_support.dart';

void main() {
  late AppDatabase db;
  late StoredAccount account;
  late HttpNextcloudApi api;
  late ChatMediaRepository media;
  late MemoryCredentialVault vault;
  late FakeOwnTalkServer server;
  late List<Map<String, dynamic>> notes;
  late List<http.Request> calls;
  late String version;
  late bool permitted;
  int? writeError;
  setUp(() async {
    db = openTestDatabase();
    account = await AccountRepository(db).upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid/nc',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    vault = MemoryCredentialVault()..values[account.id] = 'fixture-password';
    server = FakeOwnTalkServer(
      capability: ownTalkCapabilityJson(features: ['chat.photoNotes']),
    );
    version = 'revision-a';
    permitted = true;
    writeError = null;
    notes = [];
    calls = [];
    api = HttpNextcloudApi(
      client: MockClient((r) async {
        if (!r.url.path.contains('/photo/')) return server.handle(r);
        calls.add(r);
        final base =
            '/nc/ocs/v2.php/apps/owntalk_extensions/api/v1/room/rooma123/photo/10/47/notes';
        expect(r.url.path, startsWith(base));
        if (!permitted) return ocsResponse(404, {});
        final body = r.method == 'POST'
            ? jsonDecode(r.body) as Map<String, dynamic>
            : null;
        if ((body?['version'] ?? r.url.queryParameters['version']) != version) {
          return ocsResponse(409, {});
        }
        if (body != null) {
          if (writeError case final status?) return ocsResponse(status, {});
          final entry = {
            'id': body['requestId'],
            'author': 'fixture-user',
            'body': body['body'],
          };
          if (r.url.path == base) {
            notes.add({
              ...entry,
              'x': body['x'],
              'y': body['y'],
              'replies': <Map<String, dynamic>>[],
            });
          } else {
            expect(r.url.path, '$base/${notes.single['id']}/replies');
            (notes.single['replies'] as List).add(entry);
          }
        }
        return ocsResponse(200, {
          'version': version,
          'canEdit': true,
          'notes': notes,
        });
      }),
    );
    media = ChatMediaRepository(
      vault,
      client: MockClient((r) async {
        expect(
          r.url.path,
          '/nc/remote.php/dav/files/fixture-user/Talk/picture.png',
        );
        return http.Response.bytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGP6zwAAAgcBApocMXEAAAAASUVORK5CYII=',
          ),
          200,
          headers: {'content-type': 'image/png', 'etag': '"$version"'},
        );
      }),
    );
  });
  tearDown(() async {
    api.close();
    media.close();
    await db.close();
  });
  Widget app() => ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      credentialVaultProvider.overrideWithValue(vault),
      nextcloudApiProvider.overrideWithValue(api),
    ],
    child: localizedTestApp(
      home: Scaffold(
        body: PhotoNotesButton(
          account: account,
          target: (room: 'rooma123', message: 10, file: 47),
          repository: media,
          uri: Uri.parse(
            '${account.serverUrl}/remote.php/dav/files/fixture-user/Talk/picture.png',
          ),
          contentType: 'image/png',
          name: 'picture.png',
        ),
      ),
    ),
  );
  Future<void> ready(WidgetTester t, Finder f) =>
      pumpUntilCondition(t, () => f.hitTestable().evaluate().isNotEmpty);
  Future<void> tap(WidgetTester t, Finder f) async {
    await t.ensureVisible(f);
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(f);
    await t.pump();
  }

  Future<void> open(WidgetTester t) async {
    await t.pumpWidget(app());
    final button = find.byKey(const Key('open-photo-notes'));
    await ready(t, button);
    await tap(t, button);
    await pumpUntilCondition(
      t,
      () =>
          find.text('Add pin').hitTestable().evaluate().isNotEmpty ||
          find.text('Reload photo').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 8),
    );
    expect(
      find.text('Add pin'),
      findsOneWidget,
      reason:
          'requests=${calls.length} text=${t.widgetList<Text>(find.byType(Text)).map((x) => x.data)}',
    );
  }

  for (final width in [390.0, 1180.0]) {
    testWidgets('positions a pin, adds a reply, then reopens at width $width', (
      t,
    ) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = Size(width, 844);
      addTearDown(t.view.reset);
      await open(t);
      await tap(t, find.text('Add pin'));
      final rect = t.getRect(find.byKey(const Key('photo-pin-surface')));
      await t.tapAt(rect.topLeft + Offset(rect.width * .65, rect.height * .3));
      await t.pump();
      await t.enterText(find.byType(TextField), 'This connector?');
      await tap(t, find.widgetWithText(FilledButton, 'Add pin'));
      await pumpUntilCondition(
        t,
        () =>
            notes.length == 1 &&
            find.byKey(const Key('photo-send-reply')).evaluate().isNotEmpty,
      );
      expect(notes.single['x'], closeTo(.65, .005));
      expect(notes.single['y'], closeTo(.3, .005));
      await t.enterText(find.byType(TextField), 'Yes, that one.');
      await tap(t, find.byTooltip('Pin 1'));
      expect(find.text('Yes, that one.'), findsOneWidget);
      await tap(t, find.byKey(const Key('photo-send-reply')));
      await pumpUntilCondition(
        t,
        () => t
            .widgetList<SelectableText>(find.byType(SelectableText))
            .any((w) => w.data == 'Yes, that one.'),
      );
      Navigator.of(t.element(find.byKey(const Key('photo-pin-surface')))).pop();
      await t.pumpAndSettle();
      await tap(t, find.byKey(const Key('open-photo-notes')));
      await ready(t, find.text('This connector?'));
      await tap(t, find.text('This connector?'));
      expect(find.text('Yes, that one.'), findsOneWidget);
      version = 'revision-b';
      await tap(t, find.byTooltip('Refresh'));
      await pumpUntilCondition(
        t,
        () => find.textContaining('The photo changed.').evaluate().isNotEmpty,
      );
      expect(find.text('Yes, that one.'), findsNothing);
      expect(calls.where((c) => c.method == 'POST'), hasLength(2));
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump(const Duration(milliseconds: 50));
    });
  }
  testWidgets(
    'without the capability no notes action or notes request is made',
    (t) async {
      server.capability = null;
      await t.pumpWidget(app());
      await pumpUntilCondition(t, () => server.requests.isNotEmpty);
      await t.pump(const Duration(milliseconds: 150));
      expect(find.byKey(const Key('open-photo-notes')), findsNothing);
      expect(calls, isEmpty);
    },
  );
  testWidgets(
    'zoom, keyboard placement and cancel leave the original photo untouched',
    (t) async {
      await open(t);
      await tap(t, find.byTooltip('Zoom in'));
      final zoom = t
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      expect(zoom.value.getMaxScaleOnAxis(), greaterThan(1));
      await tap(t, find.text('Add pin'));
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      await t.enterText(find.byType(TextField), 'Unsaved');
      await tap(t, find.text('Cancel'));
      expect(zoom.value.getMaxScaleOnAxis(), greaterThan(1));
      expect(notes, isEmpty);
      expect(calls.where((r) => r.method == 'POST'), isEmpty);
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump(const Duration(milliseconds: 50));
    },
  );
  testWidgets('a full photo retains the typed note and original pins', (
    t,
  ) async {
    await open(t);
    await tap(t, find.text('Add pin'));
    await t.tap(find.byKey(const Key('photo-pin-surface')));
    await t.pump();
    await t.enterText(find.byType(TextField), 'Keep this text');
    writeError = 422;
    await tap(t, find.byKey(const Key('photo-save-pin')));
    await pumpUntilCondition(
      t,
      () => find.textContaining('notes limit').evaluate().isNotEmpty,
    );
    expect(
      t.widget<TextField>(find.byType(TextField)).controller!.text,
      'Keep this text',
    );
    expect(find.byKey(const Key('photo-pin-surface')), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(milliseconds: 50));
  });
  testWidgets('losing access hides previously visible replies', (t) async {
    notes.add({
      'id': 'f1',
      'x': .5,
      'y': .2,
      'author': 'first',
      'body': 'private note',
      'replies': [],
    });
    await open(t);
    await ready(t, find.text('private note'));
    permitted = false;
    await tap(t, find.byTooltip('Refresh'));
    await pumpUntilCondition(
      t,
      () =>
          find.text('This photo is no longer available.').evaluate().isNotEmpty,
    );
    expect(find.text('private note'), findsNothing);
    expect(find.byKey(const Key('photo-pin-surface')), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(milliseconds: 50));
  });
}
