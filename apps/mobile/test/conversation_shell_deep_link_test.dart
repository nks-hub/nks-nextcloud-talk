import 'dart:async';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/outgoing_message_status.dart';
import 'package:nextcloudtalk/features/conversations/conversation_shell.dart';
import 'package:nextcloudtalk/features/conversations/deep_link_bridge.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'test_support.dart';

void main() {
  testWidgets(
    'a launch deep link opens the matching account and room',
    (tester) async {
      final database = openTestDatabase();
      addTearDown(database.close);
      final accounts = AccountRepository(database);
      final vault = MemoryCredentialVault();

      final otherAccount = await accounts.upsertAccount(
        accountId: 'account-other',
        serverUrl: 'https://other.example.invalid',
        loginName: 'other-user',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final targetAccount = await accounts.upsertAccount(
        accountId: 'account-target',
        serverUrl: 'https://cloud.example.invalid',
        loginName: 'target-user',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 2),
      );
      await database
          .into(database.cachedConversations)
          .insert(
            CachedConversationsCompanion.insert(
              accountId: targetAccount.id,
              token: 'roomtoken1',
              displayName: 'Deep link target room',
              description: '',
              lastActivity: 1724300000,
              unreadMessages: 0,
              favorite: false,
              readOnly: const Value(0),
              roomType: const Value(2),
              roomName: const Value('deep-link-room'),
              objectType: const Value(''),
              avatarVersion: const Value(''),
              isCustomAvatar: const Value(false),
              rawJson: '{}',
            ),
          );

      // No app password is stored for either account, so the forced resync
      // that a resolved deep link kicks off fails fast with a caught
      // ConversationSyncException instead of making any HTTP request.
      final api = HttpNextcloudApi(
        client: _CallbackClient((request) async {
          throw StateError('Unexpected HTTP request: ${request.url}');
        }),
      );
      addTearDown(api.close);

      final deepLinkPlatform = _FakeDeepLinkPlatform(
        launchLink: Uri.parse(
          'https://cloud.example.invalid/index.php/call/roomtoken1',
        ),
      );
      addTearDown(deepLinkPlatform.dispose);

      final selectedAccounts = StreamController<StoredAccount?>();
      addTearDown(selectedAccounts.close);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
            credentialVaultProvider.overrideWithValue(vault),
            nextcloudApiProvider.overrideWithValue(api),
            deepLinkPlatformProvider.overrideWithValue(deepLinkPlatform),
            accountsProvider.overrideWith(
              (ref) => Stream.value([otherAccount, targetAccount]),
            ),
            selectedAccountProvider.overrideWith(
              (ref) => selectedAccounts.stream,
            ),
            conversationsProvider.overrideWith(
              (ref, accountId) => Stream.value(const <CachedConversation>[]),
            ),
            // Plain streams, not drift-backed ones: disposing this test's
            // ChatRoomPane would otherwise tear down several live drift
            // StreamProviders at once, which schedules internal drift
            // cleanup timers the fake test clock never reliably drains.
            chatMessagesProvider.overrideWith(
              (ref, key) => Stream.value(const <CachedChatMessage>[]),
            ),
            outgoingMessageStatusesProvider.overrideWith(
              (ref, key) => Stream.value(const <OutgoingMessageStatus>[]),
            ),
            textSendOperationsProvider.overrideWith(
              (ref, key) => Stream.value(const <StoredTextSendOperation>[]),
            ),
            chatScopeProvider.overrideWith((ref, key) => Stream.value(null)),
            chatAttachmentDependenciesProvider.overrideWith(
              (ref, key) => Future<ChatAttachmentDependencies>.error(
                StateError('attachment dependencies are not wired in this suite'),
                StackTrace.empty,
              ),
            ),
          ],
          child: localizedTestApp(home: const ConversationShell()),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
      // The shell starts with no account selected; the deep link opening
      // the room must not depend on one being selected already.
      selectedAccounts.add(otherAccount);

      await _pumpUntil(
        tester,
        () => find.byKey(const Key('chat-room-screen')).evaluate().isNotEmpty,
      );

      expect(find.text('Deep link target room'), findsOneWidget);
      // A one-shot query, not a watch(): a stream's `.first` here would wait
      // on a Timer that only fires while something is still pumping frames,
      // which deadlocks now that `_pumpUntil` has stopped.
      final selected = await accounts.getAccount(targetAccount.id);
      expect(selected?.selected, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}

typedef _RequestHandler =
    Future<http.StreamedResponse> Function(http.BaseRequest request);

final class _CallbackClient extends http.BaseClient {
  _CallbackClient(this.handler);

  final _RequestHandler handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return handler(request);
  }
}

final class _FakeDeepLinkPlatform implements DeepLinkPlatform {
  _FakeDeepLinkPlatform({this.launchLink});

  final Uri? launchLink;
  final StreamController<Uri> _controller = StreamController<Uri>.broadcast();
  var _launchLinkTaken = false;

  @override
  Stream<Uri> get linkOpened => _controller.stream;

  @override
  Future<Uri?> getLaunchLink() async {
    if (_launchLinkTaken) {
      return null;
    }
    _launchLinkTaken = true;
    return launchLink;
  }

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    if (condition()) {
      return;
    }
  }
  fail('Condition was not reached');
}
