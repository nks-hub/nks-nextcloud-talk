import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/checklist_widget.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_extensions_service.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_room_extras.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_settings_store.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'owntalk_extensions_test_support.dart';
import 'test_support.dart';

const source = '☑ Shopping\n- [ ] Apples\n- [ ] Flour';
void main() {
  late AppDatabase db;
  late FakeOwnTalkServer server;
  late HttpNextcloudApi api;
  late List<http.Request> calls;
  late Set<int> checks;
  late String revision;
  setUp(() async {
    db = openTestDatabase();
    await AccountRepository(db).upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid/nc',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026),
    );
    server = FakeOwnTalkServer(
      capability: ownTalkCapabilityJson(
        features: ['chat.checklists', 'chat.unansweredReminders'],
      ),
    );
    calls = [];
    checks = {};
    revision = sha256.convert(utf8.encode(source)).toString();
    api = HttpNextcloudApi(
      client: MockClient((r) async {
        if (!r.url.path.contains('/checklist/') &&
            !r.url.path.contains('/followup/')) {
          return server.handle(r);
        }
        calls.add(r);
        expect(
          r.url.path,
          startsWith(
            '/nc/ocs/v2.php/apps/owntalk_extensions/api/v1/room/$ownTalkTestToken/',
          ),
        );
        if (r.url.path.endsWith('/followup/42')) {
          return ocsResponse(200, {'dueAt': null});
        }
        expect(r.url.path, endsWith('/checklist/42'));
        if (r.method == 'PUT') {
          final body = jsonDecode(r.body) as Map;
          expect(body['revision'], revision);
          if (body['checked'] == true) {
            checks.add(body['item'] as int);
          } else {
            checks.remove(body['item']);
          }
        }
        return ocsResponse(200, {
          'revision': revision,
          'checked': checks.toList(),
          'canEdit': true,
        });
      }),
    );
  });
  tearDown(() => db.close());
  List<Override> overrides() => [
    appDatabaseProvider.overrideWithValue(db),
    credentialVaultProvider.overrideWithValue(
      MemoryCredentialVault()..values['account-a'] = 'fixture-password',
    ),
    nextcloudApiProvider.overrideWithValue(api),
    ownTalkSettingsStoreProvider.overrideWith(
      (_) => Future<OwnTalkSettingsStore>.error(StateError('no disk')),
    ),
    appLifecycleResumeEventsProvider.overrideWithValue(
      const Stream<void>.empty(),
    ),
  ];
  Widget preview() => ProviderScope(
    overrides: overrides(),
    child: localizedTestApp(
      home: Scaffold(
        body: SharedChecklistPreview(
          accountId: 'account-a',
          token: ownTalkTestToken,
          id: 42,
          lines: checklistLines(source)!,
          source: source,
          fallback: const Text('plain checklist'),
        ),
      ),
    ),
  );
  testWidgets(
    'open, check an item and observe an edit from another participant',
    (tester) async {
      await tester.pumpWidget(preview());
      await pumpUntilCondition(
        tester,
        () => find.text('Shopping').hitTestable().evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Shopping'));
      bool ready() => tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .any((c) => c.onChanged != null);
      await pumpUntilCondition(tester, ready);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Apples'));
      await pumpUntilCondition(tester, () => checks.contains(0) && ready());
      expect(checks, {0});
      checks.add(1);
      await tester.tap(find.byIcon(Icons.refresh));
      await pumpUntilCondition(
        tester,
        () =>
            tester
                    .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
                    .where((c) => c.value == true)
                    .length ==
                2 &&
            ready(),
      );
      expect(
        tester
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .map((c) => c.value),
        [true, true],
      );
      revision = 'different-source';
      await tester.tap(find.byIcon(Icons.refresh));
      await pumpUntilCondition(
        tester,
        () =>
            !ready() && find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(
        tester
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .every((c) => c.onChanged == null),
        true,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('a server without the new capability shows ordinary content', (
    tester,
  ) async {
    server.capability = ownTalkCapabilityJson();
    await tester.pumpWidget(preview());
    await pumpUntilCondition(tester, () => server.settingsRequests.isNotEmpty);
    expect(find.text('plain checklist'), findsOneWidget);
    expect(find.byIcon(Icons.checklist_rounded), findsNothing);
    expect(calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  test(
    'a missing extension cannot be contacted even through a stale UI action',
    () async {
      server.capability = null;
      final container = ProviderContainer(overrides: overrides());
      addTearDown(container.dispose);
      for (final tool in RoomMessageTool.values) {
        await expectLater(
          container
              .read(ownTalkExtensionsServiceProvider)
              .roomMessageTool(
                accountId: 'account-a',
                roomToken: ownTalkTestToken,
                messageId: 42,
                tool: tool,
              ),
          throwsA(isA<OwnTalkExtensionsException>()),
        );
      }
      expect(calls, isEmpty);
    },
  );
  test(
    'conditional reminder writes and deletes only the requested message',
    () async {
      final container = ProviderContainer(overrides: overrides());
      addTearDown(container.dispose);
      final service = container.read(ownTalkExtensionsServiceProvider);
      for (final method in ['PUT', 'DELETE']) {
        await service.roomMessageTool(
          accountId: 'account-a',
          roomToken: ownTalkTestToken,
          messageId: 42,
          tool: RoomMessageTool.followup,
          method: method,
          values: method == 'PUT'
              ? {'dueAt': 1900000000, 'threadId': 40}
              : null,
        );
      }
      expect(calls.map((r) => r.method), ['PUT', 'DELETE']);
      expect(jsonDecode(calls.first.body), {
        'dueAt': 1900000000,
        'threadId': 40,
      });
    },
  );
}
