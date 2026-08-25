import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/conversation_avatar_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_participant_avatar.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations.dart';

void main() {
  const accountA = StoredAccount(
    id: 'account-a',
    serverUrl: 'https://cloud.example.invalid/nextcloud',
    loginName: 'fixture-a',
    serverProductName: 'Nextcloud',
    talkFeaturesJson: '[]',
    selected: true,
    createdAtMillis: 1767225600000,
  );
  const accountB = StoredAccount(
    id: 'account-b',
    serverUrl: 'https://cloud.example.invalid/nextcloud',
    loginName: 'fixture-b',
    serverProductName: 'Nextcloud',
    talkFeaturesJson: '[]',
    selected: false,
    createdAtMillis: 1767225600001,
  );
  const accountAAfterSync = StoredAccount(
    id: 'account-a',
    serverUrl: 'https://cloud.example.invalid/nextcloud',
    loginName: 'fixture-a',
    serverProductName: 'Nextcloud',
    talkFeaturesJson: '[]',
    selected: true,
    createdAtMillis: 1767225600000,
    conversationCursor: '1724300001',
    conversationHash: 'fixture-hash-a',
    lastSyncedAtMillis: 1767225660000,
  );

  testWidgets('builds same-origin encoded light and dark user avatar URIs', (
    tester,
  ) async {
    final keys = <ConversationAvatarProviderKey>[];
    final override = conversationAvatarProvider.overrideWith((ref, key) async {
      keys.add(key);
      return null;
    });

    await tester.pumpWidget(
      _app(
        account: accountA,
        actorType: 'users',
        actorId: 'peer/name',
        displayName: 'Peer Name',
        override: override,
      ),
    );
    await tester.pump();

    expect(keys, hasLength(1));
    expect(
      keys.single.uri.toString(),
      'https://cloud.example.invalid/nextcloud/'
      'index.php/avatar/peer%2Fname/64',
    );
    expect(keys.single.versioned, isFalse);

    keys.clear();
    await tester.pumpWidget(
      _app(
        account: accountA,
        actorType: 'users',
        actorId: 'peer/name',
        displayName: 'Peer Name',
        override: override,
        dark: true,
      ),
    );
    await tester.pump();

    expect(keys, hasLength(1));
    expect(
      keys.single.uri.toString(),
      'https://cloud.example.invalid/nextcloud/'
      'index.php/avatar/peer%2Fname/64/dark',
    );
  });

  testWidgets('keeps a local fallback while loading, failed, or offline', (
    tester,
  ) async {
    final pending = Completer<ConversationAvatarImage?>();
    await tester.pumpWidget(
      _app(
        account: accountA,
        actorType: 'users',
        actorId: 'peer-a',
        displayName: 'Peer A',
        override: conversationAvatarProvider.overrideWith(
          (ref, key) => pending.future,
        ),
      ),
    );
    expect(find.text('PA'), findsOneWidget);

    await tester.pumpWidget(
      _app(
        account: accountA,
        actorType: 'users',
        actorId: 'peer-a',
        displayName: 'Peer A',
        override: conversationAvatarProvider.overrideWith(
          (ref, key) => Future.error(StateError('synthetic failure')),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('PA'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      _app(
        account: accountA,
        actorType: 'users',
        actorId: 'peer-a',
        displayName: 'Peer A',
        override: conversationAvatarProvider.overrideWith(
          (ref, key) => Future.error(http.ClientException('synthetic offline')),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('PA'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses local identities and never fetches non-user actors', (
    tester,
  ) async {
    var requests = 0;
    final override = conversationAvatarProvider.overrideWith((ref, key) async {
      requests++;
      return null;
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [override],
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: const [
                ChatParticipantAvatar(
                  account: accountA,
                  actorType: 'guests',
                  actorId: 'external-guest',
                  displayName: 'Guest Person',
                ),
                ChatParticipantAvatar(
                  account: accountA,
                  actorType: 'bots',
                  actorId: 'automation-bot',
                  displayName: 'Automation',
                ),
                ChatParticipantAvatar(
                  account: accountA,
                  actorType: 'bridged',
                  actorId: 'remote-bridge',
                  displayName: 'Remote Bridge',
                ),
                ChatParticipantAvatar(
                  account: accountA,
                  actorType: 'system',
                  actorId: 'internal-system',
                  displayName: 'System',
                ),
                ChatParticipantAvatar(
                  account: accountA,
                  actorType: 'unknown',
                  actorId: 'unknown-id',
                  displayName: 'Ada Lovelace',
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(requests, 0);
    expect(find.byIcon(Icons.person_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.smart_toy_rounded), findsOneWidget);
    expect(find.byIcon(Icons.cable_rounded), findsOneWidget);
    expect(find.byIcon(Icons.campaign_rounded), findsOneWidget);
    expect(find.text('AL'), findsOneWidget);
  });

  testWidgets(
    'provider key preserves account isolation for the same avatar URI',
    (tester) async {
      final keys = <ConversationAvatarProviderKey>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            conversationAvatarProvider.overrideWith((ref, key) async {
              keys.add(key);
              return null;
            }),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  ChatParticipantAvatar(
                    account: accountA,
                    actorType: 'users',
                    actorId: 'shared-peer',
                    displayName: 'Shared Peer A',
                  ),
                  ChatParticipantAvatar(
                    account: accountB,
                    actorType: 'users',
                    actorId: 'shared-peer',
                    displayName: 'Shared Peer B',
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(keys, hasLength(2));
      expect(keys.map((key) => key.uri).toSet(), hasLength(1));
      expect(keys.map((key) => key.account.id).toSet(), {
        'account-a',
        'account-b',
      });
    },
  );

  testWidgets('provider key ignores mutable account synchronization metadata', (
    tester,
  ) async {
    final account = ValueNotifier<StoredAccount?>(accountA);
    addTearDown(account.dispose);
    var loads = 0;

    await tester.pumpWidget(
      _switchableApp(
        account: account,
        override: conversationAvatarProvider.overrideWith((ref, key) async {
          loads++;
          return null;
        }),
      ),
    );
    await tester.pump();
    expect(loads, 1);

    account.value = accountAAfterSync;
    await tester.pump();

    expect(loads, 1);
  });

  testWidgets('provider releases avatar bytes after its last listener', (
    tester,
  ) async {
    final account = ValueNotifier<StoredAccount?>(accountA);
    addTearDown(account.dispose);
    var disposals = 0;

    await tester.pumpWidget(
      _switchableApp(
        account: account,
        override: conversationAvatarProvider.overrideWith((ref, key) async {
          ref.onDispose(() => disposals++);
          return ConversationAvatarImage(
            body: Uint8List.fromList(const [1, 2, 3]),
            contentType: 'image/png',
          );
        }),
      ),
    );
    await tester.pump();
    expect(disposals, 0);

    account.value = null;
    await tester.pump();
    await tester.pump();

    expect(disposals, 1);
  });

  testWidgets('semantics exposes the display name but never the actor id', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        account: accountA,
        actorType: 'unknown',
        actorId: 'private-internal-id',
        displayName: 'Visible Name',
        override: conversationAvatarProvider.overrideWith(
          (ref, key) async => null,
        ),
      ),
    );

    expect(find.bySemanticsLabel('Visible Name'), findsOneWidget);
    expect(find.bySemanticsLabel('private-internal-id'), findsNothing);
    expect(
      tester.getSemantics(find.byType(ChatParticipantAvatar)),
      matchesSemantics(label: 'Visible Name', isImage: true),
    );
    expect(tester.getSize(find.byType(CircleAvatar)), const Size.square(32));
    semantics.dispose();
  });

  testWidgets('fallback semantics labels follow the Czech locale', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          locale: Locale('cs'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Column(
              children: [
                ChatParticipantAvatar(
                  account: accountA,
                  actorType: 'guests',
                  actorId: '',
                  displayName: '',
                ),
                ChatParticipantAvatar(
                  account: accountA,
                  actorType: 'bots',
                  actorId: '',
                  displayName: '',
                ),
                ChatParticipantAvatar(
                  account: accountA,
                  actorType: 'bridged',
                  actorId: '',
                  displayName: '',
                ),
                ChatParticipantAvatar(
                  account: accountA,
                  actorType: 'system',
                  actorId: '',
                  displayName: '',
                ),
                ChatParticipantAvatar(
                  account: accountA,
                  actorType: 'unknown',
                  actorId: '',
                  displayName: '',
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Host'), findsOneWidget);
    expect(find.bySemanticsLabel('Bot'), findsOneWidget);
    expect(find.bySemanticsLabel('Účastník propojené služby'), findsOneWidget);
    expect(find.bySemanticsLabel('Systém'), findsOneWidget);
    expect(find.bySemanticsLabel('Účastník'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('keeps initials inside the avatar at 200 percent text scale', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        account: accountA,
        actorType: 'unknown',
        actorId: 'peer-a',
        displayName: 'Ada Lovelace',
        override: conversationAvatarProvider.overrideWith(
          (ref, key) async => null,
        ),
        textScaler: const TextScaler.linear(2),
      ),
    );

    expect(find.text('AL'), findsOneWidget);
    expect(tester.getSize(find.byType(CircleAvatar)), const Size.square(32));
    expect(tester.takeException(), isNull);
  });
}

Widget _app({
  required StoredAccount account,
  required String actorType,
  required String actorId,
  required String displayName,
  required Override override,
  bool dark = false,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return ProviderScope(
    key: UniqueKey(),
    overrides: [override],
    child: MaterialApp(
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(textScaler: textScaler),
          child: ChatParticipantAvatar(
            account: account,
            actorType: actorType,
            actorId: actorId,
            displayName: displayName,
          ),
        ),
      ),
    ),
  );
}

Widget _switchableApp({
  required ValueListenable<StoredAccount?> account,
  required Override override,
}) {
  return ProviderScope(
    overrides: [override],
    child: MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<StoredAccount?>(
          valueListenable: account,
          builder: (context, value, child) {
            if (value == null) {
              return const SizedBox.shrink();
            }
            return ChatParticipantAvatar(
              account: value,
              actorType: 'users',
              actorId: 'peer-a',
              displayName: 'Peer A',
            );
          },
        ),
      ),
    ),
  );
}
