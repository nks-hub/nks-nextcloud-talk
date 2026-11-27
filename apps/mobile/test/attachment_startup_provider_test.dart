import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/attachment_repository.dart';
import 'package:nextcloudtalk/features/chat/attachment_service.dart';
import 'package:nextcloudtalk/features/chat/chat_room_pane.dart';
import 'package:nextcloudtalk/network/attachment_transport.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  testWidgets('the room recovers after a late attachment runtime start', (
    tester,
  ) async {
    final fixture = await _attachmentStartupFixture(tester);
    final ready = Completer<AttachmentService>();
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(fixture.database),
        credentialVaultProvider.overrideWithValue(fixture.vault),
        nextcloudApiProvider.overrideWithValue(fixture.api),
        attachmentSourceProvider.overrideWith((_) => fixture.source),
        attachmentServiceProvider.overrideWith((_) => ready.future),
      ],
    );
    addTearDown(container.dispose);
    final provider = chatAttachmentDependenciesProvider((
      accountId: fixture.account.id,
      roomToken: fixture.conversation.token,
      threadId: null,
    ));
    addTearDown(container.listen(provider, (_, _) {}).close);

    expect(container.read(provider).isLoading, isTrue);
    await tester.pump(const Duration(seconds: 31));
    expect(container.read(provider).error, isA<TimeoutException>());

    ready.complete(fixture.service);
    await pumpUntilCondition(
      tester,
      () => container.read(provider).valueOrNull?.profile.enabled == true,
    );
  });

  testWidgets('the composer retry restarts failed attachment initialization', (
    tester,
  ) async {
    final fixture = await _attachmentStartupFixture(tester);
    var startupAttempts = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(fixture.database),
          credentialVaultProvider.overrideWithValue(fixture.vault),
          nextcloudApiProvider.overrideWithValue(fixture.api),
          connectivityWakeEventsProvider.overrideWithValue(
            const Stream.empty(),
          ),
          attachmentSourceProvider.overrideWith((_) => fixture.source),
          attachmentServiceProvider.overrideWith((_) async {
            if (++startupAttempts == 2) {
              throw StateError('Synthetic attachment startup failure');
            }
            return fixture.service;
          }),
        ],
        child: localizedTestApp(
          home: Scaffold(
            body: ChatRoomPane(
              account: fixture.account,
              conversation: fixture.conversation,
            ),
          ),
        ),
      ),
    );

    try {
      final giphy = find.byKey(const Key('open-giphy-picker'));
      bool giphyEnabled() => tester.widget<IconButton>(giphy).onPressed != null;

      await pumpUntilCondition(tester, giphyEnabled);
      final container = ProviderScope.containerOf(tester.element(giphy));
      container.invalidate(attachmentServiceProvider);
      await pumpUntilCondition(
        tester,
        () => container.read(attachmentServiceProvider).hasError,
        pumpBeforeChecking: true,
      );
      await tester.pump();
      expect(giphyEnabled(), isFalse);
      final retry = find.byKey(const Key('retry-media-capabilities'));
      expect(retry, findsOneWidget);

      await tester.tap(retry);
      await pumpUntilCondition(tester, giphyEnabled);
      expect(retry, findsNothing);
      expect(startupAttempts, 3);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
  });

  test(
    'account observation eagerly starts durable attachment recovery',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final started = Completer<void>();
      final pendingService = Completer<AttachmentService>();
      final container = ProviderContainer(
        overrides: <Override>[
          appDatabaseProvider.overrideWithValue(database),
          attachmentServiceProvider.overrideWith((ref) async {
            started.complete();
            return pendingService.future;
          }),
        ],
      );
      addTearDown(container.dispose);

      final subscription = container.listen(
        accountsProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await started.future.timeout(const Duration(seconds: 1));
    },
  );
}

Future<
  ({
    AttachmentService service,
    StoredAccount account,
    CachedConversation conversation,
    AppDatabase database,
    DurableAttachmentSourceStore source,
    MemoryCredentialVault vault,
    HttpNextcloudApi api,
  })
>
_attachmentStartupFixture(WidgetTester tester) async {
  final database = openTestDatabase();
  addTearDown(() async => tester.runAsync(database.close));
  final accounts = AccountRepository(database);
  final vault = MemoryCredentialVault()
    ..values['account-a'] = 'fixture-password';
  final source = DurableAttachmentSourceStore(root: Directory.systemTemp);
  final capabilities = capabilitiesJson(
    talkFeatures: const ['chat-v2', 'chat-reference-id'],
    attachments: const {'allowed': true, 'conversation-subfolders': true},
  );
  final api = HttpNextcloudApi(
    client: MockClient(
      (_) async => http.Response(jsonEncode(capabilities), 200),
    ),
  );
  addTearDown(api.close);
  final attachmentRuntime = (await tester.runAsync(() async {
    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final rooms =
        readFixtureJson(
              'conversation-list/fixtures/conversations-full.response.json',
            )!
            as Map<String, Object?>;
    final ocs = rooms['ocs']! as Map<String, Object?>;
    final room = ConversationRoom.fromJson((ocs['data']! as List).first);
    await accounts.applyAuthoritativeConversation('account-a', room);

    final service = AttachmentService(
      repository: AttachmentRepository(database),
      credentials: vault,
      releaseSource: (attachment) => source.discard(attachment.handle),
      transport: HttpAttachmentTransport(
        client: OfflineClient(),
        sourceProvider: source,
      ),
    );
    await service.ready;
    final conversation = await database
        .select(database.cachedConversations)
        .getSingle();
    return (service: service, account: account, conversation: conversation);
  }))!;
  addTearDown(() async => tester.runAsync(attachmentRuntime.service.close));

  return (
    service: attachmentRuntime.service,
    account: attachmentRuntime.account,
    conversation: attachmentRuntime.conversation,
    database: database,
    source: source,
    vault: vault,
    api: api,
  );
}
